# Verify the per-order "most road vehicles at once" limit (OrderExtraInfo::rv_transport_max).
#
# The limit is set through the real order command (MOF_RV_MAX), exactly like the settings window does,
# and every load goes through RVTransportAttachAuto(), which is where the limit is enforced. A limit of
# 0 means "no limit".
#
# The tester's savegame has a 4-hold ship (#28, 150 t per hold, so a truck fits) at station 12, and
# trucks #30-#35 standing there; `setwaiting` moves a truck into the "waiting to be transported" state
# at the carrier's station and `loadfrom` runs the carrier-side loading code for one part.
param(
    [string]$saveName = 'test1.sav',
    [string]$Exe = ''
)

. (Join-Path $PSScriptRoot '_common.ps1')

$root = Get-RoRoRoot
if (-not $Exe) { $Exe = Join-Path $root 'build\openttd.exe' }
$cfg  = Get-RoRoTestConfig -Root $root
$sav  = Join-Path $root ("build\save\" + $saveName)
if (-not (Test-Path $sav)) { Write-Output "savegame not found: $sav"; exit 1 }

# Ship #28's current order is index 2 (the station order it is loading at).
$cmds = @(
    'pause',
    'setting vehicle.rv_transport_carrier_parts 0',      # the ship's cargo is not a carrier cargo by default
    'rvtransport criteria 28 2 max 1',
    'rvtransport setwaiting 28 30',
    'rvtransport setwaiting 28 31',
    'rvtransport setwaiting 28 32',
    'rvtransport loadfrom 28 30',                        # 0 on board < 1: allowed
    'rvtransport loadfrom 28 31',                        # 1 on board = 1: refused
    'rvtransport criteria 28 2 max 2',
    'rvtransport loadfrom 28 31',                        # 1 on board < 2: allowed
    'rvtransport criteria 28 2 max 0',                   # no limit
    'rvtransport loadfrom 28 32',                        # 2 on board, no limit: allowed
    'rvtransport carried 28',
    'quit'
)
$txt = Invoke-RoRoTest -Tag 'maxload' -Exe $Exe -Config $cfg -Savegame $sav -Commands $cmds -CarrierParts -1 -LogName 'log_max_load.txt'
$txt -split "`r?`n" | Where-Object { $_ -match 'criteria:|loadfrom:|carrier #28|Assertion|crash' } | Select-Object -First 20 | ForEach-Object { Write-Output $_ }

if ($txt -match 'Assertion failed|crash encountered') { Write-Output 'RESULT: FAIL (crash/assertion)'; exit 1 }

# The limit has to reach the order, and only the loads which fit under it may succeed.
$limitSet = ($txt -match 'criteria: OK \(vehicle #28 order 2 max=1\).*max=1') -and ($txt -match 'criteria: OK \(vehicle #28 order 2 max=2\).*max=2')
$attaches = @()
foreach ($l in ($txt -split "`r?`n")) {
    if ($l -match 'loadfrom: part #\d+ -> carrier #28 .*attached=(\w+)') { $attaches += $Matches[1] }
}
Write-Output ("limit reached the order: {0} ; attach verdicts: {1}" -f $limitSet, ($attaches -join ', '))
$ok = $limitSet -and ($attaches.Count -ge 4) -and ($attaches[0] -eq 'true') -and ($attaches[1] -eq 'false') -and
      ($attaches[2] -eq 'true') -and ($attaches[3] -eq 'true')
if ($ok) {
    Write-Output 'RESULT: PASS (the order limit refuses the load at the cap, and unlimited takes it)'
} else {
    Write-Output 'RESULT: CHECK (see the verdicts above)'
}
