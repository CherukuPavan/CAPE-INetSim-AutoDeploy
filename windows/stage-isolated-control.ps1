param(
    [Parameter(Mandatory=$true)][string]$IsolatedMac,
    [Parameter(Mandatory=$true)][string]$FakeIP,
    [Parameter(Mandatory=$true)][int]$PrefixLength,
    [Parameter(Mandatory=$true)][string]$PinnedClientIP,
    [Parameter(Mandatory=$true)][string]$IsolatedGatewayIP,
    [Parameter(Mandatory=$true)][int]$AgentPort,
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'

function Write-Result($ok,$message,$extra) {
    $o=@{ok=[bool]$ok;message=[string]$message;time=(Get-Date).ToString('o');stage='isolated-control-ready'}
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

function Invoke-Netsh([string[]]$Arguments) {
    $output=@(& netsh.exe @Arguments 2>&1)
    $rc=$LASTEXITCODE
    if($rc -ne 0){
        throw ("netsh failed ({0}) for [{1}]: {2}" -f $rc,($Arguments -join ' '),($output -join ' '))
    }
    return $output
}

try {
    $wantMac=Normalize-Mac $IsolatedMac
    $isoAdapter=Get-WmiObject Win32_NetworkAdapter -ErrorAction Stop |
        Where-Object{$_.MACAddress -and (Normalize-Mac $_.MACAddress) -eq $wantMac} |
        Select-Object -First 1
    if(-not $isoAdapter){throw "isolated adapter with MAC $IsolatedMac was not found"}

    $selector=[string]$isoAdapter.NetConnectionID
    if(-not $selector){$selector=[string]$isoAdapter.InterfaceIndex}
    if(-not $selector){throw "isolated adapter $($isoAdapter.Index) has no controllable selector"}

    if($isoAdapter.NetEnabled -ne $true){
        Invoke-Netsh @('interface','set','interface',("name=" + $selector),'admin=enabled')|Out-Null
        Start-Sleep -Seconds 1
    }

    $mask=Prefix-ToMask $PrefixLength
    Invoke-Netsh @(
        'interface','ipv4','set','address',
        ("name=" + $selector),
        'source=static',
        ("address=" + $FakeIP),
        ("mask=" + $mask),
        'gateway=none',
        'store=persistent'
    )|Out-Null

    # CAPE Agent 0.22 can be pinned to the CAPE host IP that contacted it over
    # the management NIC. Preserve that client identity on the new isolated
    # path by routing only this /32 through the host-side isolated bridge.
    & route.exe -p add $PinnedClientIP mask 255.255.255.255 $IsolatedGatewayIP metric 1 if $isoAdapter.InterfaceIndex | Out-Null
    if($LASTEXITCODE -ne 0){
        & route.exe change $PinnedClientIP mask 255.255.255.255 $IsolatedGatewayIP metric 1 if $isoAdapter.InterfaceIndex | Out-Null
        if($LASTEXITCODE -ne 0){throw "could not route pinned CAPE client $PinnedClientIP through isolated adapter"}
    }

    $rule='CAPE-INetSim-AutoDeploy isolated control'
    & netsh.exe advfirewall firewall delete rule name="$rule" protocol=TCP localport=$AgentPort | Out-Null
    Invoke-Netsh @(
        'advfirewall','firewall','add','rule',
        ("name=" + $rule),
        'dir=in',
        'action=allow',
        'protocol=TCP',
        ("localport=" + $AgentPort),
        ("remoteip=" + $PinnedClientIP),
        'profile=any'
    )|Out-Null

    $seen=$false
    for($i=0;$i -lt 15;$i++){
        $cfg=Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "Index=$($isoAdapter.Index)" -ErrorAction Stop
        if($cfg.IPAddress -and ($cfg.IPAddress -contains $FakeIP)){$seen=$true;break}
        Start-Sleep -Seconds 1
    }
    if(-not $seen){throw "isolated IPv4 address $FakeIP was not observed after staging"}

    Write-Result $true 'Isolated CAPE Agent path staged with pinned client identity preserved' @{
        fake_ip=$FakeIP
        isolated_mac=$isoAdapter.MACAddress
        pinned_client_ip=$PinnedClientIP
        isolated_gateway_ip=$IsolatedGatewayIP
        agent_port=$AgentPort
    }
    exit 0
} catch {
    Write-Result $false $_.Exception.Message @{error=($_|Out-String)}
    exit 1
}
