# Old-savegame compatibility check: baseline (pristine 0.73.1) writes a savegame,
# then the fork loads it. ASCII only.
$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$forkExe = Join-Path $root 'build\openttd.exe'
$baseExe = 'D:\CNS\ottd\OpenTTD-patches-baseline\build\openttd.exe'
$cfg = Join-Path $root 'testrun\openttd.cfg'
$tr = Join-Path $root 'testrun'
$saveDir = Join-Path $tr 'save'
$baselineSave = Join-Path $tr 'baseline.sav'

function Run-Ottd([string]$exePath, [string]$argLine, [int]$pre, [string[]]$cmds, [int]$per, [int]$post, [string]$logPath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds $pre
    foreach ($c in $cmds) { try { $p.StandardInput.WriteLine($c); $p.StandardInput.Flush() } catch {}; Start-Sleep -Seconds $per }
    Start-Sleep -Seconds $post
    $early = $p.HasExited
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
    $t = ""
    try { $t += $o.Result } catch {}
    try { $t += $e.Result } catch {}
    [System.IO.File]::WriteAllText($logPath, $t, (New-Object System.Text.UTF8Encoding($false)))
    return @{ Early = $early; Log = $t }
}

Write-Output '== step1: baseline generates + saves (old format) =='
Remove-Item $baselineSave -ErrorAction SilentlyContinue
Remove-Item (Join-Path $saveDir 'baseline.sav') -ErrorAction SilentlyContinue
Run-Ottd $baseExe "-c `"$cfg`" -D -G 777" 45 @('save baseline') 20 5 (Join-Path $tr 'log_base_gen.txt') | Out-Null
$produced = Join-Path $saveDir 'baseline.sav'
if (Test-Path $produced) {
    Copy-Item $produced $baselineSave -Force
    Write-Output ("step1: OK, baseline savegame {0} bytes" -f (Get-Item $baselineSave).Length)
} else {
    Write-Output 'step1: FAILED to produce a baseline savegame'
    exit 1
}

Write-Output '== step2: fork loads the baseline (old) savegame =='
$r = Run-Ottd $forkExe "-c `"$cfg`" -D -g `"$baselineSave`"" 45 @('quit') 5 5 (Join-Path $tr 'log_fork_oldload.txt')
$bad = @('corrupt', 'failed to load', 'Assertion failed', 'invalid chunk', 'Invalid generation seed')
$hit = @()
foreach ($b in $bad) { if ($r.Log -match [regex]::Escape($b)) { $hit += $b } }
if ($hit.Count -gt 0) { Write-Output ("step2: FAIL (log contains: {0})" -f ($hit -join ', ')); exit 1 }
if ($r.Early) { Write-Output 'step2: FAIL (process exited during load)'; exit 1 }
Write-Output 'step2: PASS (fork loads pristine 0.73.1 savegame)'
