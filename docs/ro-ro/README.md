# Road vehicle transport (RoRo) — a JGR's Patch Pack feature branch

This branch adds **road vehicles carried by other vehicles** to [JGR's Patch Pack](https://github.com/JGRennison/OpenTTD-patches):
a road vehicle (truck/bus) can drive to a station, **wait to be transported**, be loaded onto a
train/ship/aircraft that stops there, travel with it (off the road network, keeping its cargo,
refit, orders and identity), and be unloaded at another station, where it simply continues its
own schedule.

* **Base**: JGRPP **0.73.1**, commit `611aabd7ba` (this is *not* upstream OpenTTD trunk)
* **Status**: playable and verified in game (loading, transport and unloading work); the
  remaining work is listed under *Known limitations*
* **Diff vs. base**: 31 files, +887/−28 — see `git diff --stat 611aabd7ba..HEAD`

## How it works from the player's point of view

On a **station order** of a vehicle, the *load behaviour* dropdown (the one with
"No loading"/"Full load") gains these entries:

| Entry | Meaning on a train/ship/aircraft | Meaning on a road vehicle |
|---|---|---|
| `Load road vehicles` | load waiting road vehicles here | **wait here to be transported** |
| `Unload road vehicles` | unload carried road vehicles here | **be unloaded here** (this is the "declared destination") |
| `Only road vehicles for the next stop` | only take vehicles whose declared destination is the carrier's next stop (on by default when loading is enabled) | – |

A typical setup:

* truck: `Go to A` + *wait to be transported* → `Go to B` + *be unloaded here* → `Go to C`
* train: `Go to A` + *load road vehicles* → `Go to B` + *unload road vehicles*

The order row shows the setting, and a waiting/carried road vehicle shows the status
*"Waiting to be transported" / "Being transported"*.

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

## Savegame compatibility

The feature uses JGRPP's extended savegame feature mechanism (`XSLFI_ROAD_VEH_TRANSPORT`,
version 1) and does **not** bump `SAVEGAME_VERSION`:

* **0.73.1 savegames load fine** (new fields default to "unused"), verified against a savegame
  written by a pristine 0.73.1 build;
* savegames produced by this branch are **not** loadable by vanilla 0.73.1 (the feature is
  written as a non-ignorable extended feature, so the older build refuses them cleanly).

## Developer/debug console commands

`rvtransport` (in the game console) is a development aid and can be dropped before merging:

```
rvtransport list                                   # ids/state of road vehicles and carriers
rvtransport orders <vehicle>                        # every order with its RoRo flags
rvtransport state <vehicle>                         # RoRo state of one vehicle
rvtransport wait <vehicle> on|off                   # force the "waiting" state
rvtransport modify <vehicle> <order> load|unload|dest   # set the flags through the real order command
rvtransport attach|detach <carrier> <rv|station> [force]  # run the load/unload transactions directly
rvtransport sim <carrier> <rv>                      # simulate waiting -> scan -> load on a real map
rvtransport selftest                                # automatic attach/detach check
```

`firstrv` / `firsttrain` may be used instead of a vehicle id.

## Verification scripts

`testrun/*.ps1` (PowerShell) were used while developing; they start a headless server against a
savegame and exercise the console commands above, e.g.:

* `verify_oldsave.ps1` — a pristine 0.73.1 build writes a savegame, this branch loads it
* `verify_sim.ps1` — waiting → scan → load chain on a real map, with the same code path the
  loading loop uses
* `m1_verify.ps1` — self save/load round-trip

They expect a build in `build/` and a config in `build/roro-test.cfg`; adapt the paths as needed.

## Design documentation

* `design-overview.zh.md` — full design/planning document (Chinese)
* `implementation-spec.zh.md` — implementation specification, including the review disposition table
* `manual-test-guide.zh.md` — step-by-step manual test guide (Chinese)

## Known limitations / next steps

* Carriers **do not wait** for road vehicles: a train that finds no waiting vehicle leaves with
  whatever else it loaded. A "wait for road vehicles / full load" semantics is planned.
* Articulated (multi-part) road vehicles cannot be loaded yet (single-unit road vehicles only).
* Carried road vehicles are frozen: they do not tick, age, depreciate, pay running costs,
  appear in vehicle lists/groups/statistics, or contribute to the road network.
* While carried, a road vehicle's own cargo is frozen (in-transit time/distance is not advanced);
  the cargo flow graphs therefore do not show the carried leg (it never enters a station cargo slot).
* By default any carrier part with cargo capacity may carry road vehicles. A setting
  (*"Carrying road vehicles requires 'oversized' cargo class"*, off by default) restores the
  stricter rule for NewGRF sets that provide `oversized` cargo; the default game content has none.
* Only station orders can be configured; carried road vehicles and carriers holding them cannot be
  sold until unloaded.
