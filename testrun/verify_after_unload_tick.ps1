# Verify that nothing is left behind at the station a road vehicle was picked up at, and that the game
# survives the ticks after it is put back on the road.
#
# Reported crashes (crash-20260911T161757Z / T161848Z):
#   economy.cpp:1947 assert(front->current_order.IsType(OT_LOADING))   in LoadUnloadStation
#   economy.cpp:1536 assert(front_v->cargo_payment == nullptr)         in PrepareUnload
# A road vehicle which arrives at a station runs Vehicle::BeginLoading() -> PrepareUnload(), which puts
# it in the station's list of loading vehicles and gives it a CargoPayment. Loading it onto a carrier
# used to leave both behind, so the old station kept processing it (and asserted once its order had
# moved on) and the next station it arrived at asserted that it still had a cargo payment.
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

$cmds = @(
    'pause',
    # The savegame's truck is already waiting at the station of the train's current order, i.e. it has
    # been through the engine's own arrival (Vehicle::BeginLoading() -> PrepareUnload()), so it still
    # has the station's loading entry and a cargo payment of its own.
    'rvtransport invariants firstrv',
    'rvtransport loadfrom 7 firstrv',              # load it: the station stop must be finished for it
    'rvtransport invariants firstrv',
    'rvtransport carried firsttrain',
    'rvtransport detach firsttrain 0',             # put it down at the station it wants off at
    'rvtransport invariants firstrv',
    'unpause',                                     # now let the game tick: this is where it crashed
    'pause',
    'rvtransport invariants firstrv',
    'rvtransport state firstrv',
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'afterunload' -Exe $exe -Config $cfg -Savegame $sav -Commands $cmds -LogName 'log_after_unload.txt'
$txt -split "`r?`n" | Where-Object { $_ -match 'arrive:|invariants:|loadfrom|detach:|carrier #|vehicle #|Assertion|crash' } | Select-Object -First 25 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# The two readings around the loading: dirty (the vehicle is loading at that station) and then clean.
$states = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match 'invariants: vehicle #\d+ in a station loading list=(\w+) cargo_payment=(\w+)') {
        $states += ,@{ List = $Matches[1]; Payment = $Matches[2] }
    }
}
$dirtyBeforeLoad = ($states.Count -ge 1) -and ($states[0].List -eq 'true') -and ($states[0].Payment -eq 'true')
$cleanAfterLoad  = ($states.Count -ge 2) -and ($states[1].List -eq 'false') -and ($states[1].Payment -eq 'false')
$tickedAndAlive  = ($txt -match 'invariants: vehicle #\d+ in a station loading list=')
Write-Output ("invariant readings: " + (($states | ForEach-Object { "list=$($_.List) payment=$($_.Payment)" }) -join ' | '))
if ($dirtyBeforeLoad -and $cleanAfterLoad -and $tickedAndAlive) {
    Write-Output 'RESULT: PASS (the station stop is finished when the vehicle is loaded, and the ticks afterwards are clean)'
} else {
    Write-Output ("RESULT: CHECK (dirtyBeforeLoad={0} cleanAfterLoad={1} ticked={2})" -f $dirtyBeforeLoad, $cleanAfterLoad, $tickedAndAlive)
}
