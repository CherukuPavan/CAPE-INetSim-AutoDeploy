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
    $mgmt=Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ManagementIP -ErrorAction Stop|Select-Object -First 1
    $macNorm=($IsolatedMac -replace ':','-').ToUpperInvariant()
    $iso=Get-NetAdapter|Where-Object{$_.MacAddress -and $_.MacAddress.ToUpperInvariant() -eq $macNorm}|Select-Object -First 1
    if(-not $iso){throw "isolated adapter $IsolatedMac missing"}
    $null=Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $iso.ifIndex -IPAddress $FakeIP -ErrorAction Stop

    $defaults=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if($defaults.Count -ne 0){throw "default route present: $($defaults.Count)"}

    $active=@(Get-NetAdapter|Where-Object{$_.Status -eq 'Up'})
    $servers=@()
    foreach($a in $active){
        $servers += @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    }
    $servers=@($servers|Where-Object{$_}|Sort-Object -Unique)
    if($servers.Count -ne 1 -or $servers[0] -ne $DnsIP){throw "active-adapter DNS is not exclusively $DnsIP"}

    if(-not (Test-NetConnection -ComputerName $ResultServerIP -Port $ResultServerPort -InformationLevel Quiet -WarningAction SilentlyContinue)){
        throw ("ResultServer {0}:{1} unreachable" -f $ResultServerIP,$ResultServerPort)
    }
    $ans=Resolve-DnsName -Name 'cape-inetsim-validation.invalid' -Server $DnsIP -Type A -DnsOnly -ErrorAction Stop|
        Where-Object{$_.Type -eq 'A'}|Select-Object -First 1
    if(-not $ans -or $ans.IPAddress -ne $DnsIP){throw 'INetSim DNS answer validation failed'}
    if(Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue){throw 'real/public IP unexpectedly reachable'}

    Write-Result $true 'Windows safety gates passed' ([ordered]@{
        management_index=$mgmt.InterfaceIndex
        isolated_index=$iso.ifIndex
        fake_ip=$FakeIP
        dns=$DnsIP
        default_routes=0
        resultserver_reachable=$true
        public_ip_reachable=$false
    })
    exit 0
} catch {
    Write-Result $false $_.Exception.Message ([ordered]@{error=($_|Out-String)})
    exit 1
}
