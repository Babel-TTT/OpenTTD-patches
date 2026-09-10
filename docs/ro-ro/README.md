# Road vehicle transport (RoRo) — a JGR's Patch Pack feature branch

This branch adds **road vehicles carried by other vehicles** to [JGR's Patch Pack](https://github.com/JGRennison/OpenTTD-patches):
a road vehicle (truck/bus) can drive to a station, **wait to be transported**, be loaded onto a
train/ship/aircraft that stops there, travel with it (off the road network, keeping its cargo,
refit, orders and identity), and be unloaded at another station, where it simply continues its
own schedule.

* **Base**: JGRPP **0.73.1**, commit `611aabd7ba` (this is *not* upstream OpenTTD trunk)
* **Status**: playable and verified in game (waiting, loading, transport, unloading and release
  all work); the remaining work is listed under *Known limitations*
* **Diff vs. base**: `src/` — 31 files, +977/−28 · `docs/ro-ro/` — 4 files (+1047) ·
  `testrun/` — 11 scripts (+586). See `git diff --stat 611aabd7ba..HEAD`

## How it works from the player's point of view

On a **station order** of a vehicle, two dropdowns gain road vehicle transport entries. They are
**check boxes** (more than one can be active at the same time) and the list is rebuilt after every
click, so the ticks always show the current state:

*load behaviour dropdown* (the one with "No loading"/"Full load"):

| Entry | Meaning on a train/ship/aircraft | Meaning on a road vehicle |
|---|---|---|
| `Load road vehicles` | load waiting road vehicles here | **wait here to be transported** |
| `Only road vehicles for the next stop` | only take vehicles whose declared destination is the carrier's next stop (on by default when loading is enabled) | – (not offered: a road vehicle's own order has no use for it) |
| `Wait for road vehicles` | keep waiting at this station until road vehicles have been loaded | – |

*unload behaviour dropdown* (the one with "Unload"/"Transfer"):

| Entry | Meaning on a train/ship/aircraft | Meaning on a road vehicle |
|---|---|---|
| `Unload road vehicles` | unload carried road vehicles here | **be unloaded here** (this is the "declared destination") |

The combinations are kept meaningful: switching loading off clears the match and wait entries,
while switching the match or wait on implies loading. A road vehicle's own order clears (and the
display ignores) the match bit, so an order saved by an older build of this branch cannot show up as
"only road vehicles for the next stop" any more.

A typical setup:

* truck: `Go to A` + *wait to be transported* → `Go to B` + *be unloaded here* → `Go to C`
* train: `Go to A` + *load road vehicles* → `Go to B` + *unload road vehicles*

The order row lists **every** part of the setting that is active (e.g. "Go to A, load road vehicles,
only road vehicles for the next stop"), and a waiting/carried road vehicle shows the status
*"Waiting to be transported" / "Being transported"*; a carrier shows how many road vehicles it
currently holds.

Behavioural notes:

* **Matching is a condition**: *"Only road vehicles for the next stop"* is evaluated like a
  conditional order — a road vehicle whose declared destination is not the carrier's next stop is
  simply **skipped** (it is not an error and the carrier does not wait for it).
* **`Wait for road vehicles` waits indefinitely** (the `finished_loading` flag is held down, exactly
  like "Full load"); there is no engine-side timeout, so pair it with a timetable or only enable it
  where vehicles are actually available.
* **Carriers are trains, ships and aircraft**; a road vehicle cannot carry another road vehicle.
* **When a carrier is destroyed**, the road vehicles it was carrying are released back onto the map
  at the carrier's tile (they stay visible and continue their own orders). A carrier holding road
  vehicles — and a road vehicle being carried — **cannot be sold** until the vehicles are unloaded.

## Building

Same toolchain as OpenTTD/JGRPP, e.g. with MSYS2 (MINGW64) on Windows:

```bash
pacman -S --needed base-devel mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja \
    mingw-w64-x86_64-zlib mingw-w64-x86_64-libpng mingw-w64-x86_64-lzo2
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DOPTION_USE_ASSERTS=ON
cmake --build build --target openttd
```

Run it from the build directory (so that `lang/` and `baseset/` are found), for example
`build/openttd.exe -c <your-config>.cfg`. The binary must not be running while relinking on Windows.

> On Windows/MSYS2 make sure `D:\msys64\mingw64\bin` is on `PATH` **when you invoke the build**:
> `cc1plus.exe` finds its runtime DLLs there, and without it the compiler dies silently with no
> error message (exit code `0xC0000135`).

## Savegame compatibility

The feature uses JGRPP's extended savegame feature mechanism (`XSLFI_ROAD_VEH_TRANSPORT`,
version 1) and does **not** bump `SAVEGAME_VERSION`:

* **0.73.1 savegames load fine** (new fields default to "unused"), verified against a savegame
  written by a pristine 0.73.1 build;
* savegames produced by this branch are **not** loadable by vanilla 0.73.1 (the feature is
  written as a non-ignorable extended feature, so the older build refuses them cleanly).
* Road vehicles carried *while saving* survive a save/load round-trip (carrier, host part and
  recorded weight are restored), verified by `testrun/verify_intransit.ps1`.

## Reviewing this branch — where to look

| Area | Files | What to check |
|---|---|---|
| Core transactions | `src/roadveh_transport.{h,cpp}` | attach/detach: `Stopped`+`Hidden`, road-network hash removal/restore, capacity-vs-weight check, finding a free road-stop tile, emergency release |
| Vehicle state | `src/vehicle_base.h`, `src/sl/vehicle_sl.cpp`, `src/sl/extended_ver_sl.{h,cpp}` | 5 new fields, gated behind `XSLFI_ROAD_VEH_TRANSPORT`; IDs stored with `SLE_UINT32` |
| Order data | `src/order_base.h`, `src/order_cmd.cpp`, `src/order_type.h`, `src/sl/order_sl.cpp` | `MOF_RV_TRANSPORT` field, command whitelist, `Order::AssignOrder()` must copy the flags |
| Loading loop | `src/economy.cpp` (`LoadUnloadVehicle`) | waiting road vehicles skip normal loading; 8 vehicles/tick matched/unloaded per order flags; `ORVTF_WAIT` holds `finished_loading` |
| Exemptions | `src/vehicle.cpp`, `vehiclelist.cpp`, `group_cmd.cpp`, `economy.cpp`, `infrastructure.cpp`, `network/network_server.cpp`, `disaster_vehicle.cpp`, `engine.cpp`, `industry_cmd.cpp`, `settings_table.cpp`, `order_cmd.cpp` | carried road vehicles behave like virtual vehicles everywhere these loops run |
| GUI | `src/order_gui.cpp`, `src/vehicle_gui.cpp`, `src/lang/extra/*.txt` | dropdown entries, road-vehicle vs carrier wording, order-row markers, status strings |
| Destruction | `src/vehicle.cpp` (`PreDestructor`) | a destroyed carrier releases what it carries |
| Setting | `src/table/settings/game_settings.ini`, `src/settings_type.h` | `vehicle.rv_transport_require_oversized` (default `false` = any cargo capacity may carry) |

## Developer/debug console commands

`rvtransport` (in the game console) is a development aid and can be dropped before merging:

```
rvtransport list                                    # ids/state of road vehicles and carriers
rvtransport orders <vehicle>                        # every order with its RoRo flags
rvtransport state <vehicle>                         # RoRo state of one vehicle
rvtransport wait <vehicle> on|off                   # force the "waiting" state
rvtransport orderflag <vehicle> load|unload|dest|wait    # set flags on the current order
rvtransport modify <vehicle> <order> load|unload|dest|wait   # set the flags through the real order command
rvtransport toggle <vehicle> <order> load|unload|dest|wait   # apply the order window's check box rules
rvtransport setflags <vehicle> <order> <flags>      # force an order into a known flag state
rvtransport attach|detach <carrier> <rv|station> [force]  # run the load/unload transactions directly
rvtransport release <rv>                            # emergency release (same function as carrier destruction)
rvtransport sim <carrier> <rv>                      # simulate waiting -> scan -> load on a real map
rvtransport selftest                                # automatic attach/detach check
```

`firstrv` / `firsttrain` may be used instead of a vehicle id.

## Verification scripts

`testrun/*.ps1` (PowerShell) were used while developing; they start a headless server
(`-D -g <savegame>`) and exercise the console commands above. They expect a build in `build/`, a
config in `build/roro-test.cfg` and a savegame in `build/save/`; adapt the paths as needed.

| Script | Checks | State |
|---|---|---|
| `verify_oldsave.ps1` | a pristine 0.73.1 build writes a savegame, this branch loads it | PASS |
| `m1_verify.ps1` | self save/load round-trip | PASS |
| `smoke_m2a.ps1` | empty map + `rvtransport` commands, crash watch | PASS |
| `verify_attach.ps1` | forced attach/detach transactions and weight accounting | PASS |
| `verify_intransit.ps1` | carried state survives save/load, then unloads | PASS |
| `verify_sim.ps1` | waiting → station scan → load chain on a real map | PASS |
| `verify_user_save.ps1` | order command chain (`load`/`unload`/`dest`) | PASS |
| `verify_toggle.ps1` | the order window's flag toggling rules (via `rvtransport toggle`, which calls the same `RVTransportToggleOrderFlag()`) | PASS |
| `verify_release.ps1` | release path used when a carrier is destroyed | PASS |
| `run_selftest.ps1`, `m1_roundtrip.ps1`, `probe_ai.ps1` | early scaffolding / diagnostics, superseded | disabled |

Note: `delete_vehicle_id` is **not** registered on a dedicated server, so the carrier-destruction
path is exercised through `rvtransport release` (the same `RVTransportForceRelease()` that
`Vehicle::PreDestructor()` calls).

## Design documentation

* `design-overview.zh.md` — full design/planning document (Chinese)
* `implementation-spec.zh.md` — implementation specification, including the review disposition
  table (appendix C) and the progress/verification appendix (appendix D)
* `manual-test-guide.zh.md` — step-by-step manual test guide (Chinese)

## Known limitations / next steps

Work that is deliberately **not** in this branch yet:

* **Articulated (multi-part) road vehicles cannot be loaded** (single-unit road vehicles only; the
  attach transaction refuses a road vehicle that is not a front engine or that has a next part).
* **No "carried vehicles" list in the vehicle detail window** — a carrier's status line shows how
  many road vehicles it holds, but the individual vehicles can only be inspected through
  `rvtransport list`/`state` for now.
* **Ship and aircraft carriers are not walked through on a real map yet** (they share the entire
  code path with trains; the manual steps are in `manual-test-guide.zh.md` §6).
* **The accident-destruction path was verified through its function, not through a real crash**
  (`verify_release.ps1` calls the same `RVTransportForceRelease()`).
* No multiplayer sync test, no performance measurement, and the `rvtransport` debug command is
  still present (to be stripped before merging).

Design decisions worth knowing when reviewing:

* Carried road vehicles are frozen: they do not tick, age, depreciate, pay running costs,
  appear in vehicle lists/groups/statistics, or contribute to the road network.
* While carried, a road vehicle's own cargo is frozen (in-transit time/distance is not advanced);
  the cargo flow graphs therefore do not show the carried leg (it never enters a station cargo slot).
* By default any carrier part with cargo capacity may carry road vehicles. A setting
  (*"Carrying road vehicles requires 'oversized' cargo class"*, off by default) restores the
  stricter rule for NewGRF sets that provide `oversized` cargo; the default game content has none.
* Only station orders can be configured; carried road vehicles and carriers holding them cannot be
  sold until unloaded.
