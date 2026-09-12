# Verify the "carried for too long" warning (vehicle.rv_transport_unload_warn_days).
#
# A road vehicle is only put down at a station its own schedule asks for, so a carrier which never
# reaches such a station keeps it on board forever. The warning tells the player about that; it is
# shown once per trip, and 0 disables it.
#
# Phase 1 loads a road vehicle onto the train and clears every road vehicle transport flag of the
# train's orders, so nothing can unload it again while the game runs. Phase 2 then runs the game for a
# while with the threshold at one day (the vehicle must be flagged as warned) and phase 3 does the same
# with the warning disabled (it must not be flagged).
param(
    [string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav',
    [int]$RunSec = 60
)

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
$made = Join-Path $root 'build\save\roro_warn.sav'
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

function Run-Game([string]$gameArgs, [string[]]$cmds, [int[]]$waits) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $gameArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    foreach ($i in 1..3) { try { $p.StandardInput.WriteLine('pause'); $p.StandardInput.Flush() } catch {}; Start-Sleep -Milliseconds 700 }
    Start-Sleep -Seconds 8
    for ($i = 0; $i -lt $cmds.Count; $i++) {
        try { $p.StandardInput.WriteLine($cmds[$i]); $p.StandardInput.Flush() } catch {}
        Start-Sleep -Seconds ([math]::Max(1, $waits[$i]))
    }
    try { $p.StandardInput.WriteLine('quit'); $p.StandardInput.Flush() } catch {}
    Start-Sleep -Seconds 3
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 1
    $txt = ""
    try { $txt += $o.Result } catch {}
    try { $txt += $e.Result } catch {}
    return $txt
}

Write-Output '== phase 1: load a road vehicle and make sure the train cannot unload it =='
$clearFlags = 0..7 | ForEach-Object { "rvtransport setflags firsttrain $_ 0" }
$cmds = @('setting vehicle.rv_transport_carrier_parts 0')
$waits = @(1)
$cmds += 'rvtransport sim firsttrain firstrv'; $waits += 2
$cmds += $clearFlags;                            $waits += (1..8 | ForEach-Object { 1 })
$cmds += 'rvtransport state firstrv';            $waits += 1
$cmds += 'save roro_warn';                       $waits += 3
$setup = Run-Game "-c `"$cfg`" -x -D -g `"$sav`"" $cmds $waits
$setup -split "`r?`n" | Where-Object { $_ -match 'sim:|vehicle #8|successfully saved' } | Select-Object -First 4 | ForEach-Object { Write-Output $_ }
if (-not (Test-Path $made)) { Write-Output 'FAIL: the setup savegame was not written'; exit 1 }
if (-not ($setup -match 'vehicle #8: .*flags=2')) { Write-Output 'FAIL: the road vehicle is not carried in the setup phase'; exit 1 }

function WarnFlagsAfterRun([int]$warnDays) {
    $cmds = @("setting vehicle.rv_transport_unload_warn_days $warnDays", 'unpause', 'pause', 'rvtransport state firstrv')
    $waits = @(1, $RunSec, 1, 1)
    $txt = Run-Game "-c `"$cfg`" -x -D -g `"$made`"" $cmds $waits
    foreach ($l in ($txt -split "`r?`n")) {
        if ($l -match '^vehicle #8: .*flags=(\d+)') { return [int]$Matches[1] }
    }
    return -1
}

Write-Output ("== phase 2: warning at 1 day, running {0}s ==" -f $RunSec)
$withWarn = WarnFlagsAfterRun 1
Write-Output ("  flags with the warning enabled: {0}" -f $withWarn)

Write-Output ("== phase 3: warning disabled, running {0}s ==" -f $RunSec)
$noWarn = WarnFlagsAfterRun 0
Write-Output ("  flags with the warning disabled: {0}" -f $noWarn)

# flags: bit1 = carried, bit2 (value 4) = the warning was shown.
$ok = ($withWarn -ge 0) -and (($withWarn -band 2) -ne 0) -and (($withWarn -band 4) -ne 0) -and
      (($noWarn -band 2) -ne 0) -and (($noWarn -band 4) -eq 0)
if ($ok) {
    Write-Output 'RESULT: PASS (the carried vehicle is flagged as warned at 1 day, and not when the warning is off)'
} else {
    Write-Output 'RESULT: CHECK (see the flag values above)'
}

