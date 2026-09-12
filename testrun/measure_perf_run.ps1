# One half of the A/B performance measurement: run a savegame with the road vehicle transport master
# switch either on or off and report how much game time advances per wall clock second.
#
# With the switch off no road vehicle transport code runs at all, so the difference between the two
# runs is the feature's overhead on this savegame. A dedicated server runs the game loop in real time,
# so if the extra work pushed ticks over the budget the achieved rate drops.
#
# Usage:
#   powershell -File testrun\measure_perf_run.ps1 -Enabled $true  -Save <sav> -Config <cfg> -LoadSec 300
#   powershell -File testrun\measure_perf_run.ps1 -Enabled $false -Save <sav> -Config <cfg> -LoadSec 300
param(
    [Parameter(Mandatory)][ValidateSet('on', 'off')][string]$Switch,
    [Parameter(Mandatory)][string]$Save,
    [string]$Config = '',
    [int]$LoadSec = 300,
    [int]$IntervalSec = 150,
    [int]$Intervals = 2,
    [int]$Port = 3986
)

$Enabled = ($Switch -eq 'on')

$root = 'D:\CNS\ottd\OpenTTD-patches-rvtransport'
$exe  = Join-Path $root 'build\openttd.exe'
if (-not $Config) { $Config = Join-Path $root 'build\roro-test.cfg' }
if (-not (Test-Path $Save)) { Write-Host ("savegame not found: {0}" -f $Save); exit 1 }
$tag = if ($Enabled) { 'on' } else { 'off' }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = "-c `"$Config`" -x -D :$Port -g `"$Save`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $root
$proc = [System.Diagnostics.Process]::Start($psi)
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()

function Send-Cmd([string]$c) {
    try { $proc.StandardInput.WriteLine($c); $proc.StandardInput.Flush() } catch {}
}

foreach ($i in 1..3) { Send-Cmd 'pause'; Start-Sleep -Milliseconds 700 }
Write-Host ("[{0}] waiting {1}s for the savegame to load ..." -f $tag, $LoadSec)
Start-Sleep -Seconds $LoadSec

# A savegame can be stored in a pause mode which `unpause` does not clear (the tester's big savegame
# is such a case: the game clock stayed at the same date forever). A client joining the server clears
# it, so join as a headless dedicated client - the same trick the multiplayer sync test uses - and it
# doubles as proof that the game is really running.
$cpsi = New-Object System.Diagnostics.ProcessStartInfo
$cpsi.FileName = $exe
$cpsi.Arguments = "-c `"$Config`" -x -D -n 127.0.0.1:$Port"
$cpsi.UseShellExecute = $false
$cpsi.RedirectStandardInput = $true
$cpsi.RedirectStandardOutput = $true
$cpsi.RedirectStandardError = $true
$cpsi.WorkingDirectory = $root
$cproc = [System.Diagnostics.Process]::Start($cpsi)
$cOutTask = $cproc.StandardOutput.ReadToEndAsync()
$cErrTask = $cproc.StandardError.ReadToEndAsync()
Write-Host ("[{0}] headless client joining to clear the pause mode ..." -f $tag)
Start-Sleep -Seconds 25
Send-Cmd 'unpause'
Start-Sleep -Seconds 2

Send-Cmd 'setting gui.autosave_interval 0'
Start-Sleep -Milliseconds 800
# Normalise the length of a game day, so that the achieved rate is comparable with the nominal one
# (0.5 game days per wall second at a day length factor of 1): the tester's savegame uses a large
# factor, which alone makes the clock look 20x slower.
Send-Cmd 'setting economy.day_length_factor 1'
Start-Sleep -Milliseconds 800
Send-Cmd 'setting economy.day_length_factor'
Start-Sleep -Milliseconds 800
Send-Cmd ("setting vehicle.rv_transport_enabled {0}" -f $(if ($Enabled) { 'true' } else { 'false' }))
Start-Sleep -Seconds 1
Send-Cmd 'setting vehicle.rv_transport_enabled'
Start-Sleep -Milliseconds 800
Send-Cmd 'dump_veh_stats'
Start-Sleep -Seconds 2
Send-Cmd 'getdate'
Start-Sleep -Seconds 1
Write-Host ("[{0}] measuring {1} intervals of {2}s ..." -f $tag, $Intervals, $IntervalSec)
Send-Cmd 'unpause'
foreach ($i in 1..$Intervals) {
    Start-Sleep -Seconds $IntervalSec
    Send-Cmd 'getdate'
    Start-Sleep -Seconds 1
}
Send-Cmd 'pause'
Start-Sleep -Seconds 1
Send-Cmd 'quit'
Start-Sleep -Seconds 3
if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
try { $cproc.StandardInput.WriteLine('quit'); $cproc.StandardInput.Flush() } catch {}
Start-Sleep -Seconds 2
if (-not $cproc.HasExited) { try { $cproc.Kill() } catch {} }
Start-Sleep -Seconds 1

$text = ""
try { $text += $outTask.Result } catch {}
try { $text += $errTask.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $root ("build\perf_{0}.txt" -f $tag)), $text)
$clientText = ""
try { $clientText += $cOutTask.Result } catch {}
try { $clientText += $cErrTask.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $root ("build\perf_{0}_client.txt" -f $tag)), $clientText)
$clientJoined = ($clientText -match 'Connected to 127\.0\.0\.1')
$lines = $text -split "`r?`n"
Write-Host ("[{0}] captured {1} output lines -> build\perf_{0}.txt (client joined: {2})" -f $tag, $lines.Count, $clientJoined)

$vehicles = '?'
$settingValue = '?'
$dayNumbers = @()
$dateText = @()
foreach ($l in $lines) {
    if ($l -match 'Total vehicles:\s*(\d+)') { $vehicles = $Matches[1] }
    if ($l -match "rv_transport_enabled' is: '(\w+)'") { $settingValue = $Matches[1] }
    if ($l -match 'Date: (\d{4})-(\d{2})-(\d{2})') {
        $dayNumbers += ([int]$Matches[1] * 372) + ([int]$Matches[2] * 31) + [int]$Matches[3]
        $dateText += $Matches[0]
    }
}

Write-Host ("[{0}] vehicles={1} switch={2} client joined={3} dates: {4}" -f $tag, $vehicles, $settingValue, $clientJoined, ($dateText -join ' / '))
if ($dayNumbers.Count -ge 2) {
    for ($i = 1; $i -lt $dayNumbers.Count; $i++) {
        $rate = ($dayNumbers[$i] - $dayNumbers[$i - 1]) / $IntervalSec
        Write-Host ("RATE {0} interval{1}: {2} days/s" -f $tag, $i, ('{0:N4}' -f $rate))
    }
    $last = ($dayNumbers[-1] - $dayNumbers[-2]) / $IntervalSec
    Write-Host ("RESULT: {0} {1} days/s" -f $tag, ('{0:N4}' -f $last))
} else {
    Write-Host ("RESULT: {0} NO DATA (only {1} date lines - see build\perf_{0}.txt)" -f $tag, $dateText.Count)
}
