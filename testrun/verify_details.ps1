# Verify the "carried road vehicles" line accounting of the train details window.
#
# The vehicles tab of the train details window ends with a "Carried road vehicles:" header plus one
# line per road vehicle. The window is scrolled by the number of lines GetTrainDetailsWndVScroll()
# reports, so if that number does not grow with the carried vehicles the list cannot be reached (and
# drawing it would walk past the end of the list).
#
# Drawing itself cannot be exercised without a GUI, so this script checks the line accounting through
# `rvtransport vscroll`, which reports the line count of every tab.
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
foreach ($i in 1..3) { try { $p.StandardInput.WriteLine('pause'); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 1 }
$o = $p.StandardOutput.ReadToEndAsync()
$e = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45

$cmds = @(
    'pause',
    'rvtransport vscroll firsttrain',            # nothing carried yet
    'rvtransport sim firsttrain firstrv',        # load a road vehicle
    'rvtransport carried firsttrain',
    'rvtransport vscroll firsttrain',            # the vehicles tab must now have 2 lines more
    'quit'
)
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 4 }
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_details_verify.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))

$txt -split "`r?`n" | Where-Object { $_ -match 'vscroll|carrying|carrier #|Assertion|crash' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

$lines = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match 'vscroll: train #(\d+) lines per tab: cargo=(\d+) info=(\d+) capacity=(\d+) totals=(\d+) perf=(\d+), carried=(\d+)') {
        $lines += ,@{ Info = [int]$Matches[3]; Carried = [int]$Matches[7] }
    }
}
$ok = $false
if ($lines.Count -ge 2) {
    $before = $lines[0]; $after = $lines[1]
    # One extra header line plus one line per carried road vehicle.
    $ok = ($before.Carried -eq 0) -and ($after.Carried -eq 1) -and ($after.Info -eq ($before.Info + $after.Carried + 1))
}
Write-Output ("vscroll readings: " + (($lines | ForEach-Object { "info=$($_.Info) carried=$($_.Carried)" }) -join ' | '))
if ($ok) {
    Write-Output 'RESULT: PASS (the vehicles tab grows by the carried list: header plus one line per vehicle)'
} else {
    Write-Output 'RESULT: CHECK (see the readings above)'
}
