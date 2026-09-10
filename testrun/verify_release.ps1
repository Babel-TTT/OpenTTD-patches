# Verify emergency release of a carried road vehicle.
# Uses the debug subcommand `rvtransport release`, which calls the same RVTransportForceRelease()
# that Vehicle::PreDestructor() uses when a carrier is destroyed. (`delete_vehicle_id` is not
# registered on a dedicated server, so it cannot be used to destroy a carrier from the console.)
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav', [string]$carrierId = '6')

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
$o = $p.StandardOutput.ReadToEndAsync()
$e = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45
$cmds = @(
    'rvtransport sim firsttrain firstrv',
    'rvtransport state firstrv',
    'rvtransport release firstrv',
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
[System.IO.File]::WriteAllText((Join-Path $tr 'log_release.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))
$txt -split "`r?`n" | Where-Object { $_ -match 'sim:|vehicle #|delete|rv #|Assertion|crash|unknown command' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }
if ($txt -match 'Assertion|crash encountered') { Write-Output 'RESULT: FAIL (crash)'; exit 1 }
if ($txt -match 'flags=0 .*hidden=false') { Write-Output 'RESULT: PASS (carried vehicle released and back on the road)' } else { Write-Output 'RESULT: CHECK (see log above)' }
