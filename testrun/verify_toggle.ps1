# Verify the order flag toggling rules of the road vehicle transport check boxes.
#
# The order window toggles ORVTF_* bits through RVTransportToggleOrderFlag(); this script drives the
# very same function through the `rvtransport toggle` debug command on a dedicated server, so the
# rules are checked without a GUI. Expectations (flags are ORVTF_LOAD=1, ORVTF_UNLOAD=2,
# ORVTF_MATCH_DEST=4, ORVTF_WAIT=8):
#
#   carrier: toggle load  0 -> 5   (load + destination match by default)
#            toggle dest  5 -> 1   (match off, load kept)
#            toggle wait  1 -> 9   (wait implies load)
#            toggle wait  9 -> 1
#            toggle load  1 -> 0   (load off clears match and wait as well)
#            toggle unload 0 -> 2  (unloading is independent of loading)
#   road vehicle: setflags 4 then toggle load -> 1 (a road vehicle's own order clears the match)
#                 toggle load 1 -> 0
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
$o = $p.StandardOutput.ReadToEndAsync()
$e = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45

$cmds = @(
    'rvtransport orders firsttrain',
    'rvtransport orders firstrv',
    'rvtransport setflags firsttrain 0 0',
    'rvtransport toggle firsttrain 0 load',
    'rvtransport toggle firsttrain 0 dest',
    'rvtransport toggle firsttrain 0 wait',
    'rvtransport toggle firsttrain 0 wait',
    'rvtransport toggle firsttrain 0 load',
    'rvtransport toggle firsttrain 0 unload',
    'rvtransport setflags firstrv 0 4',
    'rvtransport toggle firstrv 0 load',
    'rvtransport toggle firstrv 0 load',
    'rvtransport setflags firsttrain 0 0',
    'rvtransport setflags firstrv 0 0',
    'quit'
)
foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 3 }
Start-Sleep -Seconds 5
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o.Result } catch {}
try { $txt += $e.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_toggle.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))

$results = @()
$results += ($txt -split "`r?`n") | Where-Object { $_ -match 'toggle:|setflags:|order \[' }
$results | Select-Object -First 40 | ForEach-Object { Write-Output $_ }

# Expected flag transitions, in order of appearance (vehicle ids are ignored on purpose).
$actual = @()
foreach ($line in ($txt -split "`r?`n")) {
    if ($line -match 'flags (\d+) -> (\d+)') { $actual += "$($Matches[1]) -> $($Matches[2])" }
    elseif ($line -match 'order (\d+) -> (\d+)\)') { $actual += "$($Matches[1]) -> $($Matches[2])" }
}
$expected = @('0 -> 0', '0 -> 5', '5 -> 1', '1 -> 9', '9 -> 1', '1 -> 0', '0 -> 2', '0 -> 4', '4 -> 1', '1 -> 0')

if ($txt -match 'Assertion|crash encountered|Desync') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }
if ($actual.Count -ge $expected.Count -and (Compare-Object $expected ($actual | Select-Object -First $expected.Count) -SyncWindow 0).Count -eq 0) {
    Write-Output 'RESULT: PASS (all flag toggling rules behave as expected)'
} else {
    Write-Output 'RESULT: CHECK (flag transitions differ)'
    Write-Output ("  expected: " + ($expected -join ', '))
    Write-Output ("  actual:   " + ($actual -join ', '))
}
