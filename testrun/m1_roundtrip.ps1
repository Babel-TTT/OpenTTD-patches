# 存档往返验证脚本 v2（M1 起，每个里程碑复用）
#   步骤1：dedicated 生成地图 -> 等游戏开始 -> save -> 校验存档文件
#   步骤2：dedicated 载入该存档 -> 判读日志/退出码（验证自读自档）
# 用法： powershell.exe -NoProfile -ExecutionPolicy Bypass -File testrun\m1_roundtrip.ps1 [saveName]
param([string]$saveName = 'm1test')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'testrun\openttd.cfg'
$saveDir = Join-Path $root 'testrun\save'
$logDir  = Join-Path $root 'testrun'
New-Item -ItemType Directory -Force -Path $saveDir | Out-Null

# cfg 必须无 BOM，否则 ini 首行组名解析失败
$cfgText = "[network]`r`nserver_name = M1Test`r`nserver_port = 3989`r`n[misc]`r`nlanguage = english.lng`r`n"
[System.IO.File]::WriteAllText($cfg, $cfgText, (New-Object System.Text.UTF8Encoding($false)))

$sav = Join-Path $saveDir "$saveName.sav"
Remove-Item $sav -ErrorAction SilentlyContinue

function Start-Ottd([string]$arguments, [string]$logName) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:outTask = $p.StandardOutput.ReadToEndAsync()
    $script:errTask = $p.StandardError.ReadToEndAsync()
    $script:logName = $logName
    return $p
}

function Save-Log($p) {
    $txt = ""
    if ($script:outTask) { try { $txt += $script:outTask.Result } catch {} }
    if ($script:errTask) { try { $txt += $script:errTask.Result } catch {} }
    [System.IO.File]::WriteAllText((Join-Path $logDir $script:logName), $txt, (New-Object System.Text.UTF8Encoding($false)))
    return $txt
}

Write-Output '== step1: generate world + save =='
$p = Start-Ottd "-c `"$cfg`" -D -g 12345" 'step1.log'
Start-Sleep -Seconds 55            # 等地图生成与游戏开始
$p.StandardInput.WriteLine('save m1test')
$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path $sav) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
$savOk = $false
if (Test-Path $sav) {
    Start-Sleep -Seconds 3
    $len = (Get-Item $sav).Length
    Write-Output ("save file: {0} bytes" -f $len)
    $savOk = $len -gt 50000
} else {
    Write-Output 'save file NOT created'
}
try { $p.StandardInput.WriteLine('quit'); Start-Sleep -Seconds 3 } catch {}
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Seconds 2
$log1 = Save-Log $p
Write-Output ("step1 log: {0} chars" -f $log1.Length)
if (-not $savOk) { Write-Output 'RESULT: FAIL (no valid savegame)'; exit 1 }

Write-Output '== step2: load savegame =='
$p2 = Start-Ottd "-c `"$cfg`" -D -g 999 -G `"$sav`"" 'step2.log'
Start-Sleep -Seconds 60
$exitedEarly = $p2.HasExited
Write-Output ("step2 process exited early: {0}" -f $exitedEarly)
try { $p2.StandardInput.WriteLine('quit'); Start-Sleep -Seconds 4 } catch {}
if (-not $p2.HasExited) { try { $p2.Kill() } catch {} }
Start-Sleep -Seconds 2
$log2 = Save-Log $p2
Write-Output ("step2 log: {0} chars" -f $log2.Length)

$bad = @('corrupt', 'failed to load', 'Load game failed', 'error while loading', 'assert')
$hit = @()
foreach ($b in $bad) { if ($log2 -match [regex]::Escape($b)) { $hit += $b } }
if ($hit.Count -gt 0) { Write-Output ("RESULT: FAIL (log contains: {0})" -f ($hit -join ', ')); exit 1 }
if ($exitedEarly) { Write-Output 'RESULT: FAIL (process exited during load)'; exit 1 }
Write-Output 'RESULT: PASS (self save/load round-trip OK)'
