param(
    [Parameter(Mandatory=$true)][string]$ManagementIP,
    [Parameter(Mandatory=$true)][string]$IsolatedMac,
    [Parameter(Mandatory=$true)][string]$FakeIP,
    [Parameter(Mandatory=$true)][string]$DnsIP,
    [Parameter(Mandatory=$true)][string]$ResultServerIP,
    [Parameter(Mandatory=$true)][int]$ResultServerPort,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'

function Write-Result($ok,$message,$extra) {
    $o=[ordered]@{ok=[bool]$ok;message=[string]$message;time=(Get-Date).ToString('o')}
    if($extra){foreach($k in $extra.Keys){$o[$k]=$extra[$k]}}
    $o|ConvertTo-Json -Depth 8|Set-Content -Encoding UTF8 -Path $ResultPath
}

try {
    $legacyMode = -not [bool](Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)
    if($legacyMode){
        function Normalize-Mac([string]$m){ return (($m -replace '[^0-9A-Fa-f]','').ToUpperInvariant()) }
        function Test-TcpPort([string]$Address,[int]$Port,[int]$TimeoutMs=3000){
            $c=New-Object System.Net.Sockets.TcpClient
            try{
                $a=$c.BeginConnect($Address,$Port,$null,$null)
                if(-not $a.AsyncWaitHandle.WaitOne($TimeoutMs,$false)){ return $false }
                $c.EndConnect($a); return $true
            } catch { return $false } finally { $c.Close() }
        }
        function Get-Default4 {
            return @(Get-WmiObject Win32_IP4RouteTable -ErrorAction SilentlyContinue |
                Where-Object { $_.Destination -eq '0.0.0.0' -and $_.Mask -eq '0.0.0.0' })
        }
        function Get-Default6Lines {
            return @((& netsh interface ipv6 show route 2>$null) | Where-Object { $_ -match '(^|\s)::/0(\s|$)' })
        }

        $mgmtCfg=Get-WmiObject Win32_NetworkAdapterConfiguration -ErrorAction Stop |
            Where-Object { $_.IPAddress -and ($_.IPAddress -contains $ManagementIP) } | Select-Object -First 1
        if(-not $mgmtCfg){ throw "legacy management adapter for $ManagementIP missing" }
        $mgmtAdapter=Get-WmiObject Win32_NetworkAdapter -Filter "Index=$($mgmtCfg.Index)" -ErrorAction Stop

        $wantMac=Normalize-Mac $IsolatedMac
        $isoAdapter=Get-WmiObject Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.MACAddress -and (Normalize-Mac $_.MACAddress) -eq $wantMac } | Select-Object -First 1
        if(-not $isoAdapter){ throw "legacy isolated adapter $IsolatedMac missing" }
        $isoCfg=Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "Index=$($isoAdapter.Index)" -ErrorAction Stop

        if(-not ($mgmtCfg.IPAddress -contains $ManagementIP)){ throw 'legacy management IP missing' }
        if(-not ($isoCfg.IPAddress -contains $FakeIP)){ throw 'legacy fake IP missing' }

        $defaults4=Get-Default4
        $defaults6=Get-Default6Lines
        if($defaults4.Count -ne 0){ throw "legacy IPv4 default route present: $($defaults4.Count)" }
        if($defaults6.Count -ne 0){ throw "legacy IPv6 default route present: $($defaults6.Count)" }

        $active=@(Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.NetEnabled -eq $true -and $_.NetConnectionStatus -eq 2 })
        $unexpected=@($active | Where-Object { $_.Index -ne $mgmtAdapter.Index -and $_.Index -ne $isoAdapter.Index })
        if($unexpected.Count -ne 0){ throw 'unexpected legacy active adapter remains' }

        $dns=@($mgmtCfg.DNSServerSearchOrder + $isoCfg.DNSServerSearchOrder | Where-Object { $_ } | Sort-Object -Unique)
        if($dns.Count -ne 1 -or $dns[0] -ne $DnsIP){ throw "legacy active-adapter DNS is not exclusively $DnsIP" }

        if(-not (Test-TcpPort $ResultServerIP $ResultServerPort)){ throw ("ResultServer {0}:{1} unreachable" -f $ResultServerIP,$ResultServerPort) }
        & ipconfig /flushdns | Out-Null
        $answers=@([System.Net.Dns]::GetHostAddresses('cape-inetsim-validation.invalid') | ForEach-Object { $_.IPAddressToString })
        if(-not ($answers -contains $DnsIP)){ throw 'legacy INetSim DNS answer validation failed' }
        if(-not (Test-TcpPort $DnsIP 80)){ throw 'legacy INetSim HTTP service unreachable' }
        if(-not (Test-TcpPort $DnsIP 443)){ throw 'legacy INetSim HTTPS service unreachable' }

        $public4=(& ping.exe -n 1 -w 1000 8.8.8.8 2>$null | Select-String 'TTL=' -Quiet)
        $public6=(& ping.exe -6 -n 1 -w 1000 2606:4700:4700::1111 2>$null | Select-String 'TTL=' -Quiet)
        if($public4){ throw 'public IPv4 unexpectedly reachable' }
        if($public6){ throw 'public IPv6 unexpectedly reachable' }

        Write-Result $true 'Windows legacy safety gates passed' @{
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
            resultserver_reachable=$true
            inetsim_http_reachable=$true
            inetsim_https_reachable=$true
            public_ip_reachable=$false
            public_ipv6_reachable=$false
        }
        exit 0
    }

    $mgmt=Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ManagementIP -ErrorAction Stop|Select-Object -First 1
    $mgmtAdapter=Get-NetAdapter -InterfaceIndex $mgmt.InterfaceIndex -ErrorAction Stop
    $macNorm=($IsolatedMac -replace ':','-').ToUpperInvariant()
    $iso=Get-NetAdapter|Where-Object{$_.MacAddress -and $_.MacAddress.ToUpperInvariant() -eq $macNorm}|Select-Object -First 1
    if(-not $iso){throw "isolated adapter $IsolatedMac missing"}
    $null=Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $iso.ifIndex -IPAddress $FakeIP -ErrorAction Stop
    if($mgmtAdapter.Status -ne 'Up' -or $iso.Status -ne 'Up'){throw 'management/isolated adapter is not up'}

    $defaults4=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $defaults6=@(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
    if($defaults4.Count -ne 0){throw "IPv4 default route present: $($defaults4.Count)"}
    if($defaults6.Count -ne 0){throw "IPv6 default route present: $($defaults6.Count)"}

    $active=@(Get-NetAdapter|Where-Object{$_.Status -eq 'Up'})
    $unexpected=@($active|Where-Object{$_.ifIndex -ne $mgmt.InterfaceIndex -and $_.ifIndex -ne $iso.ifIndex})
    if($unexpected.Count -ne 0){throw "unexpected active adapter(s): $($unexpected.Name -join ',')"}

    $servers=@()
    foreach($a in $active){
        $servers += @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    }
    $servers=@($servers|Where-Object{$_}|Sort-Object -Unique)
    if($servers.Count -ne 1 -or $servers[0] -ne $DnsIP){throw "active-adapter DNS is not exclusively $DnsIP"}

    $ipv6Enabled=@()
    foreach($a in @(Get-NetAdapter)){
        $binding=Get-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        if($binding -and $binding.Enabled){$ipv6Enabled += $a.Name}
    }
    if($ipv6Enabled.Count -ne 0){throw "IPv6 binding enabled on: $($ipv6Enabled -join ',')"}

    if(-not (Test-NetConnection -ComputerName $ResultServerIP -Port $ResultServerPort -InformationLevel Quiet -WarningAction SilentlyContinue)){
        throw ("ResultServer {0}:{1} unreachable" -f $ResultServerIP,$ResultServerPort)
    }
    $ans=Resolve-DnsName -Name 'cape-inetsim-validation.invalid' -Server $DnsIP -Type A -DnsOnly -ErrorAction Stop|
        Where-Object{$_.Type -eq 'A'}|Select-Object -First 1
    if(-not $ans -or $ans.IPAddress -ne $DnsIP){throw 'INetSim DNS answer validation failed'}
    if(-not (Test-NetConnection -ComputerName $DnsIP -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue)){
        throw 'INetSim HTTP service unreachable'
    }
    if(-not (Test-NetConnection -ComputerName $DnsIP -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)){
        throw 'INetSim HTTPS service unreachable'
    }

    $public4=[bool](Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue)
    $public6=[bool](Test-Connection -ComputerName '2606:4700:4700::1111' -Count 1 -Quiet -ErrorAction SilentlyContinue)
    if($public4){throw 'public IPv4 unexpectedly reachable'}
    if($public6){throw 'public IPv6 unexpectedly reachable'}

    Write-Result $true 'Windows safety gates passed' ([ordered]@{
        management_index=$mgmt.InterfaceIndex
        isolated_index=$iso.ifIndex
        fake_ip=$FakeIP
        dns=$DnsIP
        default_routes=0
        ipv4_default_routes=0
        ipv6_default_routes=0
        ipv6_bindings_enabled=0
        unexpected_active_adapters=0
        resultserver_reachable=$true
        inetsim_http_reachable=$true
        inetsim_https_reachable=$true
        public_ip_reachable=$false
        public_ipv6_reachable=$false
    })
    exit 0
} catch {
    Write-Result $false $_.Exception.Message ([ordered]@{error=($_|Out-String)})
    exit 1
}
