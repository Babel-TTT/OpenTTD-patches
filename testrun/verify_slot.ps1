# Verify the "trace restrict slot" (路签) selection criterion of a carrier's "load road vehicles"
# order: only a road vehicle which is an occupant of that slot may be loaded.
#
# The debug commands used here exist for exactly this purpose (they are stripped before merging):
#   rvtransport mkslot <name>                create a road vehicle slot
#   rvtransport slot <vehicle> <id> on|off   add/remove a vehicle from a slot
#
# Phase 1: reject an invalid slot id, create a road vehicle slot and save the game (so that the slot
#          exists in phase 2 as well).
# Phase 2: load that savegame and check that the criterion only accepts an occupant of the slot.
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'build\roro-test.cfg'
$tr   = Join-Path $root 'testrun'
$saveDir = Join-Path $root 'build\save'
$src  = Join-Path $saveDir $saveName
$made = Join-Path $saveDir 'roro_slot.sav'
if (-not (Test-Path $src)) { Write-Output "savegame not found: $src"; exit 1 }
Remove-Item $made -ErrorAction SilentlyContinue

function Run-Ottd([string]$argLine, [string[]]$cmds, [string]$logName) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    # Pause as early as possible: the game keeps ticking while the savegame loads, and a carrier
    # could unload (or reach a station) before the test even starts.
    foreach ($i in 1..3) { try { $p.StandardInput.WriteLine('pause'); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 1 }
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds 45
    foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 3 }
    Start-Sleep -Seconds 4
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
    $txt = ""
    try { $txt += $o.Result } catch {}
    try { $txt += $e.Result } catch {}
    [System.IO.File]::WriteAllText((Join-Path $tr $logName), $txt, (New-Object System.Text.UTF8Encoding($false)))
    return $txt
}

Write-Output '== phase 1: reject a bogus slot, create a road vehicle slot, save =='
$log1 = Run-Ottd "-c `"$cfg`" -D -g `"$src`"" @(
    'rvtransport setflags firsttrain 0 1',
    'rvtransport criteria firsttrain 0 slot 9999',
    'rvtransport mkslot RoRoTestSlot',
    'save roro_slot',
    'quit'
) 'log_slot1.txt'
$log1 -split "`r?`n" | Where-Object { $_ -match 'criteria:|mkslot:|setflags:|slot must be' } | Select-Object -First 6 | ForEach-Object { Write-Output $_ }

$invalidRejected = ($log1 -match "slot must be <slot id>, 'any' or 'none'")
$slotId = $null
foreach ($l in ($log1 -split "`r?`n")) { if ($l -match 'mkslot: OK .*id=(\d+)') { $slotId = $Matches[1] } }
if ($slotId -eq $null) { Write-Output 'RESULT: CHECK (could not create a road vehicle slot; see log_slot1.txt)'; exit 1 }
if (-not (Test-Path $made)) { Write-Output 'RESULT: CHECK (savegame was not written)'; exit 1 }
Write-Output "created road vehicle slot id=$slotId, saved $( (Get-Item $made).Length ) bytes"

Write-Output '== phase 2: the criterion only accepts an occupant of the slot =='
$log2 = Run-Ottd "-c `"$cfg`" -D -g `"$made`"" @(
    'rvtransport setflags firsttrain 0 1',
    "rvtransport criteria firsttrain 0 slot $slotId",
    'rvtransport sim firsttrain firstrv',
    "rvtransport slot firstrv $slotId on",
    'rvtransport state firstrv',
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    "rvtransport slot firstrv $slotId off",
    'rvtransport sim firsttrain firstrv',
    'quit'
) 'log_slot2.txt'
$log2 -split "`r?`n" | Where-Object { $_ -match 'sim:|criteria:|slot:|setflags:|  slot:' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }

if ($log2 -match 'Assertion|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

$found = @()
foreach ($l in ($log2 -split "`r?`n")) { if ($l -match 'scan found=(\w+)') { $found += $Matches[1] } }
$expected = @('false', 'true', 'false')
$slotAccepted = ($log2 -match ('criteria: OK \(vehicle #\d+ order \d+ slot=' + $slotId + '\)'))

if ($invalidRejected -and $slotAccepted -and $found.Count -eq 3 -and (Compare-Object $expected $found -SyncWindow 0).Count -eq 0) {
    Write-Output 'RESULT: PASS (the slot criterion accepts only an occupant of that slot)'
} else {
    Write-Output 'RESULT: CHECK (unexpected result)'
    Write-Output ("  invalid slot rejected: " + $invalidRejected)
    Write-Output ("  valid slot accepted:   " + $slotAccepted)
    Write-Output ("  expected scans: " + ($expected -join ', ') + "  actual: " + ($found -join ', '))
}
