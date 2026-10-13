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

## Moving overlays in the game

Hold Alt and press O (the key can be changed, or the tool switched off, in the settings). The
picked overlay gets a magenta frame and is shown whatever is standing on the building, with
blue arrow buttons beside it - up and down on its right, left and right underneath. Click an
arrow to move the picture one pixel, hold it to keep it moving. Alt + PageUp / PageDown picks
another overlay. Alt + End saves every overlay's spot to `calibration.lua` in the module folder;
that file can go straight into a plugin as its `overlays.lua`. Alt + O again ends the tool.

## Adding or changing a picture

Put a PNG in the `overlays` folder (see-through parts stay see-through) and describe it in
`overlay_list.lua`: which building, which way the entrance faces, whether troops are on it, and
where the picture sits.

## Using it from a plugin

A plugin can bring its own overlays. Put the PNGs and an `overlays.lua` (the file Alt + End
writes as `calibration.lua`) in the plugin's `resources/modsupport/building-overlays/` folder,
make the plugin depend on this module, and call this from the plugin's `enable`:

    modules["building-overlays"]:registerOverlaySource(
      "ucp/plugins/MyPlugin-*/resources/modsupport/building-overlays/")
