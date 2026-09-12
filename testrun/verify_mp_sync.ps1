# Verify that road vehicle transport survives a network game (server <-> client sync).
#
# The branch had no multiplayer test at all. Both sides run headless: the server with `-D :port`, the
# client as a *dedicated client* (`-D -n host:port`, which joins through NetworkClientConnectGame()
# without needing a window).
#
# The savegame used here contains a road vehicle which is *already on board* a train, so joining the
# game transfers the branch's new vehicle fields (rv_transport_flags, transported_by,
# transported_host_part, transported_weight) and the received state can be compared between the two
# sides. Only state-reading console commands are used: the `rvtransport` mutating helpers change the
# game state server-side without going through the command framework, which a client by design cannot
# see. Phase 1 writes that savegame itself, so the test does not depend on another script's output.
param(
    [int]$Port = 3982,
    [string]$saveName = 'Wunfingley Market Transport, 1950-03-14.sav'
)

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
$exe  = Join-Path $root 'build\openttd.exe'
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
$made = Join-Path $root 'build\save\roro_mp_sync.sav'
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

Write-Output '== phase 1: load a road vehicle onto the train and save the game =='
$setup = Invoke-RoRoTest -Tag 'mpsetup' -Exe $exe -Config $cfg -Savegame $sav -CarrierParts 0 `
    -Commands @('rvtransport sim firsttrain firstrv', 'rvtransport state firstrv', 'save roro_mp_sync', 'quit') `
    -LogName 'log_mp_setup.txt' -ReadyTimeoutSec 90
$setup -split "`r?`n" | Where-Object { $_ -match 'sim:|vehicle #8|successfully saved' } | Select-Object -First 4 | ForEach-Object { Write-Output $_ }
if (-not (Test-Path $made)) { Write-Output 'FAIL: the setup savegame was not written'; exit 1 }
if (-not ($setup -match 'vehicle #8: .*flags=2')) { Write-Output 'FAIL: the road vehicle was not loaded in the setup phase'; exit 1 }
$sav = $made

function Start-Headless([string[]]$GameArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($GameArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $root
    $p = [System.Diagnostics.Process]::Start($psi)
    # Read asynchronously from the start: a process which is killed without flushing loses its buffer.
    return @{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Send([hashtable]$game, [string]$cmd) {
    try { $game.Proc.StandardInput.WriteLine($cmd); $game.Proc.StandardInput.Flush() } catch {}
}

$server = Start-Headless @("-c `"$cfg`"", '-x', "-D :$Port", "-g `"$sav`"")
Start-Sleep -Seconds 2
foreach ($i in 1..3) { Send $server 'pause'; Start-Sleep -Milliseconds 700 }
Start-Sleep -Seconds 8

$client = Start-Headless @("-c `"$cfg`"", '-x', '-D', "-n 127.0.0.1:$Port")
Start-Sleep -Seconds 22

# Both sides report the same vehicles; the client has to have received the carried state.
foreach ($g in @($server, $client)) {
    Send $g 'rvtransport state firstrv'
    Start-Sleep -Milliseconds 700
    Send $g 'rvtransport list'
    Start-Sleep -Milliseconds 700
    Send $g 'rvtransport carried firsttrain'
    Start-Sleep -Milliseconds 700
}
Start-Sleep -Seconds 3
Send $server 'quit'
Send $client 'quit'
Start-Sleep -Seconds 3

foreach ($g in @($server, $client)) { if (-not $g.Proc.HasExited) { try { $g.Proc.Kill() } catch {} } }
Start-Sleep -Seconds 1
$serverText = ""; $clientText = ""
try { $serverText += $server.Out.Result } catch {}; try { $serverText += $server.Err.Result } catch {}
try { $clientText += $client.Out.Result } catch {}; try { $clientText += $client.Err.Result } catch {}
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'log_mp_server.txt'), $serverText, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'log_mp_client.txt'), $clientText, (New-Object System.Text.UTF8Encoding($false)))

# Compare the road vehicle state and the carried list of both sides (vehicle ids included).
function Pick([string]$text, [string]$pattern) {
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match $pattern) { return $l.Trim() }
    }
    return '<not seen>'
}
$serverState = Pick $serverText '^vehicle #\d+: type=1 '
$clientState = Pick $clientText '^vehicle #\d+: type=1 '
$serverCarried = Pick $serverText '^carrier #\d+ holds \d+ road vehicle'
$clientCarried = Pick $clientText '^carrier #\d+ holds \d+ road vehicle'
$connected = ($serverText -match '\[server\] Client #\d+ .* joined as') -and ($clientText -match 'Connected to 127\.0\.0\.1')
$desync = ($clientText -match 'desync|Desync') -or ($serverText -match 'desync|Desync')

Write-Output ("server carried state: {0}" -f $serverState)
Write-Output ("client carried state: {0}" -f $clientState)
Write-Output ("server carrying:      {0}" -f $serverCarried)
Write-Output ("client carrying:      {0}" -f $clientCarried)
Write-Output ("client connected: {0} ; desync: {1}" -f $connected, $desync)

$stateOk = ($serverState -ne '<not seen>') -and ($serverState -eq $clientState) -and ($serverState -match 'flags=2')
if ($connected -and $stateOk -and ($serverCarried -eq $clientCarried) -and -not $desync) {
    Write-Output 'RESULT: PASS (client received the carried road vehicle state, no desync)'
} else {
    Write-Output 'RESULT: CHECK (see the lines above)'
}
