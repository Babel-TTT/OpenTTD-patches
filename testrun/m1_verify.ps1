# M1/M2 verification v5 (ASCII only) - fixed command line flags.
#   OpenTTD flags: -g <savegame> = load, -G <seed> = generate new map.
#   Part A: load a savegame produced by the pristine baseline exe (testrun\baseline.sav), if present
#   Part B: generate world -> save -> reload it (self round-trip)
$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'testrun\openttd.cfg'
$tr   = Join-Path $root 'testrun'
$saveDir = Join-Path $tr 'save'
New-Item -ItemType Directory -Force -Path $saveDir | Out-Null
$saveName = 'm1test'
$oldSave = Join-Path $tr 'baseline.sav'

$cfgText = "[network]`r`nserver_name = M1Test`r`nserver_port = 3989`r`n[misc]`r`nlanguage = english.lng`r`n[gui]`r`nautosave = monthly`r`n"
[System.IO.File]::WriteAllText($cfg, $cfgText, (New-Object System.Text.UTF8Encoding($false)))

function Run-Ottd([string]$arguments, [string]$logName, [int]$runSeconds, [int]$cmdDelay, [string[]]$commands) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($cmdDelay -gt 0) { Start-Sleep -Seconds $cmdDelay }
    if ($commands) {
        foreach ($c in $commands) {
            try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}
            Start-Sleep -Seconds 6
        }
    }
    Start-Sleep -Seconds $runSeconds
    $early = $p.HasExited
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
    $txt = ""
    try { $txt += $outTask.Result } catch {}
    try { $txt += $errTask.Result } catch {}
    [System.IO.File]::WriteAllText((Join-Path $tr $logName), $txt, (New-Object System.Text.UTF8Encoding($false)))
    return @{ Early = $early; Log = $txt }
}

function Test-BadLog([string]$log) {
    $bad = @('corrupt', 'failed to load', 'Load game failed', 'error while loading', 'Assertion failed', 'invalid chunk', 'Invalid generation seed')
    $hit = @()
    foreach ($b in $bad) { if ($log -match [regex]::Escape($b)) { $hit += $b } }
    return $hit
}

Write-Output '== Part A: load baseline-produced savegame (old format) =='
if (Test-Path $oldSave) {
    $rA = Run-Ottd "-c `"$cfg`" -D -g `"$oldSave`"" 'log_oldload.txt' 40 40 @('quit')
    $hitA = Test-BadLog $rA.Log
    if ($hitA.Count -eq 0) { Write-Output 'Part A: PASS (baseline savegame loads in fork)' }
    else { Write-Output ("Part A: FAIL (log contains: {0})" -f ($hitA -join ', ')) }
} else {
    Write-Output ("Part A: SKIP (no baseline savegame yet: {0})" -f $oldSave)
}

Write-Output '== Part B: generate + save + reload =='
$sav = Join-Path $saveDir "$saveName.sav"
Remove-Item $sav -ErrorAction SilentlyContinue
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "-c `"$cfg`" -D -G 12345"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $root
$p = [System.Diagnostics.Process]::Start($psi)
$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 45
for ($i = 0; $i -lt 3 -and -not (Test-Path $sav); $i++) {
    try { $p.StandardInput.WriteLine("save $saveName"); $p.StandardInput.Flush() } catch {}
    Start-Sleep -Seconds 12
}
try { $p.StandardInput.WriteLine('quit'); $p.StandardInput.Flush() } catch {}
Start-Sleep -Seconds 4
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$logB1 = ""
try { $logB1 += $outTask.Result } catch {}
try { $logB1 += $errTask.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $tr 'log_step1.txt'), $logB1, (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-Path $sav)) { Write-Output 'Part B: FAIL (no savegame produced)'; exit 1 }
Write-Output ("Part B: savegame ready: {0} bytes" -f (Get-Item $sav).Length)

$rB = Run-Ottd "-c `"$cfg`" -D -g `"$sav`"" 'log_step2.txt' 40 40 @('quit')
$hitB = Test-BadLog $rB.Log
if ($hitB.Count -eq 0) { Write-Output 'Part B: PASS (self save/load round-trip OK)' } else { Write-Output ("Part B: FAIL (log contains: {0})" -f ($hitB -join ', ')); exit 1 }
