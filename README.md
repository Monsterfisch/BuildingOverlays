# Building Overlays

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme that draws PNG pictures on
top of buildings, the way the game draws the crenellations over its tower walkways: a picture
that hides the empty walkway and goes away when troops step onto the building. The module
brings no pictures of its own: plugins bring them (see "Using it from a plugin"). It also fixes
how the game draws keep entrances, flags and overlays next to other buildings.

## What it does

### Keep entrance

A fix for a bug of the game itself: on keeps turned one of two ways, the middle of the entrance
in front of the keep was drawn in the wrong light - a bright pillar between shaded towers, or a
dark one through a bright archway. Now it matches the towers beside it. Switched on in the
settings.

### Troops on the building

An overlay goes away while any unit stands on the building - except the lord, who always
stands on his keep and would otherwise hide a keep's overlay for good. With "Only hide the
overlays while the mouse is on the building" switched on, towers, gatehouses and keeps keep
their battlements drawn whoever stands on them, and only drop them while you point the mouse
at the building. That covers the plugins' overlays and the roofs of the game's towers; a
tower's crenellations and every other game overlay keep the game's own rules. An overlay with
`units = "any"` is always drawn - use that for crenellations that should cover the troops.

### Buildings in front cover the overlays

The game draws overlays in one piece at a building's front corner, so they show through towers
and walls standing right next to it. This module draws the plugins' pictures, and the game's own
overlay pictures on every building, in narrow strips together with the building's tiles
instead, so whatever stands in front covers them. Parts hanging over the sides of a building go
with its back-most tile. Switched on in the settings ("Let buildings in front cover the
overlays").

### Moving overlays in the game

Select any building. Its panel lists its overlays on the left: the plugins', and the game's
own pictures the building is drawn with, as "Game #n" (those can be moved too; when they show
stays the game's business). Click one to pick it: it is then shown on that building whatever is standing there,
with a magenta frame, and blue arrow buttons appear on the right of the panel. Each click
moves the picture by the step size; click "Step" to switch between 1, 5 and 20 pixels. Click
the picked overlay again to stop. "Save" stores the positions in UCP's user data folder, and
the module uses them from then on. The tool is switched on in the settings.

### Using it from a plugin

A plugin brings its overlays as PNGs (see-through parts stay see-through) and an `overlays.lua`
in its `resources/modsupport/building-overlays/` folder. Every active plugin with that folder is
read at start. A plugin can also register the folder from its `enable`:

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

Each entry of `overlays.lua` names the building, which way its entrance faces on screen, whether
troops are on it, the gate state and where the picture sits. For example, a large gatehouse
with one picture for each entrance side (`bench/large-gatehouse/`):

```lua
return {
  { name = "large_gatehouse_left", building = 45, picture = "large_gatehouse_overlay_closed_left", entrance = "left", units = "empty", gate = "any", x = -107, y = -193 },
  { name = "large_gatehouse_right", building = 45, picture = "large_gatehouse_overlay_closed_right", entrance = "right", units = "empty", gate = "any", x = -107, y = -193 },
}
```

| Field | |
|---|---|
| `name` | shown in the panel and the log |
| `building` | a building type number, or `large_gatehouse`, `small_gatehouse`, `tower1` to `tower5`, `manor_house`, `stone_keep`, `stronghold`, `keep_four`, `keep_five` |
| `picture` | a PNG in the same folder, without `.png` |
| `entrance` | `left`, `right` or `any`: `left` = the entrance looks to the lower left. Pictures drawn for the wrong side: exchange the two values |
| `units` | `empty` (hidden while troops, or with the mouse setting the mouse, are on it), `occupied`, or `any` (always drawn) |
| `gate` | gates only: `any`, `open`, `closing`, `closed` or `opening` |
| `x`, `y` | the picture's top left corner, from the building's anchor point on screen |

An overlay with the same name as one of an earlier plugin's replaces it. Each plugin registers
one folder. The Save button stores a plugin's spots in the user data folder too, under the
plugin's name; the plugin's own `overlays.lua` stays as it is.

The same file can also move the game's own pictures, the ones the panel lists as "Game #n".

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - the source of truth, edited in place |
| `bench/` | the emulator bench: `test_overlays.py` runs the module's Lua and assembly with the game's own drawing code and compares the pixels with the PNGs, on both executables |
| `bench/large-gatehouse/` | a plugin's overlay folder for the large gatehouse, drawn by the bench |
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
   - `_module-a.lua` / `-b.lua`: moved game pictures while no plugin is loaded.
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

## Vanilla and Recommended

Every option of the module is off by default. With no option on and no plugin bringing
overlays, the module installs nothing and the game draws as without it. Two plugins in this
repository form the Building Overlays family in the launcher: `building-overlays-recommended`
(offered first) switches on the recommended settings, `building-overlays-vanilla` keeps
everything off. A plugin's own overlays are drawn either way; plugins that build on the module
set the options they need themselves.

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

The flag layering switches take effect with **Draw overlays behind foreground buildings**.
