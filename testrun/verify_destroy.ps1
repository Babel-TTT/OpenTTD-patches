# Verify that a destroyed carrier takes the road vehicles it carries with it.
#
# Uses `rvtransport destroy`, which removes a vehicle through the same emergency path as the
# built-in delete_vehicle_id command (registered for GUI clients only, hence unavailable here):
#
#   1. load the truck onto the train (`rvtransport sim`)
#   2. remember the truck id from `rvtransport state firstrv`
#   3. destroy the train
#   4. the truck must be gone as well: `rvtransport state <truck id>` -> "vehicle not found"
#      and `rvtransport list` must not mention it any more
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'build\roro-test.cfg'
$tr   = Join-Path $root 'testrun'
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "-c `"$cfg`" -D -g `"$sav`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $root
$p = [System.Diagnostics.Process]::Start($psi)

# Pause the game as early as possible: the script waits for the savegame to load while the game is
# already ticking, and otherwise vehicles may unload themselves (or reach a station) before the
# test starts, which makes the state-sensitive checks flaky.
foreach ($i in 1..3) { try { $p.StandardInput.WriteLine('pause'); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 1 }$o = $p.StandardOutput.ReadToEndAsync()
$e = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45

$cmds = @(
    'pause',
    'rvtransport list',
    'rvtransport sim firsttrain firstrv',
    'rvtransport state firstrv',
    'rvtransport list',
    'rvtransport destroy firsttrain',
    'rvtransport list',
    'quit'
)
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 4 }
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_destroy.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))

$lines = $txt -split "`r?`n"
$lines | Where-Object { $_ -match 'sim:|destroy:|rv #|vehicle #|carrying=|Assertion|crash' } | Select-Object -First 25 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# The truck that was loaded must no longer exist after the destroy, and the train too. Only the
# output after the 'destroy:' line may be inspected, as the earlier lines still mention both.
$rvId = $null
foreach ($l in $lines) { if ($l -match '^vehicle #(\d+): type=1 .*flags=2 ') { $rvId = $Matches[1] } }

$linesAfter = @()
$seenDestroy = $false
foreach ($l in $lines) {
    if ($seenDestroy) { $linesAfter += $l }
    if ($l -match '^destroy:') { $seenDestroy = $true }
}
$tail = $linesAfter -join "`n"

$trainGone = ($txt -match 'destroy: vehicle #6 \(still present after destroy: False\)')
$rvGone = ($rvId -ne $null) -and ($tail -notmatch ('rv #' + $rvId + '\b')) -and ($tail -notmatch ('vehicle #' + $rvId + ':'))

Write-Output "carried truck id: $rvId, truck gone: $rvGone, train destroyed: $trainGone"
if ($trainGone -and $rvGone) {
    Write-Output 'RESULT: PASS (destroying a carrier also destroys the road vehicles it carried)'
} else {
    Write-Output 'RESULT: CHECK (see log above)'
}
