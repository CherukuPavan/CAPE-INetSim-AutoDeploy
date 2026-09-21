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
            addresses_v4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,IPAddress,PrefixLength,Type,PrefixOrigin,SuffixOrigin)
            addresses_v6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object InterfaceIndex,IPAddress,PrefixLength,Type,PrefixOrigin,SuffixOrigin)
            dns_v4 = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,ServerAddresses)
            routes_v4 = @(Get-NetRoute -AddressFamily IPv4 | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,PolicyStore)
            routes_v6 = @(Get-NetRoute -AddressFamily IPv6 -ErrorAction SilentlyContinue | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,PolicyStore)
            ipv6_bindings = @(Get-NetAdapter | ForEach-Object {
                $b = Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
                [ordered]@{ Name=$_.Name; ifIndex=$_.ifIndex; Enabled=if($b){[bool]$b.Enabled}else{$null} }
            })
        } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $backupPath
    }

    Enable-NetAdapter -InterfaceIndex $mgmtIf.ifIndex -Confirm:$false -ErrorAction Stop
    Enable-NetAdapter -InterfaceIndex $isoIf.ifIndex -Confirm:$false -ErrorAction SilentlyContinue

    # Preserve explicit host routes to the CAPE control/ResultServer endpoints
    # before removing every IPv4 default route.
    foreach ($remote in @($ResultServerIP,$ControlHostIP) | Where-Object { $_ } | Select-Object -Unique) {
        $found = @(Find-NetRoute -RemoteIPAddress $remote -ErrorAction SilentlyContinue)
        $route = $found | Where-Object { $_.PSObject.Properties.Name -contains 'DestinationPrefix' } | Select-Object -First 1
        if ($route -and $route.DestinationPrefix -eq '0.0.0.0/0' -and $route.NextHop -and $route.NextHop -ne '0.0.0.0') {
            $hostPrefix = "$remote/32"
            $exists = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $hostPrefix -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -eq $route.InterfaceIndex -and $_.NextHop -eq $route.NextHop }
            if (-not $exists) {
                New-NetRoute -AddressFamily IPv4 -DestinationPrefix $hostPrefix -InterfaceIndex $route.InterfaceIndex -NextHop $route.NextHop -RouteMetric 1 -PolicyStore PersistentStore | Out-Null
            }
        }
    }

    # Any third adapter is an unneeded escape path in the analysis snapshot.
    # Disable it after recording the pre-change state. The safety snapshot
    # restores it exactly on rollback.
    $otherAdapters = @(Get-NetAdapter | Where-Object { $_.ifIndex -ne $mgmtIf.ifIndex -and $_.ifIndex -ne $isoIf.ifIndex })
    foreach ($adapter in $otherAdapters) {
        Disable-NetAdapter -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    }

    Get-NetIPAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne $FakeIP } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    if (-not (Get-NetIPAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -IPAddress $FakeIP -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $isoIf.ifIndex -IPAddress $FakeIP -PrefixLength $PrefixLength -AddressFamily IPv4 | Out-Null
    }

    # The fake Internet lab is IPv4-only. Disable the IPv6 protocol binding on
    # every adapter so an IPv6 RA/default route cannot become a real-Internet
    # bypass. CAPE management/ResultServer are explicitly validated over IPv4.
    foreach ($adapter in @(Get-NetAdapter)) {
        $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        if ($binding -and $binding.Enabled) {
            Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    Set-DnsClientServerAddress -InterfaceIndex $mgmtIf.ifIndex -ServerAddresses @($DnsIP)
    Set-DnsClientServerAddress -InterfaceIndex $isoIf.ifIndex -ServerAddresses @($DnsIP)
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    # Remove both IPv4 and IPv6 defaults. IPv6 is also unbound above, but the
    # route check is retained as an independent safety gate.
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    $defaults4 = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $defaults6 = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
    if ($defaults4.Count -ne 0) { throw "IPv4 default route removal failed; count=$($defaults4.Count)" }
    if ($defaults6.Count -ne 0) { throw "IPv6 default route removal failed; count=$($defaults6.Count)" }

    $mgmtAfter = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ManagementIP -ErrorAction Stop | Select-Object -First 1
    $null = Get-NetIPAddress -InterfaceIndex $isoIf.ifIndex -AddressFamily IPv4 -IPAddress $FakeIP -ErrorAction Stop
    if ((Get-NetAdapter -InterfaceIndex $mgmtAfter.InterfaceIndex).Status -ne 'Up') { throw 'management adapter is not up after isolation' }
    if ((Get-NetAdapter -InterfaceIndex $isoIf.ifIndex).Status -ne 'Up') { throw 'isolated adapter is not up after isolation' }

    $active = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    $unexpected = @($active | Where-Object { $_.ifIndex -ne $mgmtIf.ifIndex -and $_.ifIndex -ne $isoIf.ifIndex })
    if ($unexpected.Count -ne 0) { throw "unexpected active network adapter(s) remain: $($unexpected.Name -join ',')" }

    $dns = @()
    foreach ($adapter in $active) {
        $dns += @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    }
    $dns = @($dns | Where-Object { $_ } | Sort-Object -Unique)
    if ($dns.Count -ne 1 -or $dns[0] -ne $DnsIP) { throw "active-adapter DNS is not exclusively $DnsIP" }

    $ipv6Enabled = @()
    foreach ($adapter in @(Get-NetAdapter)) {
        $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        if ($binding -and $binding.Enabled) { $ipv6Enabled += $adapter.Name }
    }
    if ($ipv6Enabled.Count -ne 0) { throw "IPv6 remains enabled on: $($ipv6Enabled -join ',')" }

    $rsOK = Test-NetConnection -ComputerName $ResultServerIP -Port $ResultServerPort -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $rsOK) { throw ("ResultServer {0}:{1} is not reachable" -f $ResultServerIP,$ResultServerPort) }

    $dnsAnswer = Resolve-DnsName -Name 'cape-inetsim-validation.invalid' -Server $DnsIP -Type A -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if (-not $dnsAnswer -or $dnsAnswer.IPAddress -ne $DnsIP) { throw 'INetSim DNS validation failed' }

    if (-not (Test-NetConnection -ComputerName $DnsIP -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw 'INetSim HTTP service is not reachable'
    }

    $public4 = [bool](Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue)
    $public6 = [bool](Test-Connection -ComputerName '2606:4700:4700::1111' -Count 1 -Quiet -ErrorAction SilentlyContinue)
    if ($public4) { throw 'public IPv4 unexpectedly reachable' }
    if ($public6) { throw 'public IPv6 unexpectedly reachable' }

    Write-Result $true 'Windows isolated networking configured and safety-verified' ([ordered]@{
        management_interface = $mgmtIf.Name
        management_index = $mgmtIf.ifIndex
        isolated_interface = $isoIf.Name
        isolated_index = $isoIf.ifIndex
        isolated_mac = $isoIf.MacAddress
        isolated_ip = $FakeIP
        dns = $DnsIP
        default_routes = 0
        ipv4_default_routes = 0
        ipv6_default_routes = 0
        ipv6_bindings_enabled = 0
        unexpected_active_adapters = 0
        resultserver_reachable = $true
        inetsim_http_reachable = $true
        public_ip_reachable = $false
        public_ipv6_reachable = $false
        backup = $backupPath
    })
    exit 0
}
catch {
    Write-Result $false $_.Exception.Message ([ordered]@{ error = ($_ | Out-String) })
    exit 1
}
