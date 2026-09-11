# Regression: savegame round-trip while a road vehicle is being transported.
#   phase 1: load savegame -> load a road vehicle onto a train -> save as roro_intransit -> quit
#   phase 2: load roro_intransit -> check the carried state survived -> unload -> check restoration
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'build\roro-test.cfg'
$tr   = Join-Path $root 'testrun'
$saveDir = Join-Path $root 'build\save'
$src  = Join-Path $saveDir $saveName
$tmp  = Join-Path $tr 'intransit_input.sav'
$made = Join-Path $saveDir 'roro_intransit.sav'

if (-not (Test-Path $src)) { Write-Output "savegame not found: $src"; exit 1 }
Copy-Item $src $tmp -Force
Remove-Item $made -ErrorAction SilentlyContinue

function Run-Ottd([string]$argLine, [string[]]$cmds, [int]$settle, [string]$logName) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)

# Pause the game as early as possible: the script waits for the savegame to load while the game is
# already ticking, and otherwise vehicles may unload themselves (or reach a station) before the
# test starts, which makes the state-sensitive checks flaky.
foreach ($i in 1..3) { try { $p.StandardInput.WriteLine('pause'); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 1 }
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds $settle
    foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 6 }
    Start-Sleep -Seconds 8
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
    $txt = ""
    try { $txt += $o.Result } catch {}
    try { $txt += $e.Result } catch {}
    [System.IO.File]::WriteAllText((Join-Path $tr $logName), $txt, (New-Object System.Text.UTF8Encoding($false)))
    return $txt
}

Write-Output '== phase 1: load a road vehicle, then save while it is carried =='
$log1 = Run-Ottd "-c `"$cfg`" -D -g `"$tmp`"" @('rvtransport sim firsttrain firstrv', 'rvtransport state firstrv', 'save roro_intransit', 'quit') 45 'log_intransit1.txt'
$log1 -split "`r?`n" | Where-Object { $_ -match 'sim:|vehicle #|successfully saved|Saving map|failed' } | Select-Object -First 8 | ForEach-Object { Write-Output $_ }
if (-not (Test-Path $made)) { Write-Output 'FAIL: savegame was not written'; exit 1 }
Write-Output ("saved: {0} bytes" -f (Get-Item $made).Length)

Write-Output '== phase 2: reload it and check the carried state survived =='
$log2 = Run-Ottd "-c `"$cfg`" -D -g `"$made`"" @('rvtransport state firstrv', 'rvtransport list', 'rvtransport detach firsttrain 0 force', 'rvtransport state firstrv', 'quit') 45 'log_intransit2.txt'
$log2 -split "`r?`n" | Where-Object { $_ -match 'vehicle #|rv #|carrying|detach:|Assertion|crash|corrupt|failed' } | Select-Object -First 15 | ForEach-Object { Write-Output $_ }

$crash = ($log2 -match 'Assertion|corrupt|failed to load')
$carriedAfterLoad = ($log2 -match 'flags=2')
$restored = ($log2 -match 'detach: ok')
Write-Output ("carried state survived load: {0}" -f $carriedAfterLoad)
Write-Output ("unload after load: {0}" -f $restored)
if ($crash) { Write-Output 'RESULT: FAIL (crash/corruption during reload)'; exit 1 }
if ($carriedAfterLoad -and $restored) { Write-Output 'RESULT: PASS (carried state survives save/load, and unload still works)' } else { Write-Output 'RESULT: FAIL'; exit 1 }
