# Simulate the full RoRo chain on the tester's savegame: waiting -> scan -> attach.
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
    'rvtransport orders firsttrain',
    'rvtransport orders firstrv',
    'rvtransport sim firsttrain firstrv',
    'rvtransport state firstrv',
    'rvtransport list',
    'quit'
)
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 5 }
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_sim.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))
$txt -split "`r?`n" | Where-Object { $_ -match 'rvtransport|sim:|orders|\[|vehicle #|rv #|carrying|on_board|Assertion|crash' } | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
