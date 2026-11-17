# Roof Builder for Patterns

A Dungeondraft mod that turns Pattern Tool shapes into real roofs: gap-free tiling, gable roofs, conical / pyramid roofs and hip roofs, with shading and roofs that merge together.

Requires Dungeondraft 1.2.0.1 or later.

---

## Installation

1. Download the latest release and unzip it.
2. Put the `BetterRoofPatterns` folder in your Dungeondraft mods folder.
3. On Dungeondraft's start screen, open the **Mods** panel and enable **Roof Builder for Patterns**.

The folder must contain `BetterRoofPatterns.ddmod`, `scripts/` and `icons/`.

---

## Quick start

1. Select the **Pattern Tool** and pick a roof texture (tiles, slates, thatch...).
2. Turn on **Roof Builder** in the tool panel (under the Layer control) and choose a roof type.
   Two Slopes, Round Ends and Merge With Roof Below can be set here too.
3. Draw your shape: it becomes a roof.
4. Select it with the **Select Tool** to fine-tune it in the **Roof Builder** section.

You can also turn an existing pattern into a roof: select it with the Select Tool and turn **Roof Builder** on. Turning it off gives you the plain pattern back.

---

## Roof types

### Gap Free
The bottom edge of the texture (the eave) is drawn once, along the lower edge of the shape, and only the repeatable part of the texture is tiled above it. Large roofs no longer show holes or repeated eaves.

- **Two Slopes**: an eave on both sides with a ridge in the middle (gable roof). The far slope is the near one turned 180°. The texture rotation sets the ridge direction.
- **Ridge Offset**: shifts the tiles of the far slope so both slopes do not line up perfectly at the ridge.
- **Round Ends** (Two Slopes): rounds one end of the ridge (**Start** or **End**, along the texture direction) or **Both**, inside the drawn shape: half a cone as wide as the roof, with the tiles laid in rings. On short roofs the round end gets flatter instead of being cut. Draw the shape along the ridge.

### Centered
The outline of the shape becomes the eave and its centre the peak: conical towers, pyramid roofs, domes. Best on circles, ellipses and regular polygons.

- **Taper Toward Top**: each course of tiles has its own tile count, fewer and fewer toward the peak, like a real conical roof.
- **Custom Top Position**: moves the peak away from the centre with a dial (the dots around it lock the peak on a 45° direction). The lock button sets whether the peak stays in place on the map or turns with the shape.

### Hip
Every edge is an eave and the tile rows follow the nearest edge. A rectangle gets a ridge along its length, a square becomes a pyramid. Works with any shape, including L-shaped houses.

---

## Settings (Select Tool)

| Setting | What it does |
|---|---|
| **Seams** | Ridge and hip lines: **None** (plain cut), **Line** (ink line and crease shadow), **Soft** (blended over a few pixels, default) or **Ridge Caps**. Also in the Pattern Tool. |
| **Repeat Point** | Moves where the texture repeats along the slope, when the automatic repeat shows a seam or a band. |
| **Side Lines** | Dark outline on the sides where the texture is plainly cut (gable ends, eaves of textures without their own edge). |
| **Ridge Caps** (Seams) / **Cap Style** / **Cap Width** / **Cap Brightness** / **Cap Outline** (None / Line / Blurred) | Covers the ridge and hip lines (Hip, Gap Free with Two Slopes) with caps made from the roof texture itself: turned tiles (half-round tiles) or a band of the texture (slates, bricks, thatch). Ridges are wider than hips; caps meet in mitred joints and follow curved ridges. Curved parts of an outline (round ends, rounded corners) get no caps. |
| **Tile Width** | Width of the tiles. Rows keep their height, the shape keeps its size. |
| **Edge Offset** | Moves the eave inward (+) or outward (−). Empty rows under the eave are already removed automatically. |
| **Texture Offset** | Slides the texture sideways (Gap Free). |
| **Pitch** | Roof steepness: steeper roofs show more tile rows between the eave and the top. |
| **Shading** | Lights one side of the roof and darkens the other. |
| **Shading Strength** / **Light Direction** | Strength of the effect and where the light comes from (0° = top, clockwise). |
| **Global Lighting** | One light for every roof of the map: changing strength or direction changes all roofs at once. Saved with the map. |
| **Merge With Roof Below** | See below. |
| **Merge Height** | Raises (+) or lowers (−) this roof against the roofs below it. |

Every slider has a reset button. Changes apply to all selected roofs.

---

## Merging roofs

Draw a roof over another one and turn on **Merge With Roof Below** on the top roof: where the roof below rises higher, it shows through, so both roofs meet along their real intersection line, with an ink line and a soft valley shadow on both roofs.

- Works with several roofs below and with any roof type (e.g. a conical tower on a gable roof, an L-shaped house made of two hip roofs).
- Tip: put the roof with the most cut-out eave (round tiles, scales) on top, so its own edge is drawn over the other one.

---

## Good to know

- **Textures**: any pattern works. Textures with a transparent, cut-out bottom edge (tiles, slates) get the most out of the mod. Fully opaque textures simply tile.
- **Copy / paste / duplicate** keep the roof settings.
- **Saving**: roof settings are saved in the map. Without the mod, the map opens with plain patterns.
- **Undo**: if Dungeondraft rebuilds a pattern (texture change, undo...), the roof is applied again on the next frame.

---

## Compatibility

- **Colour and Modify Things**: coloured roofs keep their shape and shading, with every colour mode, gradient and edge blur. Turning the roof off keeps the colours.
- **Soft Shadows**: the Building Shadow tool can use roofs as building outlines (visible pixels only), and its Global Lighting option is linked to Roof Builder's.
- **Free Transform** (Unofficial Patch): a shape being free-transformed is left to that mod.

---

## For mod authors

Roof Builder registers itself as `Engine.get_meta("RoofBuilderForPatterns")` (a `WeakRef`). Available methods:

- `roof_api_version()`, `roof_api_alive()`, `roof_api_revision()`
- `roof_outlines_at(world_pos, extra = [], inset = 0.0)`: outlines of the visible roof pixels at a point (`null` while rendering, ask again a few frames later)
- `roof_global_light()`, `roof_set_global_light(fields)`

Pattern shapes with the node meta `roof_builder_skip` are never turned into roofs.

---

## Author

Made by **Moulk**.
