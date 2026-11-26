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
3. Lining pictures up in game: select the building - its panel lists its overlays (left), a click
   picks one (shown and framed on that building whatever stands there), blue arrows move it by
   the Step size (1 / 5 / 20). Every move is saved at once and Save saves again; the button's
   label says whether the last write worked. Positions go into UCP's user data folder,
   `ucp/userdata/building-overlays/` in the game's folder under Documents, two alternating files
   per source, so an interrupted write leaves the other one readable:
   - `module-a.lua` / `-b.lua`: the module's own overlays.
   - `<plugin name>-a.lua` / `-b.lua`, for example `MyPlugin-a.lua`: a registered
     plugin's overlays, written only when that plugin has overlays to save.
   - Moved game pictures (`{ game = n, ... }` entries) go into the first loaded plugin's files, or
     the module's if no plugin is loaded. If two sources set the same game picture and building,
     the one loaded last wins.

   Saved spots replace `x` and `y` of the overlays of the same name once the game has started.
   Calibration files in the game's `ucp` folder (`ucp/building-overlays-*`) are only read: when
   a source has none in the user data folder, its `ucp` file is applied and saved there.

   A saved file has the format of `overlays.lua`. To ship it in a plugin, copy it as the plugin's
   `overlays.lua` next to the PNGs it names, and test it with your saved files moved aside.
4. Plugins: `modules["building-overlays"]:registerOverlaySource(folder)` loads `overlays.lua` and the
   PNGs from `resources/modsupport/building-overlays/` of the plugin.

## Moving the game's own pictures

The game draws its own overlay pictures on keeps, gatehouses, the drawbridge and towers (and on
many other buildings). Every place in its
drawing code that draws one is numbered in code order, "Game #n" in the panel; the numbers are
the same in Stronghold Crusader and Crusader Extreme 1.41. An `overlays.lua` entry with `game`
instead of `name` moves that picture on every building of one type by `x` / `y` pixels from where
the game puts it (`x = 0, y = 0` is the game's own place):

```lua
return {
  -- tower two (building 75): its first picture 4 pixels higher
  { game = 152, building = 75, x = 0, y = -4 },
}
```

The Save button writes the same entry for a game picture, and a plugin can ship it in its
`resources/modsupport/building-overlays/overlays.lua`. Which of its pictures a building draws
depends on its state; its panel lists the ones it uses. The places in each building's drawing
code, in drawing order:

| Building | Type | Game # |
|---|---|---|
| Stone keep | 41 | 162 |
| Stronghold | 42 | 162 |
| Large gatehouse | 45 | 136, 137, 138, 139, 140, 162 |
| Small gatehouse | 46 | 141, 142, 143, 144, 145, 162 |
| Wooden gatehouse | 47 | 146, 147, 148, 149, 150, 162 |
| Drawbridge | 49 | 75, 162 |
| Tower one (lookout tower) | 74 | 151, 162 |
| Tower two | 75 | 152, 153, 162 |
| Tower three | 76 | 154, 155, 162 |
| Tower four | 77 | 156, 157, 158, 159, 162 |
| Tower five (round tower) | 78 | 160, 161, 162 |

Game #162 is the last picture of each of these buildings: they share that call, and the entry's
`building` decides whose picture moves. Many other buildings draw pictures through the same
numbered calls and can be moved the same way; select one and its panel lists them.

## How it works

* One hook at the shared tail of `renderGmOverlayBuilding`, after the game's own overlays.
* The tool wraps two shared building-panel items (first every-frame item = clicks, work status
  line = drawing), the same two smarter-buildings wraps; each chains to whatever was there.
* A record table (type, occupancy, entrance direction on screen, gate state, offset, picture)
  walked in assembly; pictures are PNGs packed as TGX (RGB565 and RGB555) and drawn through the
  game's own picture routine, so clipping and the zoomed-out view come for free.
* The PNGs are read by `png.lua`, not by GM Resource Modifier: that module shows a picture only in
  a GM sheet slot (`ReserveGm` needs a base sheet of the same type and picture count, `SetGm`
  replaces a game picture), and `LoadResourceFromImage` keeps 5 bits of green.
* "Empty" = no unit on the building's tiles (the game's own `hasHumanPlayerUnitsOnBuilding`, which a
  gatehouse needs - its `+0xB0` flag stays 0) and `+0xB0 == 0`; entrance side from `+0x102` (0x50 = along x) flipped on map
  orientations 2 and 6.
