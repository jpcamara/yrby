# Tile sources

`public/city/tiles.png` and `src/city_tiles.json` are built by
`bun tiles/make_tiles.mjs` from two sources.

## Kenney, Tiny Town (CC0)

`kenney_tiny_town.png` is `Tilemap/tilemap_packed.png` from Kenney's
Tiny Town 1.1, https://kenney.nl/assets/tiny-town, downloaded as
`kenney_tiny-town.zip`. License: Creative Commons Zero, see
`KENNEY_LICENSE.txt`. The city page uses these tiles, by their index in
the pack's `Tilesheet.txt` order (12 across):

| frame | tile |
|-------|------|
| grass, grass_flowers, grass_sparkle | 0, 1, 2 |
| road | 25 (the dirt patch's middle) |
| park | 28 (a tree) over 1 |
| sign | 83 (a signpost) over 0 |

## Drawn in make_tiles.mjs

Water, the bridge, the road's grass edges, the three houses, the shop,
the claim marker, the four people, and the planner are drawn in the
script as rows of characters, in Tiny Town's palette plus three blues for
water. They are original to this repository.
