# Verify that a road vehicle is moved on to the "get off here" order when it is loaded, and that a
# carrier only drops it at the station that order names.
#
# A road vehicle which is carried more than once (train from A to B, drive to C, ship from C to D)
# marks one drop-off station per leg. Reading only the first "be unloaded here" order of the whole list
# kept such a vehicle on board of every carrier after the first leg, so the vehicle is now moved on to
# its next order when it is loaded, and the carrier compares its unload station with that order.
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

# The test savegame: the truck's orders are
#   [3] station 1 'Wunfingley Market 中央'  RV_LOAD    <- the "wait to be transported" order it is on
#   [4] station 0 'Wunfingley Market 站'    RV_UNLOAD  <- where it wants to get off
# and the train it is loaded onto sits at station 1, i.e. the carrier's station is *not* the one the
# truck wants to get off at.
$cmds = @(
    'pause',
    'rvtransport setwaiting firsttrain firstrv',   # the truck waits at the train's station
    'rvtransport orders firstrv',
    'rvtransport loadfrom 7 firstrv',              # load it (through a wagon, as a ship part would)
    'rvtransport orders firstrv',                  # the current order must have moved on to [4]
    'rvtransport detach firsttrain 1',             # wrong station: must stay on board
    'rvtransport carried firsttrain',
    'rvtransport detach firsttrain 0',             # the station it names: must be dropped
    'rvtransport carried firsttrain',
    # Let the game tick after the unload. This is what caught the reported crash: the vehicle used to
    # stay in the *boarding* station's list of loading vehicles, and as soon as it was put back on the
    # road that station processed it as a loading vehicle and asserted, because its current order has
    # moved on by then.
    'unpause',
    'pause',
    'rvtransport state firstrv',
    'rvtransport state firsttrain',
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'unloadmatch' -Exe $exe -Config $cfg -Savegame $sav -Commands $cmds -LogName 'log_unload_match.txt'
$txt -split "`r?`n" | Where-Object { $_ -match 'loadfrom|detach:|carrier #|has \d+ orders|^\s+\[\d\]|vehicle #|Assertion|crash' } | Select-Object -First 30 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# The order index of the truck in the two `orders` dumps, before and after loading.
$indices = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match 'vehicle #8 type=1 has \d+ orders \(current index (\d+)\)') { $indices += [int]$Matches[1] }
}
$advanced = ($indices.Count -ge 2) -and ($indices[1] -eq 4) -and ($indices[0] -eq 3)
# The truck is not moved to a station which is not its own: `detach ... 1` fails, `detach ... 0` works.
$keptAtWrongStation = ($txt -match 'detach: failed \(on board=1')
$droppedAtOwnStation = ($txt -match 'detach: ok \(on board=0')

Write-Output ("order index readings: " + ($indices -join ' -> ') + " (expected 3 -> 4)")
if ($advanced -and $keptAtWrongStation -and $droppedAtOwnStation) {
    Write-Output 'RESULT: PASS (loading moves the vehicle on to its drop-off order, and the carrier only drops it there)'
} else {
    Write-Output ("RESULT: CHECK (advanced={0} kept={1} dropped={2})" -f $advanced, $keptAtWrongStation, $droppedAtOwnStation)
}
