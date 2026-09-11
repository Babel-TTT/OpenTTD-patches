# Verify the "waiting to be transported" state against the game clock.
#
# Reported bug: a road vehicle which arrived at a station and started waiting lost that state on the
# very next tick, so it drove off again and no carrier could ever load it. The older scripts missed
# this because they all pause the game (and `rvtransport sim` sets the state and loads the vehicle in
# the same command), so the tick path (RoadVehController -> RVTransportTickWaiting) was never run.
#
# This script therefore lets the game tick with a waiting vehicle:
#   1. put the vehicle's current order on a station order which asks to wait (`setcurrent ... loading`
#      emulates the state it has right after arriving), set the waiting state, unpause for a moment
#      and check that it is *still* waiting (this is the regression);
#   2. point its current order at a depot order instead, unpause and check that the waiting state is
#      given up again (the M11b behaviour, which must keep working).
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

$cmds = @(
    'pause',
    # Keep the train out of the picture, otherwise it could load the vehicle while the game runs and
    # the "still waiting" check below would be meaningless.
    'rvtransport setcurrent firsttrain 3',           # a depot order: no station loading
    'rvtransport orders firstrv',
    'rvtransport setcurrent firstrv 0 loading',      # arrives at the station order which asks to wait
    'rvtransport wait firstrv on',
    'rvtransport state firstrv',
    'unpause',                                        # let the game tick (~1.2 s between commands)
    'pause',
    'rvtransport state firstrv',                      # must still be waiting (the regression)
    'rvtransport modify firstrv 0 load',              # uncheck "wait to be transported" in the order
    'unpause',
    'pause',
    'rvtransport state firstrv',                      # must have given up waiting now
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'waittick' -Exe $exe -Config $cfg -Savegame $sav -Commands $cmds -LogName 'log_wait_tick.txt' -DelaySec 1.2
$txt -split "`r?`n" | Where-Object { $_ -match 'setcurrent|vehicle #|flags=|Assertion|crash' } | Select-Object -First 30 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# Collect the three states: after setting it up, after ticking with a station order, and after
# ticking with a depot order.
$states = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match '^vehicle #\d+: type=1 flags=(\d+)') { $states += [int]$Matches[1] }
}
# The waiting flag is RVTF_WAITING = 1.
$waiting = @($states | ForEach-Object { ($_ -band 1) -ne 0 })
Write-Output ("waiting flag readings: " + (($waiting | ForEach-Object { if ($_) { 'set' } else { 'clear' } }) -join ' | '))
$keptWhileStationOrder = ($waiting.Count -ge 2) -and $waiting[1]
$clearedForDepotOrder  = ($waiting.Count -ge 3) -and (-not $waiting[2])
if ($keptWhileStationOrder -and $clearedForDepotOrder) {
    Write-Output 'RESULT: PASS (waiting survives ticking with a station order and is given up for a depot order)'
} else {
    Write-Output ("RESULT: CHECK (kept={0} cleared={1}, readings={2})" -f $keptWhileStationOrder, $clearedForDepotOrder, ($states -join ','))
}
