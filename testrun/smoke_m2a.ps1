# M2a smoke test on a self-generated empty map (no user savegames, no NewGRF).
# Loads our own m1test.sav and exercises the rvtransport console command.
$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'testrun\openttd.cfg'
$tr   = Join-Path $root 'testrun'
$sav  = Join-Path $tr 'save\m1test.sav'

if (-not (Test-Path $sav)) { Write-Output "missing $sav - run m1_verify.ps1 first"; exit 1 }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "-c `"$cfg`" -D -G `"$sav`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $root
$p = [System.Diagnostics.Process]::Start($psi)
$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 40
$cmds = @('rvtransport', 'rvtransport selftest', 'rvtransport state 1', 'rvtransport detach 1 0')
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 5 }
try { $p.StandardInput.WriteLine('quit'); $p.StandardInput.Flush() } catch {}
Start-Sleep -Seconds 5
$early = $p.HasExited
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $outTask.Result } catch {}
try { $txt += $errTask.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_smoke_m2a.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))

$crash = @('Assertion failed', 'terminate called', 'Access violation', 'SIGSEGV')
$hit = @()
foreach ($c in $crash) { if ($txt -match [regex]::Escape($c)) { $hit += $c } }
if ($hit.Count -gt 0) { Write-Output ("SMOKE: FAIL (crash: {0})" -f ($hit -join ', ')); $txt -split "`r?`n" | Select-Object -Last 15; exit 1 }
Write-Output 'SMOKE: no crash detected'
$txt -split "`r?`n" | Where-Object { $_ -match 'rvtransport|SELFTEST|RoRo|Usage|vehicle not found|station not found' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }
