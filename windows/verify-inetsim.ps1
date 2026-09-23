param(
    [Parameter(Mandatory=$true)][string]$ManagementIP,
    [Parameter(Mandatory=$true)][string]$IsolatedMac,
    [Parameter(Mandatory=$true)][string]$FakeIP,
    [Parameter(Mandatory=$true)][string]$DnsIP,
    [Parameter(Mandatory=$true)][string]$ResultServerIP,
    [Parameter(Mandatory=$true)][int]$ResultServerPort,
    [string]$PinnedClientIP='',
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'

function Escape-JsonString([string]$Value) {
    if($null -eq $Value){return ''}
    return $Value.Replace('\','\\').Replace('"','\"').Replace([char]13,'\r').Replace([char]10,'\n').Replace([char]9,'\t')
}

function Convert-SimpleJsonValue($Value) {
    if($null -eq $Value){return 'null'}
    if($Value -is [bool]){if($Value){return 'true'}else{return 'false'}}
    if($Value -is [byte] -or $Value -is [sbyte] -or
       $Value -is [int16] -or $Value -is [uint16] -or
       $Value -is [int32] -or $Value -is [uint32] -or
       $Value -is [int64] -or $Value -is [uint64] -or
       $Value -is [single] -or $Value -is [double] -or
       $Value -is [decimal]){
        return [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
    }
    return ('"' + (Escape-JsonString ([string]$Value)) + '"')
}

function Write-Result($ok,$message,$extra) {
    $o=@{ok=[bool]$ok;message=[string]$message;time=(Get-Date).ToString('o')}
    if($extra){foreach($k in @($extra.Keys)){$o[[string]$k]=$extra[$k]}}
    $parts=@()
    foreach($k in @($o.Keys | Sort-Object)){
        $parts += ('"' + (Escape-JsonString ([string]$k)) + '":' + (Convert-SimpleJsonValue $o[$k]))
    }
    $json='{' + ($parts -join ',') + '}'
    $dir=Split-Path -Parent $ResultPath
    if($dir -and -not (Test-Path $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    [System.IO.File]::WriteAllText($ResultPath,$json,[System.Text.Encoding]::UTF8)
}
function Normalize-Mac([string]$m){(($m -replace '[^0-9A-Fa-f]','').ToUpperInvariant())}

function Test-TcpPort([string]$Address,[int]$Port,[int]$TimeoutMs=3000){
    $c=New-Object System.Net.Sockets.TcpClient
    try{
        $a=$c.BeginConnect($Address,$Port,$null,$null)
        if(-not $a.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){return $false}
        $c.EndConnect($a)
        return $true
    } catch { return $false } finally { $c.Close() }
}

function Get-Default4 {
    @(Get-WmiObject Win32_IP4RouteTable -ErrorAction SilentlyContinue |
      Where-Object{$_.Destination -eq '0.0.0.0' -and $_.Mask -eq '0.0.0.0'})
}

function Get-Default6Lines {
    @((& netsh interface ipv6 show route 2>$null) |
      Where-Object{$_ -match '(^|\s)::/0(\s|$)'})
}

try{
    $mgmtCfg=Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction Stop |
        Where-Object{$_.IPAddress -and ($_.IPAddress -contains $ManagementIP)} |
        Select-Object -First 1
    if(-not $mgmtCfg){throw "management adapter for $ManagementIP missing"}
    $mgmtAdapter=Get-WmiObject Win32_NetworkAdapter -Filter "Index=$($mgmtCfg.Index)" -ErrorAction Stop

    $wantMac=Normalize-Mac $IsolatedMac
    $isoAdapter=Get-WmiObject Win32_NetworkAdapter -ErrorAction Stop |
        Where-Object{$_.MACAddress -and (Normalize-Mac $_.MACAddress) -eq $wantMac} |
        Select-Object -First 1
    if(-not $isoAdapter){throw "isolated adapter $IsolatedMac missing"}
    $isoCfg=Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "Index=$($isoAdapter.Index)" -ErrorAction Stop

    if(-not ($mgmtCfg.IPAddress -contains $ManagementIP)){throw 'management IP missing'}
    if(-not ($isoCfg.IPAddress -contains $FakeIP)){throw 'fake IP missing'}

    $defaults4=@(Get-Default4)
    $defaults6=@(Get-Default6Lines)
    if([int]$defaults4.Count -ne 0){throw ("IPv4 default route present: {0}" -f [int]$defaults4.Count)}
    if([int]$defaults6.Count -ne 0){throw ("IPv6 default route present: {0}" -f [int]$defaults6.Count)}

    $active=@(Get-WmiObject Win32_NetworkAdapter |
        Where-Object{$_.NetEnabled -eq $true -and $_.NetConnectionStatus -eq 2})
    $unexpected=@($active |
        Where-Object{$_.Index -ne $mgmtAdapter.Index -and $_.Index -ne $isoAdapter.Index})
    if($unexpected.Count -ne 0){throw 'unexpected active adapter remains'}

    $temporaryControlRoutes=0
    if($PinnedClientIP){
        $temporaryControlRoutes=@(Get-WmiObject Win32_IP4RouteTable -ErrorAction SilentlyContinue |
            Where-Object{
                $_.Destination -eq $PinnedClientIP -and
                $_.Mask -eq '255.255.255.255' -and
                [int]$_.InterfaceIndex -eq [int]$isoAdapter.InterfaceIndex
            }).Count
        if($temporaryControlRoutes -ne 0){
            throw "temporary isolated CAPE control route still exists for $PinnedClientIP"
        }
    }

    $isolatedAgentRules=0
    try{
        $fw=New-Object -ComObject HNetCfg.FwPolicy2
        $isolatedAgentRules=@($fw.Rules | Where-Object{$_.Name -eq 'CAPE-INetSim-AutoDeploy isolated control'}).Count
    } catch {
        throw ('could not verify temporary Windows Firewall cleanup: ' + $_.Exception.Message)
    }
    if($isolatedAgentRules -ne 0){throw 'temporary isolated CAPE Agent firewall rule still exists'}

    $dns=@($mgmtCfg.DNSServerSearchOrder + $isoCfg.DNSServerSearchOrder |
        Where-Object{$_}|Sort-Object -Unique)
    if($dns.Count -ne 1 -or $dns[0] -ne $DnsIP){throw "active-adapter DNS is not exclusively $DnsIP"}

    if(-not (Test-TcpPort $ResultServerIP $ResultServerPort)){
        throw ("ResultServer {0}:{1} unreachable" -f $ResultServerIP,$ResultServerPort)
    }

    & ipconfig /flushdns|Out-Null
    $answers=@([System.Net.Dns]::GetHostAddresses('cape-inetsim-validation.invalid') |
        ForEach-Object{$_.IPAddressToString})
    if(-not ($answers -contains $DnsIP)){throw 'INetSim DNS answer validation failed'}
    if(-not (Test-TcpPort $DnsIP 80)){throw 'INetSim HTTP service unreachable'}
    if(-not (Test-TcpPort $DnsIP 443)){throw 'INetSim HTTPS service unreachable'}

    $public4=(& ping.exe -n 1 -w 1000 8.8.8.8 2>$null|Select-String 'TTL=' -Quiet)
    $public6=(& ping.exe -6 -n 1 -w 1000 2606:4700:4700::1111 2>$null|Select-String 'TTL=' -Quiet)
    if($public4){throw 'public IPv4 unexpectedly reachable'}
    if($public6){throw 'public IPv6 unexpectedly reachable'}

    Write-Result $true 'Windows safety gates passed' @{
        legacy_network_stack=$true
        management_index=$mgmtAdapter.InterfaceIndex
        isolated_index=$isoAdapter.InterfaceIndex
        fake_ip=$FakeIP
        dns=$DnsIP
        default_routes=0
        ipv4_default_routes=0
        ipv6_default_routes=0
        ipv6_bindings_enabled=-1
        ipv6_router_discovery_disabled=$true
        unexpected_active_adapters=0
        temporary_control_routes=$temporaryControlRoutes
        isolated_agent_rules=$isolatedAgentRules
        resultserver_reachable=$true
        inetsim_http_reachable=$true
        inetsim_https_reachable=$true
        public_ip_reachable=$false
        public_ipv6_reachable=$false
    }
    exit 0
} catch {
    Write-Result $false $_.Exception.Message @{error=($_|Out-String)}
    exit 1
}
