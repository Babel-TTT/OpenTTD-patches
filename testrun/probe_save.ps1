# Generic probe: load a savegame on a dedicated server and run console commands against it.
#
# Used to look at a tester's savegame (or any savegame) without touching it: the game is loaded, the
# commands are sent and the console output is printed (and written to testrun\log_probe_save.txt).
#
# Usage:
#   powershell -File testrun\probe_save.ps1 -SavePath "D:\path\to\game.sav" -Commands "rvtransport dump","rvtransport list"
param(
    [Parameter(Mandatory)][string]$SavePath,
    [string[]]$Commands = @('rvtransport list'),
    [string]$Config = '',
    [string]$Exe = '',
    [int]$ReadyTimeoutSec = 180,
    [double]$DelaySec = 1.2,
    [string]$LogName = 'log_probe_save.txt'
)

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
if (-not $Exe) { $Exe = Join-Path $root 'build\openttd.exe' }
$exe = $Exe
if (-not $Config) { $Config = Get-RoRoTestConfig -Root $root }
if (-not (Test-Path -LiteralPath $SavePath)) { Write-Output "savegame not found: $SavePath"; exit 1 }

# 'powershell -File ... -Commands a,b' arrives as one comma separated string, so split it.
$cmdList = @()
foreach ($c in $Commands) { $cmdList += ($c -split ',') | Where-Object { $_ } }

# The savegames of a tester may use many NewGRFs, so allow a long time for the load.
$cmds = @('pause') + $cmdList + @('quit')
$txt = Invoke-RoRoTest -Tag 'probe' -Exe $exe -Config $Config -Savegame $SavePath -Commands $cmds `
    -LogName $LogName -DelaySec $DelaySec -ReadyTimeoutSec $ReadyTimeoutSec

$txt -split "`r?`n" | Where-Object {
    $_ -match 'rv #|carrier|part \d+:|holds rv|station #|stop 0x|road stop|declared|order:|vscroll|carried|Assertion|crash|error'
} | ForEach-Object { Write-Output $_ }
