# Simulate the full RoRo chain on the tester's savegame: waiting -> scan -> attach.
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$tr   = Join-Path $root 'testrun'
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

$cmds = @(
    'pause',
    'rvtransport list',
    'rvtransport orders firsttrain',
    'rvtransport orders firstrv',
    'rvtransport sim firsttrain firstrv',
    'rvtransport state firstrv',
    'rvtransport list',
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'sim' -Exe $exe -Config $cfg -Savegame $sav -Commands $cmds -LogName 'log_sim.txt'
$txt -split "`r?`n" | Where-Object { $_ -match 'rvtransport|sim:|orders|\[|vehicle #|rv #|carrying|on_board|Assertion|crash' } | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
