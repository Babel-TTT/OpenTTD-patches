# Run the RoRo selftest on several candidate savegames (ASCII only).
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File testrun\run_selftest.ps1
$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Join-Path $root 'testrun\openttd.cfg'
$tr   = Join-Path $root 'testrun'
$saveDir = Join-Path $env:USERPROFILE 'Documents\OpenTTD\save'

$cfgText = "[network]`r`nserver_name = M1Test`r`nserver_port = 3989`r`n[misc]`r`nlanguage = english.lng`r`n"
[System.IO.File]::WriteAllText($cfg, $cfgText, (New-Object System.Text.UTF8Encoding($false)))

$candidates = @('a1.sav', 'a2.sav', '1.sav', 'Test.sav')

function Run-Selftest([string]$srcSave) {
    $tmp = Join-Path $tr 'input.sav'
    Copy-Item $srcSave $tmp -Force
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "-c `"$cfg`" -D -G `"$tmp`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds 45
    try { $p.StandardInput.WriteLine('rvtransport selftest'); $p.StandardInput.Flush() } catch {}
    Start-Sleep -Seconds 8
    try { $p.StandardInput.WriteLine('quit'); $p.StandardInput.Flush() } catch {}
    Start-Sleep -Seconds 4
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
    $txt = ""
    try { $txt += $outTask.Result } catch {}
    try { $txt += $errTask.Result } catch {}
    return $txt
}

foreach ($name in $candidates) {
    $path = Join-Path $saveDir $name
    if (-not (Test-Path $path)) { continue }
    Write-Output ("===== {0} ({1} bytes) =====" -f $name, (Get-Item $path).Length)
    $log = Run-Selftest $path
    $interesting = $log -split "`r?`n" | Where-Object { $_ -match 'selftest|SELFTEST|corrupt|failed|error|no suitable|road vehicle' }
    if ($interesting) { $interesting | Select-Object -First 12 | ForEach-Object { Write-Output $_ } }
    else { Write-Output '(no selftest output - load may have failed)' }
}
