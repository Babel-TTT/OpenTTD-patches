# Diagnostic: load the savegame from the user's crash report and inspect the RoRo state there,
# including a headless run of the vehicle details drawing code ("rvtransport drawtest").
#
# Usage: powershell -File testrun\probe_user_crash.ps1 [-SaveName crash-20260911T125152Z.sav]
param([string]$SaveName = 'crash-20260911T125152Z.sav')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe = Join-Path $root 'build\openttd.exe'
$cfg = Join-Path $root 'build\roro-test.cfg'
$tr = Join-Path $root 'testrun'
$sav = Join-Path 'C:\Users\11936\Documents\OpenTTD' $SaveName
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

# The user's map uses a large NewGRF set, so allow plenty of time for the load.
Start-Sleep -Seconds 120

$cmds = @(
    'pause',
    'rvtransport list',
    'rvtransport state firsttrain',
    'rvtransport parts firsttrain',
    'rvtransport carried firsttrain',
    'rvtransport vscroll firsttrain',
    'rvtransport state firstrv',
    'quit'
)
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 4 }
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_probe_user_crash.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))

$txt -split "`r?`n" | Where-Object { $_ -match 'rv #|carrier|carrying|weights|drawtest|attach|Assertion|crash|error|NewGRF' } | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
