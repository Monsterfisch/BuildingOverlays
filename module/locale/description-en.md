# Building Overlays

**Author**: Monsterfish

Draws extra pictures on top of buildings. The game does this itself for the crenellations
on towers: a picture that covers the walkway so units don't look like they stand outside
the tower, and that disappears when units are on it. This module adds such pictures to other
buildings: PNGs listed in `overlay_list.lua` or in a plugin's `overlays.lua`. The overlay
tool in the building panel lines them up and saves their positions.
