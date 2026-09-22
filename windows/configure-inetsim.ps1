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
$ErrorActionPreference='Stop'
$ProgressPath="$ResultPath.progress.txt"

function Set-Stage([string]$Stage) {
    try {
        $line=("{0} {1}" -f (Get-Date).ToString('o'),$Stage)
        [System.IO.File]::AppendAllText($ProgressPath,$line+[Environment]::NewLine,[System.Text.Encoding]::ASCII)
    } catch {}
}

Set-Stage 'start'

function Write-Result($ok,$message,$extra) {
    $o=@{ok=[bool]$ok;message=[string]$message;time=(Get-Date).ToString('o')}
    if($extra){foreach($k in $extra.Keys){$o[$k]=$extra[$k]}}
    $dir=Split-Path -Parent $ResultPath
    if($dir -and -not (Test-Path $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
    if(Get-Command ConvertTo-Json -ErrorAction SilentlyContinue){
        $json=$o|ConvertTo-Json -Depth 8
    } else {
        Add-Type -AssemblyName System.Web.Extensions
        $ser=New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $json=$ser.Serialize($o)
    }
    [System.IO.File]::WriteAllText($ResultPath,$json,[System.Text.Encoding]::UTF8)
}

function Normalize-Mac([string]$m){(($m -replace '[^0-9A-Fa-f]','').ToUpperInvariant())}

function Get-AdapterSelector($Adapter) {
    $name=[string]$Adapter.NetConnectionID
    if($name){return $name}
    return [string]$Adapter.InterfaceIndex
}

function Invoke-NetshChecked([string[]]$NetshArgs,[string]$Operation) {
    $output=@(& netsh.exe @NetshArgs 2>&1)
    if($LASTEXITCODE -ne 0){
        throw ("{0} failed (netsh exit {1}): {2}" -f $Operation,$LASTEXITCODE,($output -join ' '))
    }
}

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

function Get-Default6Lines {
    @((& netsh interface ipv6 show route 2>$null) |
      Where-Object{$_ -match '(^|\s)::/0(\s|$)'})
}

function Refresh-Config([int]$Index){
    Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "Index=$Index" -ErrorAction Stop
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
        $backup=@{
            adapters=@(Get-WmiObject Win32_NetworkAdapter | Select-Object Index,InterfaceIndex,NetConnectionID,MACAddress,NetEnabled,NetConnectionStatus)
            configs=@(Get-WmiObject Win32_NetworkAdapterConfiguration | Select-Object Index,InterfaceIndex,IPAddress,IPSubnet,DefaultIPGateway,DNSServerSearchOrder,DHCPEnabled)
            route4=@(& route print -4)
            route6=@(& netsh interface ipv6 show route)
        }
        if(Get-Command ConvertTo-Json -ErrorAction SilentlyContinue){
            $backup|ConvertTo-Json -Depth 8|Set-Content -Encoding UTF8 -Path $backupPath
        }
    }

    $mgmtSelector=Get-AdapterSelector $mgmtAdapter
    $isoSelector=Get-AdapterSelector $isoAdapter
    if($mgmtAdapter.NetEnabled -ne $true){
        Set-Stage 'enable-management-adapter'
        Invoke-NetshChecked @('interface','set','interface',"name=$mgmtSelector",'admin=enabled') 'management adapter enable'
        Start-Sleep -Seconds 1
    }
    if($isoAdapter.NetEnabled -ne $true){
        Set-Stage 'enable-isolated-adapter'
        Invoke-NetshChecked @('interface','set','interface',"name=$isoSelector",'admin=enabled') 'isolated adapter enable'
        Start-Sleep -Seconds 1
    }
    Set-Stage 'adapters-enabled'

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

    # Avoid Win32_NetworkAdapterConfiguration mutation methods here. On real
    # CAPE guests those calls can block for many minutes while reconfiguring the
    # same NIC that carries CAPE Agent. netsh performs the same persistent
    # transition without holding an in-process WMI method call open.
    Set-Stage 'management-static-begin'
    Invoke-NetshChecked @(
        'interface','ip','set','address',
        "name=$mgmtSelector",'source=static',
        "address=$ManagementIP","mask=$mgmtMask",'gateway=none'
    ) 'management static IPv4/no-gateway'
    Set-Stage 'management-static-done'

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

    Set-Stage 'isolated-static-begin'
    Invoke-NetshChecked @(
        'interface','ip','set','address',
        "name=$isoSelector",'source=static',
        "address=$FakeIP","mask=$isoMask",'gateway=none'
    ) 'isolated static IPv4/no-gateway'
    Set-Stage 'isolated-static-done'

    Set-Stage 'dns-update-begin'
    Invoke-NetshChecked @(
        'interface','ip','set','dns',
        "name=$mgmtSelector",'source=static',"address=$DnsIP",'register=primary'
    ) 'management DNS update'
    Invoke-NetshChecked @(
        'interface','ip','set','dns',
        "name=$isoSelector",'source=static',"address=$DnsIP",'register=primary'
    ) 'isolated DNS update'
    Set-Stage 'dns-update-done'

    $mgmtCfg=Refresh-Config $mgmtAdapter.Index
    $isoCfg=Refresh-Config $isoAdapter.Index

    Set-Stage 'disable-unexpected-adapters-begin'
    foreach($a in @(Get-WmiObject Win32_NetworkAdapter |
        Where-Object{$_.Index -ne $mgmtAdapter.Index -and $_.Index -ne $isoAdapter.Index -and $_.NetEnabled -eq $true})){
        $selector=Get-AdapterSelector $a
        Invoke-NetshChecked @('interface','set','interface',"name=$selector",'admin=disabled') ("disable unexpected adapter {0}" -f $selector)
    }
    Set-Stage 'disable-unexpected-adapters-done'

    for($i=0;$i -lt 5;$i++){
        if((Get-Default4).Count -eq 0){break}
        & route.exe delete 0.0.0.0|Out-Null
        Start-Sleep -Milliseconds 300
    }

    foreach($a in @(Get-WmiObject Win32_NetworkAdapter | Where-Object{$_.InterfaceIndex})){
        & netsh interface ipv6 set interface $a.InterfaceIndex routerdiscovery=disabled store=persistent 2>$null|Out-Null
        & netsh interface ipv6 delete route '::/0' "interface=$($a.InterfaceIndex)" store=active 2>$null|Out-Null
        & netsh interface ipv6 delete route '::/0' "interface=$($a.InterfaceIndex)" store=persistent 2>$null|Out-Null
    }
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Force|Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents -PropertyType DWord -Value 255 -Force|Out-Null

    Set-Stage 'route-and-ipv6-hardening-done'
    & ipconfig /flushdns|Out-Null
    Start-Sleep -Seconds 2

    Set-Stage 'validation-begin'
    $defaults4=Get-Default4
    $defaults6=Get-Default6Lines
    if($defaults4.Count -ne 0){throw "IPv4 default route removal failed; count=$($defaults4.Count)"}
    if($defaults6.Count -ne 0){throw "IPv6 default route removal failed; count=$($defaults6.Count)"}

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

    Set-Stage 'validation-complete'
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
    Set-Stage ("failed: " + $_.Exception.Message)
    Write-Result $false $_.Exception.Message @{error=($_|Out-String)}
    exit 1
}
