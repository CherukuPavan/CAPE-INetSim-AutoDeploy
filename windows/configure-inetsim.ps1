param(
    [Parameter(Mandatory=$true)][string]$ManagementIP,
    [Parameter(Mandatory=$true)][string]$IsolatedMac,
    [Parameter(Mandatory=$true)][string]$FakeIP,
    [Parameter(Mandatory=$true)][int]$PrefixLength,
    [Parameter(Mandatory=$true)][string]$DnsIP,
    [Parameter(Mandatory=$true)][string]$ResultServerIP,
    [Parameter(Mandatory=$true)][int]$ResultServerPort,
    [Parameter(Mandatory=$true)][string]$ControlHostIP,
    [string]$PinnedClientIP='',
    [string]$IsolatedGatewayIP='',
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
    # PowerShell 2 / JavaScriptSerializer may recurse into PSObject/WMI wrappers.
    # The AutoDeploy result schema is deliberately flat, so serialize only
    # primitive scalars ourselves and never hand PowerShell runtime objects to
    # a generic serializer.
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

$ProgressPath="$ResultPath.progress"

function Write-Progress([string]$Stage) {
    try {
        [System.IO.File]::WriteAllText(
            $ProgressPath,
            ((Get-Date).ToString('o') + " stage=" + $Stage + [Environment]::NewLine),
            [System.Text.Encoding]::UTF8
        )
    } catch {}
}

function Invoke-Netsh([string[]]$Arguments) {
    $output=@(& netsh.exe @Arguments 2>&1)
    $rc=$LASTEXITCODE
    if($rc -ne 0){
        throw ("netsh failed ({0}) for [{1}]: {2}" -f $rc,($Arguments -join ' '),($output -join ' '))
    }
    return $output
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

function Same-Subnet([string]$A,[string]$B,[string]$Mask){
    $ab=[System.Net.IPAddress]::Parse($A).GetAddressBytes()
    $bb=[System.Net.IPAddress]::Parse($B).GetAddressBytes()
    $mb=[System.Net.IPAddress]::Parse($Mask).GetAddressBytes()
    for($i=0;$i -lt 4;$i++){
        if(($ab[$i] -band $mb[$i]) -ne ($bb[$i] -band $mb[$i])){return $false}
    }
    return $true
}

function Prefix-ToMask([int]$Prefix){
    if($Prefix -lt 0 -or $Prefix -gt 32){throw "invalid IPv4 prefix length $Prefix"}
    $octets=@()
    $remain=$Prefix
    for($i=0;$i -lt 4;$i++){
        $bits=[Math]::Min(8,[Math]::Max(0,$remain))
        $value=0
        for($j=0;$j -lt $bits;$j++){$value += [Math]::Pow(2,7-$j)}
        $octets += [int]$value
        $remain -= $bits
    }
    return ($octets -join '.')
}

function Get-Default4 {
    @(Get-WmiObject Win32_IP4RouteTable -ErrorAction SilentlyContinue |
      Where-Object{$_.Destination -eq '0.0.0.0' -and $_.Mask -eq '0.0.0.0'})
}

function Remove-Default4 {
    # Win32_IP4RouteTable is supported on Windows Vista/7 and advertises
    # SupportsDelete. Prefer deleting the exact WMI route instances; older
    # route.exe builds can report "Element not found" even while WMI still
    # exposes a default-route instance.
    for($attempt=0;$attempt -lt 5;$attempt++){
        $routes=@(Get-Default4)
        if([int]$routes.Count -eq 0){return}
        foreach($route in $routes){
            $deleted=$false
            try{
                $route.Delete()
                $deleted=$true
            } catch {}
            if(-not $deleted){
                $args=@('delete','0.0.0.0','mask','0.0.0.0')
                if([string]$route.NextHop -and [string]$route.NextHop -ne '0.0.0.0'){
                    $args += [string]$route.NextHop
                }
                if([int]$route.InterfaceIndex -gt 0){
                    $args += @('if',[string]$route.InterfaceIndex)
                }
                & route.exe @args 2>$null|Out-Null
            }
        }
        Start-Sleep -Milliseconds 300
    }

    $remaining=@(Get-Default4)
    if([int]$remaining.Count -ne 0){
        $facts=@($remaining | ForEach-Object{
            ('if={0} next={1} metric={2}' -f $_.InterfaceIndex,$_.NextHop,$_.Metric1)
        })
        throw ('IPv4 default route removal failed; count={0}; {1}' -f [int]$remaining.Count,($facts -join '; '))
    }
}

function Get-Default6Lines {
    @((& netsh interface ipv6 show route 2>$null) |
      Where-Object{$_ -match '(^|\s)::/0(\s|$)'})
}

function Refresh-Config([int]$Index){
    Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "Index=$Index" -ErrorAction Stop
}

function Ensure-TemporaryControlRoute([int]$InterfaceIndex){
    if(-not $PinnedClientIP){return}
    if(-not $IsolatedGatewayIP){throw 'isolated gateway is required when preserving CAPE Agent control'}

    $routes=@(Get-WmiObject Win32_IP4RouteTable -ErrorAction SilentlyContinue |
        Where-Object{$_.Destination -eq $PinnedClientIP -and $_.Mask -eq '255.255.255.255'})
    $exact=@($routes | Where-Object{
        [int]$_.InterfaceIndex -eq $InterfaceIndex -and
        [string]$_.NextHop -eq $IsolatedGatewayIP
    })
    if($exact.Count -eq 1 -and $routes.Count -eq 1){return}
    if($routes.Count -ne 0){
        throw "temporary CAPE control route for $PinnedClientIP changed unexpectedly"
    }

    & route.exe -p add $PinnedClientIP mask 255.255.255.255 $IsolatedGatewayIP metric 1 if $InterfaceIndex | Out-Null
    if($LASTEXITCODE -ne 0){throw "could not restore temporary CAPE control route for $PinnedClientIP"}
}

try{
    $mgmtCfg=Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction Stop |
        Where-Object{$_.IPAddress -and ($_.IPAddress -contains $ManagementIP)} |
        Select-Object -First 1
    if(-not $mgmtCfg){throw "management adapter for $ManagementIP was not found"}
    $mgmtAdapter=Get-WmiObject Win32_NetworkAdapter -Filter "Index=$($mgmtCfg.Index)" -ErrorAction Stop

    $wantMac=Normalize-Mac $IsolatedMac
    $isoAdapter=Get-WmiObject Win32_NetworkAdapter -ErrorAction Stop |
        Where-Object{$_.MACAddress -and (Normalize-Mac $_.MACAddress) -eq $wantMac} |
        Select-Object -First 1
    if(-not $isoAdapter){throw "isolated adapter with MAC $IsolatedMac was not found"}
    if($isoAdapter.Index -eq $mgmtAdapter.Index){throw 'isolated adapter resolved to management adapter'}
    $isoCfg=Refresh-Config $isoAdapter.Index

    $mgmtMask=$null
    $mgmtIPv4=@()
    $mgmtIPv4Masks=@()
    for($i=0;$i -lt @($mgmtCfg.IPAddress).Count;$i++){
        $addr=[string]$mgmtCfg.IPAddress[$i]
        if($addr -match '^\d+\.\d+\.\d+\.\d+$'){
            $mgmtIPv4 += $addr
            $mgmtIPv4Masks += [string]$mgmtCfg.IPSubnet[$i]
        }
        if($addr -eq $ManagementIP){$mgmtMask=[string]$mgmtCfg.IPSubnet[$i]}
    }
    if(-not $mgmtMask){throw 'could not determine management IPv4 subnet mask'}
    if($mgmtIPv4.Count -eq 0){throw 'management adapter has no IPv4 addresses to preserve'}
    $isoMask=Prefix-ToMask $PrefixLength
    $gateway=@($mgmtCfg.DefaultIPGateway | Where-Object{$_ -match '^\d+\.\d+\.\d+\.\d+$'} | Select-Object -First 1)

    $backupDir='C:\ProgramData\CAPE-INetSim-AutoDeploy'
    New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
    $backupPath=Join-Path $backupDir 'network-before.json'
    if(-not (Test-Path $backupPath)){
        # Store only plain values so the PowerShell 2 JSON fallback never
        # receives live WMI/PSObject wrappers.
        $backup=@{
            adapters=@(Get-WmiObject Win32_NetworkAdapter | ForEach-Object{
                @{
                    Index=[int]$_.Index
                    InterfaceIndex=[int]$_.InterfaceIndex
                    NetConnectionID=[string]$_.NetConnectionID
                    MACAddress=[string]$_.MACAddress
                    NetEnabled=[bool]$_.NetEnabled
                    NetConnectionStatus=[int]$_.NetConnectionStatus
                }
            })
            configs=@(Get-WmiObject Win32_NetworkAdapterConfiguration | ForEach-Object{
                @{
                    Index=[int]$_.Index
                    InterfaceIndex=[int]$_.InterfaceIndex
                    IPAddress=@($_.IPAddress | Where-Object{$_} | ForEach-Object{[string]$_})
                    IPSubnet=@($_.IPSubnet | Where-Object{$_} | ForEach-Object{[string]$_})
                    DefaultIPGateway=@($_.DefaultIPGateway | Where-Object{$_} | ForEach-Object{[string]$_})
                    DNSServerSearchOrder=@($_.DNSServerSearchOrder | Where-Object{$_} | ForEach-Object{[string]$_})
                    DHCPEnabled=[bool]$_.DHCPEnabled
                }
            })
            route4=@(& route print -4 | ForEach-Object{[string]$_})
            route6=@(& netsh interface ipv6 show route | ForEach-Object{[string]$_})
        }
        if(Get-Command ConvertTo-Json -ErrorAction SilentlyContinue){
            $backup|ConvertTo-Json -Depth 8|Set-Content -Encoding UTF8 -Path $backupPath
        } else {
            Add-Type -AssemblyName System.Web.Extensions
            $ser=New-Object System.Web.Script.Serialization.JavaScriptSerializer
            [System.IO.File]::WriteAllText($backupPath,$ser.Serialize($backup),[System.Text.Encoding]::UTF8)
        }
    }

    Write-Progress 'adapters-discovered'
    foreach($adapter in @($mgmtAdapter,$isoAdapter)){
        if($adapter.NetEnabled -ne $true){
            if(-not $adapter.NetConnectionID){throw "network adapter $($adapter.Index) has no controllable connection name"}
            Invoke-Netsh @('interface','set','interface',("name=" + $adapter.NetConnectionID),'admin=enabled')|Out-Null
            Start-Sleep -Seconds 1
        }
    }
    Write-Progress 'adapters-enabled'
    Ensure-TemporaryControlRoute $isoAdapter.InterfaceIndex
    Write-Progress 'control-route-proven'

    foreach($remote in @($ResultServerIP,$ControlHostIP)|Where-Object{$_}|Select-Object -Unique){
        if(-not (Same-Subnet $ManagementIP $remote $mgmtMask)){
            if(-not $gateway){throw "no management gateway exists to preserve routed control endpoint $remote"}
            & route.exe -p add $remote mask 255.255.255.255 $gateway[0] metric 1 if $mgmtAdapter.InterfaceIndex|Out-Null
            if($LASTEXITCODE -ne 0){
                & route.exe change $remote mask 255.255.255.255 $gateway[0] metric 1 if $mgmtAdapter.InterfaceIndex|Out-Null
                if($LASTEXITCODE -ne 0){throw "could not preserve route to control endpoint $remote"}
            }
        }
    }

    Invoke-Netsh @(
        'interface','ipv4','set','address',
        ("name=" + $mgmtAdapter.InterfaceIndex),
        'source=static',
        ("address=" + $ManagementIP),
        ("mask=" + $mgmtMask),
        'gateway=none',
        'store=persistent'
    )|Out-Null
    Write-Progress 'management-static'
    Ensure-TemporaryControlRoute $isoAdapter.InterfaceIndex

    # Persistently clear management default-gateway values so a future adapter
    # reinitialization cannot recreate Internet egress. Off-subnet CAPE control
    # endpoints, when present, were preserved above as explicit /32 routes.
    $ifaceKeyPath="SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($mgmtCfg.SettingID)"
    $ifaceKey=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($ifaceKeyPath,$true)
    if(-not $ifaceKey){throw 'could not open management TCP/IP registry state'}
    try{
        $empty=[string[]]@()
        $ifaceKey.SetValue('DefaultGateway',$empty,[Microsoft.Win32.RegistryValueKind]::MultiString)
        $ifaceKey.SetValue('DhcpDefaultGateway',$empty,[Microsoft.Win32.RegistryValueKind]::MultiString)
    } finally {
        $ifaceKey.Close()
    }

    # CAPE-Agent cutover pre-stages the isolated address and a temporary
    # pinned-client /32 route before this script is launched over that path.
    # Re-applying the isolated address with netsh can flush interface routes
    # and tear down the HTTP connection carrying /execpy. Preserve an already
    # correct staged address; QGA/WinRM paths still configure it here.
    $isoCfg=Refresh-Config $isoAdapter.Index
    $isolatedAlreadyStaged=($isoCfg.IPAddress -and ($isoCfg.IPAddress -contains $FakeIP))
    if($isolatedAlreadyStaged){
        $stagedMask=$null
        for($i=0;$i -lt @($isoCfg.IPAddress).Count;$i++){
            if([string]$isoCfg.IPAddress[$i] -eq $FakeIP){
                $stagedMask=[string]$isoCfg.IPSubnet[$i]
                break
            }
        }
        if($stagedMask -ne $isoMask){
            throw "pre-staged isolated address $FakeIP has unexpected mask $stagedMask (wanted $isoMask)"
        }
        Write-Progress 'isolated-static-preserved'
    } else {
        Invoke-Netsh @(
            'interface','ipv4','set','address',
            ("name=" + $isoAdapter.InterfaceIndex),
            'source=static',
            ("address=" + $FakeIP),
            ("mask=" + $isoMask),
            'gateway=none',
            'store=persistent'
        )|Out-Null
        Write-Progress 'isolated-static'
    }
    Ensure-TemporaryControlRoute $isoAdapter.InterfaceIndex

    Invoke-Netsh @(
        'interface','ipv4','set','dnsservers',
        ("name=" + $mgmtAdapter.InterfaceIndex),
        'source=static',
        ("address=" + $DnsIP),
        'register=none',
        'validate=no'
    )|Out-Null
    Invoke-Netsh @(
        'interface','ipv4','set','dnsservers',
        ("name=" + $isoAdapter.InterfaceIndex),
        'source=static',
        ("address=" + $DnsIP),
        'register=none',
        'validate=no'
    )|Out-Null
    Write-Progress 'dns-static'
    Ensure-TemporaryControlRoute $isoAdapter.InterfaceIndex

    $mgmtCfg=Refresh-Config $mgmtAdapter.Index
    $isoCfg=Refresh-Config $isoAdapter.Index

    foreach($a in @(Get-WmiObject Win32_NetworkAdapter |
        Where-Object{$_.Index -ne $mgmtAdapter.Index -and $_.Index -ne $isoAdapter.Index -and $_.NetEnabled -eq $true})){
        if(-not $a.NetConnectionID){throw "unexpected active adapter $($a.Index) cannot be safely disabled by name"}
        Invoke-Netsh @('interface','set','interface',("name=" + $a.NetConnectionID),'admin=disabled')|Out-Null
    }
    Write-Progress 'unexpected-adapters-disabled'

    Remove-Default4
    Write-Progress 'ipv4-default-route-removed'
    Ensure-TemporaryControlRoute $isoAdapter.InterfaceIndex

    foreach($a in @(Get-WmiObject Win32_NetworkAdapter | Where-Object{$_.InterfaceIndex})){
        & netsh interface ipv6 set interface $a.InterfaceIndex routerdiscovery=disabled store=persistent 2>$null|Out-Null
        & netsh interface ipv6 delete route '::/0' "interface=$($a.InterfaceIndex)" store=active 2>$null|Out-Null
        & netsh interface ipv6 delete route '::/0' "interface=$($a.InterfaceIndex)" store=persistent 2>$null|Out-Null
    }
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Force|Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents -PropertyType DWord -Value 255 -Force|Out-Null

    & ipconfig /flushdns|Out-Null
    Start-Sleep -Seconds 2

    $defaults4=@(Get-Default4)
    $defaults6=@(Get-Default6Lines)
    if([int]$defaults4.Count -ne 0){throw ("IPv4 default route removal failed; count={0}" -f [int]$defaults4.Count)}
    if([int]$defaults6.Count -ne 0){throw ("IPv6 default route removal failed; count={0}" -f [int]$defaults6.Count)}

    $mgmtCfg=Refresh-Config $mgmtAdapter.Index
    $isoCfg=Refresh-Config $isoAdapter.Index
    if(-not ($mgmtCfg.IPAddress -contains $ManagementIP)){throw 'management IPv4 address was not preserved'}
    if(-not ($isoCfg.IPAddress -contains $FakeIP)){throw 'isolated IPv4 address was not applied'}

    $active=@(Get-WmiObject Win32_NetworkAdapter |
        Where-Object{$_.NetEnabled -eq $true -and $_.NetConnectionStatus -eq 2})
    $unexpected=@($active |
        Where-Object{$_.Index -ne $mgmtAdapter.Index -and $_.Index -ne $isoAdapter.Index})
    if($unexpected.Count -ne 0){throw 'unexpected active network adapter remains'}

    $dns=@($mgmtCfg.DNSServerSearchOrder + $isoCfg.DNSServerSearchOrder |
        Where-Object{$_}|Sort-Object -Unique)
    if($dns.Count -ne 1 -or $dns[0] -ne $DnsIP){throw "active-adapter DNS is not exclusively $DnsIP"}

    Write-Progress 'network-state-validated'

    if(-not (Test-TcpPort $ResultServerIP $ResultServerPort)){
        throw ("ResultServer {0}:{1} is not reachable" -f $ResultServerIP,$ResultServerPort)
    }
    $answers=@([System.Net.Dns]::GetHostAddresses('cape-inetsim-validation.invalid') |
        ForEach-Object{$_.IPAddressToString})
    if(-not ($answers -contains $DnsIP)){throw 'INetSim DNS validation failed'}
    if(-not (Test-TcpPort $DnsIP 80)){throw 'INetSim HTTP service is not reachable'}
    if(-not (Test-TcpPort $DnsIP 443)){throw 'INetSim HTTPS service is not reachable'}

    $public4=(& ping.exe -n 1 -w 1000 8.8.8.8 2>$null|Select-String 'TTL=' -Quiet)
    $public6=(& ping.exe -6 -n 1 -w 1000 2606:4700:4700::1111 2>$null|Select-String 'TTL=' -Quiet)
    if($public4){throw 'public IPv4 unexpectedly reachable'}
    if($public6){throw 'public IPv6 unexpectedly reachable'}

    Write-Progress 'connectivity-validated'
    Write-Result $true 'Windows isolated networking configured and safety-verified' @{
        legacy_network_stack=$true
        management_interface=$mgmtAdapter.NetConnectionID
        management_index=$mgmtAdapter.InterfaceIndex
        isolated_interface=$isoAdapter.NetConnectionID
        isolated_index=$isoAdapter.InterfaceIndex
        isolated_mac=$isoAdapter.MACAddress
        isolated_ip=$FakeIP
        dns=$DnsIP
        default_routes=0
        ipv4_default_routes=0
        ipv6_default_routes=0
        ipv6_bindings_enabled=-1
        ipv6_router_discovery_disabled=$true
        unexpected_active_adapters=0
        resultserver_reachable=$true
        inetsim_http_reachable=$true
        inetsim_https_reachable=$true
        public_ip_reachable=$false
        public_ipv6_reachable=$false
        backup=$backupPath
    }
    exit 0
} catch {
    Write-Progress ('failed: ' + $_.Exception.Message)
    Write-Result $false $_.Exception.Message @{error=($_|Out-String)}
    exit 1
}
