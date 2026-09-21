param(
    [Parameter(Mandatory=$true)][string]$ManagementIP,
    [Parameter(Mandatory=$true)][string]$IsolatedMac,
    [Parameter(Mandatory=$true)][string]$FakeIP,
    [Parameter(Mandatory=$true)][int]$PrefixLength,
    [Parameter(Mandatory=$true)][string]$DnsIP,
    [Parameter(Mandatory=$true)][string]$ResultServerIP,
    [Parameter(Mandatory=$true)][int]$ResultServerPort,
    [Parameter(Mandatory=$true)][string]$ControlHostIP,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'

function Write-Result($ok, $message, $extra) {
    $obj = [ordered]@{ ok = [bool]$ok; message = [string]$message; time = (Get-Date).ToString('o') }
    if ($extra) { foreach ($k in $extra.Keys) { $obj[$k] = $extra[$k] } }
    $dir = Split-Path -Parent $ResultPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $ResultPath
}

try {
    $mgmtIPObj = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ManagementIP -ErrorAction Stop | Select-Object -First 1
    $mgmtIf = Get-NetAdapter -InterfaceIndex $mgmtIPObj.InterfaceIndex -ErrorAction Stop

    $macNorm = ($IsolatedMac -replace ':','-').ToUpperInvariant()
    $isoIf = Get-NetAdapter | Where-Object { $_.MacAddress -and $_.MacAddress.ToUpperInvariant() -eq $macNorm } | Select-Object -First 1
    if (-not $isoIf) { throw "isolated adapter with MAC $IsolatedMac was not found" }
    if ($isoIf.ifIndex -eq $mgmtIf.ifIndex) { throw 'isolated adapter resolved to management adapter' }

    $backupDir = 'C:\ProgramData\CAPE-INetSim-AutoDeploy'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backupPath = Join-Path $backupDir 'network-before.json'
    if (-not (Test-Path $backupPath)) {
        [ordered]@{
            adapters = @(Get-NetAdapter | Select-Object Name,InterfaceDescription,ifIndex,MacAddress,Status)
            addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,IPAddress,PrefixLength,Type,PrefixOrigin,SuffixOrigin)
            dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,ServerAddresses)
            routes = @(Get-NetRoute -AddressFamily IPv4 | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,PolicyStore)
        } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $backupPath
    }

    Enable-NetAdapter -InterfaceIndex $isoIf.ifIndex -Confirm:$false -ErrorAction SilentlyContinue

    foreach ($remote in @($ResultServerIP,$ControlHostIP) | Select-Object -Unique) {
        if (-not $remote) { continue }
        $best = Find-NetRoute -RemoteIPAddress $remote -ErrorAction SilentlyContinue
        if ($best -and $best.NetRoute.DestinationPrefix -eq '0.0.0.0/0' -and $best.NetRoute.NextHop -ne '0.0.0.0') {
            $prefix = "$remote/32"
            $exists = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -eq $best.NetRoute.InterfaceIndex -and $_.NextHop -eq $best.NetRoute.NextHop }
            if (-not $exists) {
                New-NetRoute -AddressFamily IPv4 -DestinationPrefix $prefix -InterfaceIndex $best.NetRoute.InterfaceIndex -NextHop $best.NetRoute.NextHop -RouteMetric 1 -PolicyStore PersistentStore | Out-Null
            }
        }
    }

    Get-NetIPAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne $FakeIP } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    $existingFake = Get-NetIPAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -IPAddress $FakeIP -ErrorAction SilentlyContinue
    if (-not $existingFake) {
        New-NetIPAddress -InterfaceIndex $isoIf.ifIndex -IPAddress $FakeIP -PrefixLength $PrefixLength -AddressFamily IPv4 | Out-Null
    }

    Set-DnsClientServerAddress -InterfaceIndex $mgmtIf.ifIndex -ServerAddresses @($DnsIP)
    Set-DnsClientServerAddress -InterfaceIndex $isoIf.ifIndex -ServerAddresses @($DnsIP)

    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    $defaults = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if ($defaults.Count -ne 0) { throw "default route removal failed; count=$($defaults.Count)" }

    $null = Get-NetIPAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -IPAddress $FakeIP -ErrorAction Stop
    $dnsMgmt = (Get-DnsClientServerAddress -InterfaceIndex $mgmtIf.ifIndex -AddressFamily IPv4).ServerAddresses
    $dnsIso = (Get-DnsClientServerAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4).ServerAddresses
    if (@($dnsMgmt).Count -ne 1 -or $dnsMgmt[0] -ne $DnsIP) { throw 'management-adapter DNS validation failed' }
    if (@($dnsIso).Count -ne 1 -or $dnsIso[0] -ne $DnsIP) { throw 'isolated-adapter DNS validation failed' }

    $rsOK = Test-NetConnection -ComputerName $ResultServerIP -Port $ResultServerPort -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $rsOK) { throw ("ResultServer {0}:{1} is not reachable" -f $ResultServerIP,$ResultServerPort) }

    $dnsAnswer = Resolve-DnsName -Name 'cape-inetsim-validation.invalid' -Server $DnsIP -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if (-not $dnsAnswer -or $dnsAnswer.IPAddress -ne $DnsIP) { throw 'INetSim DNS validation failed' }

    Write-Result $true 'Windows isolated networking configured' ([ordered]@{
        management_interface = $mgmtIf.Name
        management_index = $mgmtIf.ifIndex
        isolated_interface = $isoIf.Name
        isolated_index = $isoIf.ifIndex
        isolated_mac = $isoIf.MacAddress
        isolated_ip = $FakeIP
        dns = $DnsIP
        default_routes = 0
        resultserver_reachable = $true
        backup = $backupPath
    })
    exit 0
}
catch {
    Write-Result $false $_.Exception.Message ([ordered]@{ error = ($_ | Out-String) })
    exit 1
}
