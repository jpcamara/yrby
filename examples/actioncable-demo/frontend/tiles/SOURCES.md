# Tile sources

`public/city/tiles.png` and `src/city_tiles.json` are built by
`bun tiles/make_tiles.mjs` from two sources. Everything in the sheet is
either Kenney's (CC0) or drawn in the script; nothing is taken from any
other site or game.

## Kenney, Tiny Town (CC0)

`kenney_tiny_town.png` is `Tilemap/tilemap_packed.png` from Kenney's
Tiny Town 1.1, https://kenney.nl/assets/tiny-town, downloaded as
`kenney_tiny-town.zip`. License: Creative Commons Zero, see
`KENNEY_LICENSE.txt`. The sheet uses these tiles, by their index in the
pack's `Tilesheet.txt` order (12 across):

| frame | tiles |
|-------|-------|
| grass_{band}_{0,1,2} | 0, 1, 2, each in four hill tints |
| path_{mask} | the dirt nine-slice 12, 13, 14, 24, 25, 26, 36, 37, 38, quartered and autotiled |
| plaza_{mask} | the stone nine-slice 96, 97, 98, 108, 109, 110, 120, 121, 122, the same way |
| cobble | 43 |
| park, pine, tree_orange | 5 over 16, 4 over 16, 3 over 15 (two cells tall) |
| tree_small, tree_orange_small, shrub, mushrooms | 28, 27, 17, 29 |
| bench | the left half of 80 and the right half of 82 |
| sign | 83 |
| cottage | roof 52, 54 over wall 84, 85 |
| stone_cottage | roof 48, 50 over wall 88, 89 |

## Drawn in make_tiles.mjs

In Tiny Town's palette plus water, asphalt, and the painted ladies' paint,
as rows of characters or as rectangles: the water in sixteen shore shapes
and two frames, the roads in sixteen shapes with kerbs and lane lines,
the cable car rails, the red bridge and its towers, the terrace ledges,
the fences, the lamp, the flowers, the hydrant, the cone, the three small
houses, the three Victorian houses, the grand house, the three shops, the
people (eight townsfolk, four visitors, the planner, three frames each),
the cars, the cable car, the gulls, the boats, and the waving hand. They
are original to this repository.

## Sound

The four sounds on the page (a blip, a hop, a chime, a bell) are
synthesised in `src/city.js` with the Web Audio API; there are no audio
files.
