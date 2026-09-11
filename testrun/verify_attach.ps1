# Verify the RoRo attach/detach transactions on the tester's savegame (read-only load).
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
    'rvtransport state firsttrain',
    'rvtransport attach firsttrain firstrv force',
    'rvtransport state firstrv',
    'rvtransport state firsttrain',
    'rvtransport list',
    'rvtransport carried firsttrain',
    'rvtransport detach firsttrain 0 force',
    'rvtransport carried firsttrain',
    'rvtransport state firsttrain',
    'rvtransport state firstrv',
    'quit'
)
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 5 }
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_attach_verify.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))
$txt -split "`r?`n" | Where-Object { $_ -match 'attach|detach|transport state|carried|carrier #|rv #|carrying|on_board|Assertion|crash|SELFTEST' } | Select-Object -First 30 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion|crash encountered') { Write-Output 'RESULT: FAIL (crash)'; exit 1 }
$attached = ($txt -match 'attach: ok \(on board=1')
$listedWhileCarried = ($txt -match 'carrier #6 holds 1 road vehicle')
$listedEmpty = ($txt -match 'carrier #6 holds 0 road vehicle')
$detached = ($txt -match 'detach: ok')

# The carrier's cached weight must include the carried road vehicle while it is on board, and go back
# to its own weight afterwards (rvtransport state prints carried= / total_incl_carried= / own=).
$weights = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match 'weights: carried=(\d+)t total_incl_carried=(\d+)t own=(\d+)t') {
        $weights += ,@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
}
$weightOk = $false
if ($weights.Count -ge 3) {
    # Order: before attach (carried 0), while carried (carried > 0 and total = own + carried), after detach (carried 0 again)
    $before = $weights[0]; $whileCarried = $weights[1]; $after = $weights[2]
    $weightOk = ($before[0] -eq 0) -and ($whileCarried[0] -gt 0) -and ($whileCarried[1] -eq ($whileCarried[2] + $whileCarried[0])) -and ($after[0] -eq 0)
}
Write-Output ("weight readings: " + (($weights | ForEach-Object { "carried=$($_[0]) total=$($_[1]) own=$($_[2])" }) -join ' | '))
if ($attached -and $listedWhileCarried -and $detached -and $listedEmpty -and $weightOk) {
    Write-Output 'RESULT: PASS (attach/detach, carrying list, and the carrier weight includes the carried vehicle)'
} else {
    Write-Output ("RESULT: CHECK (attached={0} listed={1} detached={2} emptyAfter={3} weight={4})" -f $attached, $listedWhileCarried, $detached, $listedEmpty, $weightOk)
}
