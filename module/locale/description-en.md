# Building Overlays

**Author**: Monsterfish
**Version**: 1.0.0

Draws extra pictures on top of buildings. The game does this itself for the crenellations
on towers: a picture that covers the walkway so units don't look like they stand outside
the tower, and that disappears when units are on it. This module lets pictures like that be
added for other buildings, and changed, just by dropping PNG files into its `overlays` folder.

## Large gatehouse

An empty large gatehouse gets a picture over its towers (one for a gatehouse whose entrance
looks to the lower left, one for the lower right). When troops go onto the gatehouse the
picture goes away. Can be switched off in the settings.

## Keep entrance

A fix for a bug of the game itself: on keeps turned one of two ways, the middle of the entrance
in front of the keep was drawn in the wrong light - a bright pillar between shaded towers, or a
dark one through a bright archway. Now it matches the towers beside it. Can be switched off in
the settings.

## Troops on the building

An overlay goes away while any unit stands on the building - except the lord, who always
stands on his keep and would otherwise hide a keep's overlay for good. With "Only hide the
overlays while the mouse is on the building" switched on, towers, gatehouses and keeps keep
their battlements drawn whoever stands on them, and only drop them while you point the mouse
at the building. That covers this module's overlays and the roofs of the game's towers; a
tower's crenellations and every other game overlay keep the game's own rules. An overlay with
`units = "any"` is always drawn - use that for crenellations that should cover the troops.

## Buildings in front cover the overlays

The game draws overlays in one piece at a building's front corner, so they show through towers
and walls standing right next to it. This module draws its own pictures, and the game's own
overlay pictures on every building, in narrow strips together with the building's tiles
instead, so whatever stands in front covers them. Parts hanging over the sides of a building go
with its back-most tile. Can be switched off in the settings ("Let buildings in front cover the
overlays").

## Moving overlays in the game

Select any building. Its panel lists its overlays on the left: this module's, and the game's
own pictures the building is drawn with, as "Game #n" (those can be moved too; when they show
stays the game's business). Click one to pick it: it is then shown on that building whatever is standing there,
with a magenta frame, and blue arrow buttons appear on the right of the panel. Each click
moves the picture by the step size; click "Step" to switch between 1, 5 and 20 pixels. Click
the picked overlay again to stop. "Save" writes every overlay's spot to `calibration.lua` in
the module folder; that file can go straight into a plugin as its `overlays.lua`. The tool
can be switched off in the settings.

## Adding or changing a picture

Put a PNG in the `overlays` folder (see-through parts stay see-through) and describe it in
`overlay_list.lua`: which building, which way the entrance faces, whether troops are on it, and
where the picture sits.

## Using it from a plugin

A plugin can bring its own overlays. Put the PNGs and an `overlays.lua` in the plugin's
`resources/modsupport/building-overlays/` folder, and call this from the plugin's `enable`:

    local overlays = modules["building-overlays"]
    if overlays ~= nil then
      overlays:registerOverlaySource("ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
    end

An overlay with the same name as one of the module's own replaces it. The Save button writes a
plugin's overlays straight back into that plugin's `overlays.lua`.
