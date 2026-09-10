# Verify the RoRo order-modify command chain on the tester's own savegame (read-only load).
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'build\roro-test.cfg'
$tr   = Join-Path $root 'testrun'
$sav  = Join-Path $root ("build\save\" + $saveName)

if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }
Write-Output ("using savegame: {0} ({1} bytes)" -f $saveName, (Get-Item $sav).Length)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "-c `"$cfg`" -D -g `"$sav`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $root
$p = [System.Diagnostics.Process]::Start($psi)
$o = $p.StandardOutput.ReadToEndAsync()
$e = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45
$cmds = @(
    'rvtransport list',
    'rvtransport modify firsttrain 0 load',
    'rvtransport modify firsttrain 0 unload',
    'rvtransport modify firsttrain 0 dest',
    'rvtransport modify firstrv 0 load',
    'rvtransport modify firstrv 0 unload',
    'rvtransport list',
    'quit'
)
foreach ($c in $cmds) {
    try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}
    Start-Sleep -Seconds 5
}
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_user_save_verify.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))

$txt -split "`r?`n" | Where-Object { $_ -match 'rvtransport|modify|road vehicles|carriers|rv #|type=|carrying|Assertion|crash' } | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
