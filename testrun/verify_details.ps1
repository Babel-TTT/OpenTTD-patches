# Verify the line accounting of the train details window for the carried road vehicles.
#
# Two places list them:
#   * the "vehicles" (information) tab ends with a "Carried road vehicles:" header plus one line per
#     road vehicle;
#   * the "carried" tab lists them, one per line (and one line saying that there are none), and clicking
#     a line opens the window of that vehicle.
# The window is scrolled by the number of lines GetTrainDetailsWndVScroll() reports, so if that number
# does not match the lines that are drawn the list cannot be reached (or drawing walks past its end).
#
# Drawing and clicking cannot be exercised without a GUI, so this script checks the line accounting
# (`rvtransport vscroll`) and the line -> vehicle mapping the click handler uses (`rvtransport row`).
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

$cmds = @(
    'pause',
    'rvtransport vscroll firsttrain',            # nothing carried yet
    'rvtransport sim firsttrain firstrv',        # load a road vehicle
    'rvtransport carried firsttrain',
    'rvtransport vscroll firsttrain',            # the vehicles tab must now have 2 lines more
    'rvtransport row firsttrain 0',              # the "carried" tab: line 0 is the vehicle just loaded
    'rvtransport row firsttrain 5',              # ... and a line past the end has nothing
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'details' -Exe $exe -Config $cfg -Savegame $sav -Commands $cmds -LogName 'log_details_verify.txt'

$txt -split "`r?`n" | Where-Object { $_ -match 'vscroll|row:|carrying|carrier #|Assertion|crash' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

$lines = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match 'vscroll: train #(\d+) lines per tab: cargo=(\d+) info=(\d+) capacity=(\d+) totals=(\d+) perf=(\d+) carried_tab=(\d+), carried=(\d+)') {
        $lines += ,@{ Info = [int]$Matches[3]; CarriedTab = [int]$Matches[7]; Carried = [int]$Matches[8] }
    }
}
$ok = $false
if ($lines.Count -ge 2) {
    $before = $lines[0]; $after = $lines[1]
    # Before loading: nothing carried, so the tab has its single "none" line. After loading: one line per
    # vehicle, and the information tab grew by a header plus one line per vehicle.
    $ok = ($before.Carried -eq 0) -and ($before.CarriedTab -eq 1) -and
          ($after.Carried -eq 1) -and ($after.CarriedTab -eq 1) -and
          ($after.Info -eq ($before.Info + $after.Carried + 1))
}
# Line 0 of the carried tab is a real vehicle; a line past its end is not.
$rowOk = ($txt -match 'row: carrier #\d+ line 0 -> rv #\d+') -and ($txt -match 'row: carrier #\d+ line 5 has no road vehicle')
Write-Output ("vscroll readings: " + (($lines | ForEach-Object { "info=$($_.Info) carried_tab=$($_.CarriedTab) carried=$($_.Carried)" }) -join ' | ') + ", row mapping ok=$rowOk")
if ($ok -and $rowOk) {
    Write-Output 'RESULT: PASS (both carried lists are accounted for, and a carried-tab line names its vehicle)'
} else {
    Write-Output 'RESULT: CHECK (see the readings above)'
}
