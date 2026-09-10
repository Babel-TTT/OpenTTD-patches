# Verify the selection criteria of a carrier's "load road vehicles" order (parameterised filter,
# in the spirit of the px-patch coupling parameters).
#
# The `rvtransport sim` command sets a road vehicle waiting at the carrier's current station and then
# runs the very same scan the loading loop uses, so `scan found=true/false` tells whether the
# criteria accepted the candidate. Every successful load is undone with `release` before the next
# case.
#
# Cases (the truck's own cargo type and cargo are read from `rvtransport state`):
#   1. no criteria                    -> found
#   2. cargo = the truck's own cargo  -> found
#   3. cargo = a different cargo      -> not found
#   4. loadstate empty                -> found iff the truck is empty
#   5. minwait 100 days               -> not found (it just started waiting)
#   6. minwait 0                      -> found
#   7. dest = the truck's declared destination -> found
param([string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'build\roro-test.cfg'
$tr   = Join-Path $root 'testrun'
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

# Probe run first: find out what the road vehicle carries, which cargo types it can carry and which
# station it declares as its destination.
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
Start-Sleep -Seconds 45
$probe = @('rvtransport state firstrv', 'rvtransport orders firsttrain', 'rvtransport sim firsttrain firstrv', 'rvtransport release firstrv', 'quit')
foreach ($c in $probe) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 3 }
Start-Sleep -Seconds 4
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$ptxt = ""
try { $ptxt += $o.Result } catch {}
try { $ptxt += $e.Result } catch {}
$ptxt -split "`r?`n" | Where-Object { $_ -match 'part |cargo:|order \[' } | Select-Object -First 10 | ForEach-Object { Write-Output $_ }

$ownCargo = $null; $stored = $null; $declared = $null
foreach ($l in ($ptxt -split "`r?`n")) {
    if ($l -match 'cargo: type=(\d+) cap=(\d+) stored=(\d+)') { $ownCargo = [int]$Matches[1]; $stored = [int]$Matches[3] }
    if ($l -match 'declared dest of rv=(\d+)') { $declared = [int]$Matches[1] }
}
if ($ownCargo -eq $null) { Write-Output 'RESULT: CHECK (could not read the road vehicle cargo from the state output)'; exit 1 }
$otherCargo = if ($ownCargo -eq 0) { 1 } else { 0 }
if ($declared -eq $null) { Write-Output 'RESULT: CHECK (could not read the declared destination from the sim output)'; exit 1 }

Write-Output "truck cargo type=$ownCargo stored=$stored, other cargo=$otherCargo, declared destination=$declared"

# Collect the declared destination from a sim run (the state output does not show it).
$psi2 = New-Object System.Diagnostics.ProcessStartInfo
$psi2.FileName = $exe
$psi2.Arguments = "-c `"$cfg`" -D -g `"$sav`""
$psi2.UseShellExecute = $false
$psi2.RedirectStandardInput = $true
$psi2.RedirectStandardOutput = $true
$psi2.RedirectStandardError = $true
$psi2.WorkingDirectory = $root
$p2 = [System.Diagnostics.Process]::Start($psi2)
foreach ($i in 1..3) { try { $p2.StandardInput.WriteLine('pause'); $p2.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 1 }
$o2 = $p2.StandardOutput.ReadToEndAsync()
$e2 = $p2.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45

$emptyCase = if ($stored -eq 0) { 'true' } else { 'false' }
$cmds = @(
    # carrier order 0: load road vehicles, no destination match (the criteria are what we test here)
    'rvtransport setflags firsttrain 0 1',
    # 1. no criteria
    'rvtransport criteria firsttrain 0 loadstate any',
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    # 2. cargo: the truck's own cargo type (it can carry it)
    "rvtransport criteria firsttrain 0 cargo $ownCargo",
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    # 3. cargo: a cargo type the truck does not have
    "rvtransport criteria firsttrain 0 cargo $otherCargo",
    'rvtransport sim firsttrain firstrv',
    # 4. loadstate empty
    'rvtransport criteria firsttrain 0 cargo any',
    'rvtransport criteria firsttrain 0 loadstate empty',
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    # 5. minimum waiting time that cannot be met yet
    'rvtransport criteria firsttrain 0 loadstate any',
    'rvtransport criteria firsttrain 0 minwait 100',
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    # 6. no minimum waiting time again
    'rvtransport criteria firsttrain 0 minwait 0',
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    # 7. declared destination of the truck itself
    "rvtransport criteria firsttrain 0 dest $declared",
    'rvtransport sim firsttrain firstrv',
    'rvtransport release firstrv',
    'quit'
)
foreach ($c in $cmds) { try { $p2.StandardInput.WriteLine($c); $p2.StandardInput.Flush() } catch {}; Start-Sleep -Seconds 3 }
Start-Sleep -Seconds 4
if (-not $p2.HasExited) { try { $p2.Kill() } catch {} }
Start-Sleep -Seconds 2
$txt = ""
try { $txt += $o2.Result } catch {}
try { $txt += $e2.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_filter.txt'), $txt, (New-Object System.Text.UTF8Encoding($false)))
$txt -split "`r?`n" | Where-Object { $_ -match 'sim:|criteria:|setflags:|release:' } | Select-Object -First 40 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# Expected sequence of `scan found=` results.
$expected = @('true', 'true', 'false', $emptyCase, 'false', 'true', 'true')
$found = @()
foreach ($l in ($txt -split "`r?`n")) { if ($l -match 'scan found=(\w+)') { $found += $Matches[1] } }

if ($found.Count -eq $expected.Count -and (Compare-Object $expected $found -SyncWindow 0).Count -eq 0) {
    Write-Output 'RESULT: PASS (selection criteria accept and skip candidates as configured)'
} else {
    Write-Output 'RESULT: CHECK (scan results differ)'
    Write-Output ("  expected: " + ($expected -join ', '))
    Write-Output ("  actual:   " + ($found -join ', '))
}
