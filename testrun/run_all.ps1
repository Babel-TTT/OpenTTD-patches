# Run the RoRo verification scripts, optionally several at a time.
#
# The scripts are independent: each one starts its own dedicated server, loads its own savegame and
# writes its own log, so they can run in parallel (they do share the server ports of the config;
# a dedicated server whose port is already taken logs a warning and keeps working, which is fine
# for these tests).
#
# Usage:
#   powershell -File testrun\run_all.ps1                 # 4 at a time (default)
#   powershell -File testrun\run_all.ps1 -Jobs 8         # 8 at a time
#   powershell -File testrun\run_all.ps1 -Jobs 1         # one after another (like before)
#   powershell -File testrun\run_all.ps1 -Only verify_attach.ps1,verify_destroy.ps1
param(
    [int]$Jobs = 4,
    [string[]]$Only = @(),
    [int]$TimeoutSec = 420,
    [switch]$Quiet
)

$root = Split-Path -Parent $PSScriptRoot
$tr = Join-Path $root 'testrun'
$resultsDir = Join-Path $root 'build\testrun-results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

# Every script which reports PASS/FAIL.
$all = @(
    'verify_oldsave.ps1',
    'm1_verify.ps1',
    'smoke_m2a.ps1',
    'verify_details.ps1',
    'verify_wait_tick.ps1',
    'verify_attach.ps1',
    'verify_intransit.ps1',
    'verify_sim.ps1',
    'verify_user_save.ps1',
    'verify_toggle.ps1',
    'verify_filter.ps1',
    'verify_slot.ps1',
    'verify_release.ps1',
    'verify_destroy.ps1'
)
# 'powershell -File ... -Only a.ps1,b.ps1' arrives as a single comma separated string, so split it.
$onlyList = @()
foreach ($o in $Only) { $onlyList += ($o -split ',') | Where-Object { $_ } }
if ($onlyList.Count -gt 0) { $all = $all | Where-Object { $onlyList -contains $_ } }

$queue = [System.Collections.Queue]::new()
foreach ($s in $all) { $queue.Enqueue($s) }

$running = @{}
$done = @()
$start = Get-Date

function Start-Test([string]$name) {
    $out = Join-Path $resultsDir ("{0}.out.txt" -f ($name -replace '\.ps1$', ''))
    $err = Join-Path $resultsDir ("{0}.err.txt" -f ($name -replace '\.ps1$', ''))
    Remove-Item $out, $err -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'powershell' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tr $name)) `
        -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    return @{ Name = $name; Proc = $p; Out = $out; Err = $err; Started = (Get-Date) }
}

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Jobs) {
        $name = $queue.Dequeue()
        $job = Start-Test $name
        $running[$name] = $job
        if (-not $Quiet) { Write-Output ("-> started {0} ({1} running)" -f $name, $running.Count) }
    }

    Start-Sleep -Milliseconds 500

    foreach ($name in @($running.Keys)) {
        $job = $running[$name]
        $timedOut = ((Get-Date) - $job.Started).TotalSeconds -gt $TimeoutSec
        if ($job.Proc.HasExited -or $timedOut) {
            if ($timedOut -and -not $job.Proc.HasExited) { try { $job.Proc.Kill() } catch {} }
            # The exit code is only available once the process object has been refreshed.
            $code = 0
            if ($job.Proc.HasExited) {
                try { $job.Proc.WaitForExit(); if ($null -ne $job.Proc.ExitCode) { $code = $job.Proc.ExitCode } } catch {}
            } else {
                $code = -1
            }
            $text = ''
            if (Test-Path $job.Out) { $text = (Get-Content -LiteralPath $job.Out -Raw) }

            # Judge from what the script printed (they all report their own verdict), and only fail on
            # the exit code when the script did not report anything.
            $reported = $false
            $verdict = 'FAIL'
            if ($text -match 'Assertion failed|crash encountered') {
                $verdict = 'CRASH'
                $reported = $true
            } elseif ($text -match 'RESULT: CHECK') {
                $verdict = 'CHECK'
                $reported = $true
            } elseif ($text -match 'RESULT: PASS' -or $text -match 'SMOKE: no crash detected' -or
                      $text -match 'step2: PASS' -or $text -match 'Part B: PASS' -or
                      $text -match 'sim: scan found=true attached=true' -or $text -match 'modify: OK') {
                $verdict = 'PASS'
                $reported = $true
            }
            if ($timedOut) { $verdict = 'TIMEOUT'; $reported = $true }
            if ($code -ne 0 -and $verdict -eq 'FAIL' -and -not $reported) { $verdict = 'FAIL' }

            $line = ($text -split "`r?`n") | Where-Object { $_ -match 'RESULT:|SMOKE:|step2:|Part B:|sim: scan' } | Select-Object -Last 1
            $done += [pscustomobject]@{
                Script  = $name
                Verdict = if ($timedOut) { 'TIMEOUT' } else { $verdict }
                Exit    = $code
                Seconds = [math]::Round(((Get-Date) - $job.Started).TotalSeconds, 1)
                Last    = $line
            }
            $running.Remove($name)
            if (-not $Quiet) { Write-Output ("<- {0}: {1} in {2}s" -f $name, $done[-1].Verdict, $done[-1].Seconds) }
        }
    }
    if ($running.Count -eq 0 -and $queue.Count -eq 0) { break }
}

$total = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
Write-Output ''
Write-Output ('== summary (jobs={0}, wall clock {1}s) ==' -f $Jobs, $total)
$done | Sort-Object Script | Format-Table Script, Verdict, Exit, Seconds -AutoSize | Out-String | Write-Output
foreach ($d in ($done | Where-Object { $_.Last })) { Write-Output ("{0}: {1}" -f $d.Script, $d.Last) }

$bad = @($done | Where-Object { $_.Verdict -ne 'PASS' })
Write-Output ''
if ($bad.Count -eq 0) { Write-Output 'ALL PASS' } else { Write-Output ("FAILED: " + (($bad | ForEach-Object { $_.Script }) -join ', ')) }
exit ($(if ($bad.Count -eq 0) { 0 } else { 1 }))
