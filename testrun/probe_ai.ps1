# Probe available AIs / game scripts (to let an AI build the test scenario). ASCII only.
$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'testrun\openttd.cfg'
$tr   = Join-Path $root 'testrun'
$sav  = Join-Path $tr 'save\m1test.sav'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
if (Test-Path $sav) { $psi.Arguments = "-c `"$cfg`" -D -g `"$sav`"" } else { $psi.Arguments = "-c `"$cfg`" -D -G 12345" }
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $root
$p = [System.Diagnostics.Process]::Start($psi)
$o = $p.StandardOutput.ReadToEndAsync()
$e = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45
foreach ($c in @('list_ai', 'list_game', 'list_ai_libs', 'companies')) {
    try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}
    Start-Sleep -Seconds 4
}
try { $p.StandardInput.WriteLine('quit'); $p.StandardInput.Flush() } catch {}
Start-Sleep -Seconds 4
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$t = ""
try { $t += $o.Result } catch {}
try { $t += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_probe_ai.txt'), $t, (New-Object System.Text.UTF8Encoding($false)))
$t -split "`r?`n" | Select-Object -Last 40 | ForEach-Object { Write-Output $_ }
