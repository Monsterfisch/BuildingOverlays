# Building Overlays

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme that draws PNG pictures on
top of buildings, the way the game draws the crenellations over its tower walkways: a picture
that hides the empty walkway and goes away when troops step onto the building. Ships with an
overlay for the large gatehouse; more are added by dropping a PNG into `module/overlays/` and a
line into `module/overlay_list.lua`.

What the module does, in plain English, is in `module/locale/description-en.md`.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - the source of truth, edited in place |
| `bench/` | the emulator bench: `test_overlays.py` runs the module's Lua and assembly with the game's own drawing code and compares the pixels with the PNGs, on both executables |
| `tools/publish.py` | copies `module/` into the game's module folder under the version in `definition.yml` |

## Working on it

1. Edit under `module/`; run `python bench/test_overlays.py` until it is green.
2. `python tools/publish.py --bump`, then F5 and apply in the UCP GUI.
3. Lining a picture up in game: Alt + PageUp / PageDown picks an overlay, Alt + arrows nudge it a
   pixel, Alt + End saves `calibration.lua` (and logs the numbers to `ucp3.log`).

## How it works

* One hook at the shared tail of `renderGmOverlayBuilding`, after the game's own overlays.
* A record table (type, occupancy, entrance direction on screen, gate state, offset, picture)
  walked in assembly; pictures are PNGs packed as TGX (RGB565 and RGB555) and drawn through the
  game's own picture routine, so clipping and the zoomed-out view come for free.
* "Empty" = building `+0xB0 == 0`; entrance side from `+0x102` (0x50 = along x) flipped on map
  orientations 2 and 6.
