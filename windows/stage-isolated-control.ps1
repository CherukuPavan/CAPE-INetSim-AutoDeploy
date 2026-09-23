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
    $o=@{ok=[bool]$ok;message=[string]$message;time=(Get-Date).ToString('o');stage='isolated-control-ready'}
    if($extra){foreach($k in @($extra.Keys)){$key=[string]$k;$o[$key]=$extra[$k]}}
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

    # Preserve the CAPE host client identity on the isolated path using a
    # temporary /32 route. Never replace an unknown pre-existing route: this
    # route is deployment scaffolding and must be unambiguously ours.
    $preExistingPinnedRoutes=@(Get-WmiObject Win32_IP4RouteTable -ErrorAction SilentlyContinue |
        Where-Object{$_.Destination -eq $PinnedClientIP -and $_.Mask -eq '255.255.255.255'})
    if($preExistingPinnedRoutes.Count -ne 0){
        throw "refusing to overwrite pre-existing /32 route for CAPE client $PinnedClientIP"
    }
    & route.exe -p add $PinnedClientIP mask 255.255.255.255 $IsolatedGatewayIP metric 1 if $isoAdapter.InterfaceIndex | Out-Null
    if($LASTEXITCODE -ne 0){throw "could not route CAPE client $PinnedClientIP through isolated adapter"}

    $rule='CAPE-INetSim-AutoDeploy isolated control'
    try{
        $fw=New-Object -ComObject HNetCfg.FwPolicy2
        $preExistingRules=@($fw.Rules | Where-Object{$_.Name -eq $rule})
        if($preExistingRules.Count -ne 0){
            throw "refusing to replace pre-existing Windows Firewall rule '$rule'"
        }
    } catch {
        throw ('could not prove isolated-control firewall ownership: ' + $_.Exception.Message)
    }
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
