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

## Adding or changing a picture

Put a PNG in the `overlays` folder (see-through parts stay see-through) and describe it in
`overlay_list.lua`: which building, which way the entrance faces, whether troops are on it, and
where the picture sits. In the game, Alt + PageUp / PageDown picks an overlay, Alt + arrow
keys nudge it a pixel, and Alt + End saves the new spot.
