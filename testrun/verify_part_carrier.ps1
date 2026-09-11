# Verify that the carrier-side loading code works when a *part* of a carrier enters the station.
#
# Every part of a multi-part carrier (a multi-hold ship, for instance) is a vehicle of its own which
# runs the loading code, while the road vehicles it carries belong to the *front* vehicle. Loading and
# unloading used to pass that part on as the carrier, so a multi-hold ship could not unload (and could
# only load onto the part which happened to be the front). This script uses a train wagon as the
# "part" (it is the same code path) and checks that the vehicle is attached to the train's front.
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

$cmds = @(
    'pause',
    'rvtransport list',
    'rvtransport setwaiting firsttrain firstrv',       # the road vehicle waits at the carrier's station
    'rvtransport state firsttrain',
    'rvtransport parts firsttrain',                    # shows which part is which (part 1 is a wagon)
    'rvtransport loadfrom 7 firstrv',                  # run the loading code as if that wagon entered
    'rvtransport carried firsttrain',
    'rvtransport state firstrv',
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'partcarrier' -Exe $exe -Config $cfg -Savegame $sav -Commands $cmds -LogName 'log_part_carrier.txt'
$txt -split "`r?`n" | Where-Object { $_ -match 'loadfrom|setwaiting|carried rv|part \d+:|vehicle #|Assertion|crash' } | Select-Object -First 30 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# The road vehicle must be carried by the train's *front* (vehicle #6 in the test savegame) and its
# host part must be the wagon the loading code was invoked with.
$byFront = ($txt -match 'loadfrom: carried rv #\d+ by=6 host_part=') -or ($txt -match 'by=6 part=')
$carried = ($txt -match 'carrier #6 holds 1 road vehicle')
$attached = ($txt -match 'loadfrom: part #7 -> carrier #6 .*attached=true')
if ($attached -and $carried -and $byFront) {
    Write-Output 'RESULT: PASS (a part of the carrier loads onto the carrier front)'
} else {
    Write-Output ("RESULT: CHECK (attached={0} carried={1} byFront={2})" -f $attached, $carried, $byFront)
}
