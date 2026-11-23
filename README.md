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
- **Profile**: Cone, Dome, Low Dome, Spire or Onion. Where the slope is steep the rows are packed closer together and extra rows are added; flat parts keep wide rows, and the shading follows the curve.
- **Curve** (Select Tool, not with Cone): how steep the slope gets at the eave. Higher packs the rows tighter there.
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
| **Tile Width** / **Pitch** link | The link buttons make them move together, so the tiles keep their shape (a steeper roof shows shorter rows and narrower tiles). |
| **Ridge Caps** (Seams) / **Cap Style** | Covers the ridge and hip lines (Hip, Gap Free with Two Slopes) with caps: turned tiles (half-round tiles) or a band of the roof texture (slates, bricks, thatch), Path Tool textures (**Path**: **Hip Path** and **Ridge Path**, each can be "Same as" the other, picked in a window with a search bar), or the ridge and hip strips of Roof Tool textures (**Roof Pieces**, greyed out for other textures). A roof whose texture or path is missing goes back to Auto. Caps follow curved ridges; curved parts of an outline (round ends, rounded corners) get no caps. The reset button next to Cap Style puts every cap setting back to its default. |
| **Width** (Hip / Ridge / Both) | The slider below sizes the hip caps, the ridge caps, or both together (keeping their ratio). Gap Free: ridges only. |
| **Cap Outline** | None / Line / Blurred. |
| **Cap Corners Style** / **Length** (cog) | End of the hips at the shape's corners: **Square** (cut like the corner, a point), **Round** (half circle) or **Flat**; Length moves the end past the corner or short of it. |
| **Ridge Ends** / **Ridge Fade** (cog) | **Mitred Faded**: caps meet in mitred joints, cross-faded over Ridge Fade (0%: hard cut). **Round**: the ridge is laid over the hips, ending in a half circle. |
| **Cap Recolor** / **Recolor** / **Cap Brightness** / **Cap Hue** / **Cap Saturation** | Recolours the hip caps, the ridge caps or both. Off: the caps keep their own colours. |
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

## Roof Tool textures

Some asset packs give their roofs to DD's Roof Tool (tiles plus ridge, hip and edge strips) rather than to the Pattern Tool.

- **Auto Roof Library** (top of the Roof Builder section, Select Tool and Pattern Tool): while Roof Builder is on, the pattern list only shows roof textures — the patterns that are roofs (also given to the Roof Tool, or in a folder with "roof" in its name), then the Roof Tool's own textures. Textures a pack gives both as a roof and as a pattern (same file) are only listed once. The full list comes back when Roof Builder is off. The setting is kept for every map.
- **Ridge Caps** use the pack's own ridge and hip strips when the roof texture comes with them (Cap Style **Roof Pieces**, picked by Auto), whether it was taken from the Roof Library or from the Patterns.

## Copying settings

**Copy Settings** (Select Tool, at the bottom of the Roof Builder section) takes every setting of the selected roof except its texture; **Paste Settings** gives them to the selected shapes, which become roofs if they were not.

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

Made with Claude AI.
