--[[
  The overlays this module draws. Each entry is a picture drawn on top of a building:

    name      shown in the log while you line it up
    group     the settings switch that turns it on or off (see options.yml)
    building  the building: a number (BT_ ids) or one of the names in init.lua
    picture   a PNG in the overlays folder, without ".png"
    entrance  "left", "right" or "any": which way the building's entrance faces on screen
              (left = it looks to the lower left, right = to the lower right)
    units     "empty" (nobody stands on it), "occupied" or "any"
    gate      gates only: "any", "open" or "closed"
    x, y      where the picture's top left corner sits, measured from the building's
              anchor point on screen (the point the game puts its own tower pictures at)

  Alt + arrow keys move the overlay picked with Alt + PageUp / PageDown in the game, and
  Alt + End saves the new spots to calibration.lua, which wins over x and y here.
]]
return {
  {
    name = "large_gatehouse_left", group = "large_gatehouse", building = "large_gatehouse",
    picture = "large_gatehouse_overlay_closed_left", entrance = "left", units = "empty",
    gate = "any", x = -107, y = -193,
  },
  {
    name = "large_gatehouse_right", group = "large_gatehouse", building = "large_gatehouse",
    picture = "large_gatehouse_overlay_closed_right", entrance = "right", units = "empty",
    gate = "any", x = -107, y = -193,
  },
}
