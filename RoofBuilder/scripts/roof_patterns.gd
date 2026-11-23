# roof_patterns.gd
# Roof Builder for Patterns — roof helpers for Dungeondraft's Pattern Tool.
#
# Three per-shape modes, stored in ModMapData (saved with the map):
#   1. Gap Free Fill : roof textures with a non-seamless bottom edge (eave) no
#      longer leave holes when the shape is taller than the texture. The eave
#      is drawn once, on the lower edge of the shape (in texture orientation),
#      and only the repeatable body of the texture is tiled above it.
#      "Two Slopes" puts an eave on both sides (gable roof): the far slope is
#      the near one turned 180°, shifted by "Ridge Offset".
#   2. Centered Roof : the shape outline becomes the eave and a top point
#      (centre, or a custom position) the apex — conical / pyramidal roofs.
#      Optional per-course tile count (taper), pitch and directional shading.
#   3. Hip Roof      : every edge is an eave, rows follow the nearest edge
#      (rectangle -> ridge along its length, any polygon works).
#
# The texture is analysed once (alpha + best seam match + tile row height
# and tile width) to find the repeatable band, the empty rows below the
# eave, and where the courses of tiles start. Textures without a
# transparent edge simply tile as usual.
#
# Implementation: the PatternShape's ShaderMaterial is swapped for ours (same
# uniform names as DD's pattern shaders: albedo / rotation / use_wear / wear),
# so DD keeps saving texture/colour/rotation normally. If DD rebuilds the
# material (texture change, undo…), it is re-applied on the next frame.
# Without this mod, maps open with plain patterns.
#
# Other mods can ask for the outline of the visible pixels of the roofs (see
# "Public API for other mods"): Soft Shadows' Building Shadow tool uses it.
#
# Colour and Modify Things (uchideshi34) colours a pattern by giving it a
# material of its own. On a roof, Roof Builder takes its settings over
# (texture, rotation, colours, edge blur) and runs the same colour steps on
# the roof texture, before the roof shading. Turning the roof off gives the
# shape its Colour and Modify Things material back.

var _g

const STORE_KEY = "_roof_patterns"
const GLOBAL_KEY = "_roof_patterns_light"
const SKIP_META = "roof_builder_skip"        # node meta: other mods' pattern shapes that are never roofs
const SHADOW_REGISTRY = "BuildingShadowTex"  # Soft Shadows: {node id: opacity} of its building shadows
const CT_META = "roof_builder_ct_source"     # roof material meta: the Colour and Modify Things material it took over
const MODE_OFF = 0
const MODE_FILL = 1
const MODE_CENTER = 2
const MODE_HIP = 3
# Seams (ridge / hip lines): none, ink line + shadow, soft blend, ridge caps.
# Centered roofs: shape of the slope (cone, domes, spire, onion).
const PROFILE_CONE = 0
const PROFILE_DOME = 1
const PROFILE_LOW_DOME = 2
const PROFILE_SPIRE = 3
const PROFILE_ONION = 4
const PROFILE_LUT_N = 256
# Extra rows where a curved profile is steep (1 = none).
const PROFILE_ROW_GAMMA = 1.5
const PROFILE_ROW_GAMMA_SPIRE = 2.5
const SEAMS_NONE = 0
const SEAMS_LINE = 1
const SEAMS_SOFT = 2
const SEAMS_CAPS = 3
# Cap Style Path: Path Tool textures as ridge / hip caps.
const CAP_PATH = 4
# Ridge Path "Same as Hip".
const PATH_SAME_HIP = "@hip"
const LUT_N = 512
const MAX_MERGE = 8
const SMOOTH_MIN_POINTS = 16
const MAX_EDGES = 1024
const CAP_SIM = 0.766        # Ridge Caps: faces turned by less (~40°) are one curved surface
const MAX_CAP_ENDS = 32
const ANALYSIS_COLUMNS = 128
# Texture analyses kept between sessions (bump the version when the analysis changes).
const TEX_CACHE_PATH = "user://better_roof_patterns_textures.json"
const TEX_CACHE_VERSION = 1
const UI_TOOL_NAME = "BetterRoofPatternsToolSection"
const UI_SELECT_NAME = "BetterRoofPatternsSelectSection"
const HEADER_ICON_PX = 24
const RESET_ICON_PX = 16
const DIAL_SIZE = 90
const DIAL_PAD = 12          # room around the dial for the snap points

const DEFAULT_CFG = {
	"mode": 1,
	"edge": 0.0,
	"u_offset": 0.0,
	"scale": 100.0,
	"mirror": false,
	"ridge_offset": 25.0,
	"taper": true,
	"profile": PROFILE_CONE,
	"curve": 50.0,
	"size_link": false,
	"soft_seams": true,
	"pitch": 0.0,
	"shade_on": true,
	"shade": 0.4,
	"light": 315.0,
	"apex_on": false,
	"apex_x": 0.0,
	"apex_y": 0.0,
	"apex_lock": false,
	"merge": false,
	"merge_height": 0.0,
	"valley_line": 100.0,
	"valley_opacity": 35.0,
	"valley_width": 100.0,
	"side_ink": true,
	"ridge_caps": false,
	"cap_width": 100.0,
	"cap_width_hip": 100.0,
	"cap_width_on": 2,
	"cap_style": 0,
	"cap_path_ridge": "",
	"cap_path_hip": "",
	"cap_outline": 1,
	"cap_bright": 0.0,
	"cap_hue": 0.0,
	"cap_sat": 0.0,
	"cap_recolor": false,
	"cap_recolor_on": 2,
	"cap_corners": 1,
	"cap_tip": 35.0,
	"ridge_ends": 0,
	"cap_fade": 15.0,
	"seams": SEAMS_SOFT,
	"repeat": 0.0,
	"round_ends": 0,
}

# Colour and Modify Things: the settings of its material that matter for a
# pattern, with its defaults (copied into the "ct_" uniforms of the roof).
const CT_PARAMS = {
	"min_gray": 0.0,
	"max_gray": 1.0,
	"apply_grayscale": false,
	"saturation": 1.0,
	"hue_shift": 0.0,
	"lightness": 0.0,
	"contrast": 0.0,
	"invert": false,
	"sat_blacks": 0.0,
	"sat_midtones": 1.0,
	"sat_whites": 1.0,
	"sat_out_blacks": 0.0,
	"sat_out_whites": 1.0,
	"apply_saturation": false,
	"base_color": Color(1, 1, 1, 1),
	"apply_base_color": false,
	"gradient_tex": null,
	"apply_gradient": false,
	"is_colourable": false,
	"min_redness": 0.1,
	"red_tolerance": 0.04,
	"min_saturation": 0.0,
	"protect_hue": true,
	"protect_sat": true,
	"protect_light": true,
	"has_edge_blur": false,
	"vectors": null,
	"vectorsTextureWidth": 64,
	"vectorsCount": 0,
	"render_rect_position": Vector2(0, 0),
	"render_rect_size": Vector2(0, 0),
	"use_texture": false,
	"index_first_non_shadow": 0,
	"index_last_non_shadow": 0,
	"blur_range": 0.0,
	"shadow_direction": Vector2(0, 0),
	"edge_softness": 0.1,
	"reverse_alpha": false,
}

const SHADER_CODE = """shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D albedo;
uniform float rotation = 0.0;
uniform bool use_wear = false;
uniform sampler2D wear;
uniform bool custom_color = false;
uniform int roof_mode = 1;
uniform float band_start = 0.0;
uniform float band = 1024.0;
uniform float edge_shift = 0.0;
uniform float fade = 0.0;
uniform float body_end = 1024.0;
uniform float eave_band = 0.0;
uniform float seam_soft = 0.0;
uniform float tex_scale = 1.0;
uniform float row_h = 64.0;
uniform float tile_n = 0.0;
uniform float row_y0 = 0.0;
uniform float ref_d = 100.0;
uniform float perimeter = 1000.0;
uniform float v_max = 0.0;
uniform float v_min = 0.0;
uniform bool mirror = false;
// Ridge Caps: a row of cap tiles, made from the roof texture turned along the
// ridge / hip lines (one tile column wide, times cap_scale).
uniform bool ridge_caps = false;
uniform float cap_scale = 1.0;
uniform float cap_scale_hip = 1.0;
uniform int cap_tone_on = 2;
// 1 = tiles (one tile column turned along the line, for half-round tiles),
// 2 = band (one course of the texture laid along the line), 3 = the roof's
// own ridge / hip strips (Roof Tool assets).
uniform int cap_style = 2;
uniform sampler2D cap_ridge_tex;
uniform sampler2D cap_hip_tex;
// Rows (0..1, top / bottom) where those strips are visible: their shadow
// is cast around that part.
uniform vec2 cap_ridge_vis = vec2(0.0, 1.0);
uniform vec2 cap_hip_vis = vec2(0.0, 1.0);
// Thickness of the dark line along the strips' sides (share of their height).
uniform float cap_ridge_ink = 0.0;
uniform float cap_hip_ink = 0.0;
// Cap width base (texels): ridges get 1.15 of it, hips 0.8.
uniform float cap_base = 64.0;
// Hip roofs: lines ending at the centre of a curved part of the outline
// (edges rows 4-5, see _cap_ends).
uniform int cap_ends = 0;
// Ridge Caps outline: 0 none, 1 ink line, 2 blurred (fades out at its edges).
uniform int cap_outline = 1;
// Cap Brightness: gamma applied to the cap texture (< 1 brighter).
uniform float cap_gamma = 1.0;
// Cap Hue (turns, -0.5..0.5) and Cap Saturation (factor).
uniform float cap_hue = 0.0;
uniform float cap_sat = 1.0;
// Centered roofs: curved slope (Profile). profile_lut, at x = share of the
// way up as a cone (0 eave, 1 top): r = share of the way up along the curved
// slope, g = how much it slopes (shading, 1 = cone), b = inverse of r.
uniform bool profile_on = false;
// Slope length of the profile / radius: more rows where the slope is long.
uniform float profile_len = 1.0;
uniform sampler2D profile_lut : hint_black;
// Seams set to None: no ink line / shadow on hard ridge and hip lines.
uniform bool seam_lines = true;
// Size of the ink lines and seam shadows (texels): the tile row height, or a
// fixed share of the texture when no rows were found (thatch, hay...).
uniform float ink_h = 64.0;
// Round Ends (Two Slopes): the ends of the ridge become half cones, centred
// at round_x0 / round_x1 (texels along the ridge).
uniform bool round_start = false;
uniform bool round_end = false;
uniform float round_x0 = 0.0;
uniform float round_x1 = 0.0;
uniform float round_a = 1.0;
uniform float ridge_offset = 0.0;
uniform float u_offset = 0.0;
uniform bool side_ink = true;
uniform bool eave_cut = true;
uniform sampler2D lut;
uniform int lut_n = 256;
uniform vec2 center = vec2(0.0);
uniform float columns = 8.0;
uniform bool taper = true;
uniform sampler2D edges;
uniform int edge_count = 0;
uniform float pitch_scale = 1.0;
uniform bool smooth_shape = true;
uniform bool apex_moved = false;
uniform float shade = 0.0;
uniform vec2 light_dir = vec2(-0.7071, -0.7071);
// Merge With Roof Below: the roofs under this shape, 5 rows each in
// merge_data: params, outline table (Centered), edge table (3 rows).
uniform bool merge_on = false;
uniform sampler2D merge_data;
uniform int merge_count = 0;
uniform int merge_lut_n = 512;
// Valley shadow where two merged roofs meet: same strength and fade on both
// roofs.
uniform float valley_strength = 0.35;
// Width of the ink line on the junction (1 = default, 0 = none).
uniform float junction_ink = 1.0;
// Width of the valley shadow where two merged roofs meet (both sides).
uniform float valley_w = 40.0;
// Merge Height: raises (+) or lowers (-) this roof against the roofs below.
uniform float merge_raise = 0.0;
// Contact shadow: the part of this roof that is really drawn is blurred into
// a small texture (bake_mode, in its own Viewport), then a rectangle behind
// the shape (skirt_mode) darkens the roof below with it.
uniform bool skirt_mode = false;
uniform bool bake_mode = false;
uniform float skirt_w = 30.0;
uniform int bake_n = 64;
uniform sampler2D bake_tex : hint_black;
uniform vec2 bake_pos = vec2(0.0);
uniform vec2 bake_size = vec2(1.0);
uniform bool star_shape = true;
// Caps' rounded tips past the outline's corners (child shape drawn above).
uniform bool tip_mode = false;
// Caps at the outline's corners: 0 cut like the corner (a point), 1 rounded,
// 2 flat; tip_len: how far their end goes past the corner (visible half
// widths).
uniform int cap_corner = 1;
uniform float tip_len = 0.35;
// Ridge caps laid over the hips, ending rounded where they meet.
uniform bool cap_ridge_top = false;
// Where two caps meet (mitred): cross-faded over cap_fade (share of the
// cap's half width), or a hard cut when 0.
uniform float cap_fade = 0.2;
uniform float own_vis = 0.0;
// Colour and Modify Things (uchideshi34) colouring this roof: the settings of
// its material ("ct_" + its names) and its colour steps (ct_colour, from its
// universal shader 1.0.3). Its tint and opacity are the node's modulate,
// which Godot applies after this shader.
uniform bool ct_on = false;
uniform float ct_min_gray = 0.0;
uniform float ct_max_gray = 1.0;
uniform bool ct_apply_grayscale = false;
uniform float ct_saturation = 1.0;
uniform float ct_hue_shift = 0.0;
uniform float ct_lightness = 0.0;
uniform float ct_contrast = 0.0;
uniform bool ct_invert = false;
uniform float ct_sat_blacks = 0.0;
uniform float ct_sat_midtones = 1.0;
uniform float ct_sat_whites = 1.0;
uniform float ct_sat_out_blacks = 0.0;
uniform float ct_sat_out_whites = 1.0;
uniform bool ct_apply_saturation = false;
uniform vec4 ct_base_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool ct_apply_base_color = false;
uniform sampler2D ct_gradient_tex;
uniform bool ct_apply_gradient = false;
uniform bool ct_is_colourable = false;
uniform float ct_min_redness = 0.1;
uniform float ct_red_tolerance = 0.04;
uniform float ct_min_saturation = 0.0;
uniform bool ct_protect_hue = true;
uniform bool ct_protect_sat = true;
uniform bool ct_protect_light = true;
uniform bool ct_has_edge_blur = false;
uniform sampler2D ct_vectors;
uniform int ct_vectorsTextureWidth = 64;
uniform int ct_vectorsCount = 0;
uniform vec2 ct_render_rect_position = vec2(0.0);
uniform vec2 ct_render_rect_size = vec2(0.0);
uniform bool ct_use_texture = false;
uniform int ct_index_first_non_shadow = 0;
uniform int ct_index_last_non_shadow = 0;
uniform float ct_blur_range = 0.0;
uniform vec2 ct_shadow_direction = vec2(0.0);
uniform float ct_edge_softness = 0.1;
uniform bool ct_reverse_alpha = false;
varying vec2 v_local;

vec2 rotate_uv(vec2 uv, float r)
{
	float mid = 0.5;
	return vec2(
		cos(r) * (uv.x - mid) + sin(r) * (uv.y - mid) + mid,
		cos(r) * (uv.y - mid) - sin(r) * (uv.x - mid) + mid
	);
}

float roof_row(float t, float h)
{
	float y = h - edge_shift - t;
	if (y < band_start)
	{
		y = band_start + mod(y - band_start, band);
	}
	return y;
}

// One texture lookup: ux in tiles across, t in texels from the eave.
vec4 roof_sample(float ux, float t, float lod, vec2 size)
{
	float y = roof_row(t, size.y);
	vec4 c = textureLod(albedo, vec2(ux, min(y, size.y - 0.5) / size.y), lod);
	// Seam cross-fade: just above band_start the next rows come from the
	// bottom of the band (wrap), so blend toward the matching rows.
	if (fade > 0.0 && y >= band_start && y < band_start + fade)
	{
		float w = 1.0 - (y - band_start) / fade;
		c = mix(c, textureLod(albedo, vec2(ux, (y + band) / size.y), lod), w);
	}
	if (y >= size.y)
	{
		c.a = 0.0;
	}
	return c;
}

// Taper: tiles in course kf (courses are the rings at a constant fraction
// of the way to the top, one texture row high; the eave's partial course is
// merged into the first one so the eave tiles are never cut).
float course_tiles(float kf, float t0, float d_ref, float tiles_eave)
{
	float t_mid = kf < 0.5 ? (t0 + row_h) * 0.5 : t0 + (kf + 0.5) * row_h;
	float u_k = clamp(t_mid / (pitch_scale * d_ref * (profile_on ? profile_len : 1.0)), 0.0, 1.0);
	if (profile_on)
	{
		u_k = texture(profile_lut, vec2(u_k, 0.5)).b;
	}
	float s_k = 1.0 - u_k;
	float n = tiles_eave * s_k;
	// Single tiles known: always a whole number of tiles, the course loops
	// without any seam. Otherwise (thatch...) exact count, the loop seam is
	// blended.
	if (tile_n > 0.0)
	{
		n = floor(n + 0.5);
	}
	return max(n, 1.0);
}

// Round Ends: distance from the eave (texels, before Pitch) of a point b of
// texture space (rotated, in texels) in a round end of a Two Slopes roof
// whose eaves are at v_hi / v_lo (texels), ra: length of the round end along
// the ridge; -1 outside the round end, -2 when
// b is not in a round end.
float round_end_t(vec2 b, float v_hi, float v_lo, bool rs, bool re, float x0, float x1, float ra)
{
	float xc = 0.0;
	if (rs && b.x < x0)
	{
		xc = x0;
	}
	else if (re && b.x > x1)
	{
		xc = x1;
	}
	else
	{
		return -2.0;
	}
	float rr = (v_hi - v_lo) * 0.5;
	// Half an ellipse: ra along the ridge (shorter than rr on short roofs).
	float rho = length(vec2((b.x - xc) / max(ra, 0.001), (b.y - (v_hi + v_lo) * 0.5) / max(rr, 0.001)));
	return rho > 1.0 ? -1.0 : (1.0 - rho) * rr;
}

// Height of merged roof pi at v, from its visible eave, in the same units as
// t (distance from the eave); -1 outside it.
float merge_height(vec2 v, int pi)
{
	int r0 = pi * 5;
	vec4 p0 = texelFetch(merge_data, ivec2(0, r0), 0);
	vec4 p1 = texelFetch(merge_data, ivec2(1, r0), 0);
	vec4 p2 = texelFetch(merge_data, ivec2(2, r0), 0);
	vec4 p3 = texelFetch(merge_data, ivec2(3, r0), 0);
	vec4 p4 = texelFetch(merge_data, ivec2(4, r0), 0);
	int mode = int(p0.x + 0.5);
	int n_edges = int(p0.y + 0.5);
	vec2 q = p1.xy * v.x + p1.zw * v.y + p2.xy;
	if (mode == 2 && p3.w > 0.5)
	{
		// Centered roof crossed once in every direction from its top: its
		// radius table alone tells inside from outside (no edge loop).
		vec2 pc = q - p2.zw;
		float rc = length(pc);
		float nfc = float(merge_lut_n);
		float fc = (atan(pc.y, pc.x) + 3.14159265) / 6.28318531 * nfc - 0.5;
		float flc = floor(fc);
		float ra0 = texelFetch(merge_data, ivec2(int(mod(flc, nfc)), r0 + 1), 0).x;
		float rb0 = texelFetch(merge_data, ivec2(int(mod(flc + 1.0, nfc)), r0 + 1), 0).x;
		float rrc = max(mix(ra0, rb0, fc - flc), 0.001);
		if (rc >= rrc)
		{
			return -1.0;
		}
		return (1.0 - rc / rrc) * p3.x * p3.y - p0.w;
	}
	bool inside = false;
	float d_edge = 100000000.0;
	for (int i = 0; i < n_edges; i++)
	{
		vec4 e = texelFetch(merge_data, ivec2(i, r0 + 2), 0);
		if ((e.y > q.y) != (e.w > q.y) && q.x < (e.z - e.x) * (q.y - e.y) / (e.w - e.y) + e.x)
		{
			inside = !inside;
		}
		if (mode == 3)
		{
			// Same faces as a Hip roof (straight valleys at inner corners).
			vec4 fl = texelFetch(merge_data, ivec2(i, r0 + 3), 0);
			vec4 nb = texelFetch(merge_data, ivec2(i, r0 + 4), 0);
			vec2 ab = e.zw - e.xy;
			float h = dot(q - e.xy, ab) / max(dot(ab, ab), 0.000001);
			bool inner = dot(q - e.xy, fl.xy) <= 0.0;
			bool ext = (h >= 0.0 && h <= 1.0)
				|| (inner && h < 0.0 && fl.z > 0.5 && dot(q - e.xy, nb.xy + normalize(ab)) > 0.0)
				|| (inner && h > 1.0 && fl.w > 0.5 && dot(q - e.zw, normalize(ab) + nb.zw) < 0.0);
			float dd = ext ? abs(dot(q - e.xy, fl.xy)) : length(q - e.xy - ab * clamp(h, 0.0, 1.0));
			if (!ext && ((h < 0.0 && fl.z > 0.5) || (h > 1.0 && fl.w > 0.5)))
			{
				dd = 100000000.0;
			}
			d_edge = min(d_edge, dd);
		}
	}
	if (!inside)
	{
		return -1.0;
	}
	float hm = 0.0;
	if (mode == 1)
	{
		vec2 base = rotate_uv(q / p4.xy, p3.z);
		hm = (p4.z - base.y) * p4.y;
		if (p0.z > 0.5)
		{
			hm = min(hm, (base.y - p4.w) * p4.y);
			vec4 p5 = texelFetch(merge_data, ivec2(5, r0), 0);
			if (p5.x > 0.5)
			{
				int fl5 = int(p5.x + 0.5);
				float rt = round_end_t(base * p4.xy, p4.z * p4.y, p4.w * p4.y, fl5 == 1 || fl5 == 3, fl5 >= 2, p5.y, p5.z, p5.w);
				if (rt > -1.5)
				{
					if (rt < 0.0)
					{
						return -1.0;
					}
					hm = rt;
				}
			}
		}
		hm *= p3.y;
	}
	else if (mode == 3)
	{
		hm = d_edge * p3.y;
	}
	else
	{
		vec2 p = q - p2.zw;
		float r = length(p);
		float nf = float(merge_lut_n);
		float f = (atan(p.y, p.x) + 3.14159265) / 6.28318531 * nf - 0.5;
		float fl = floor(f);
		float fr = f - fl;
		float ra = texelFetch(merge_data, ivec2(int(mod(fl, nf)), r0 + 1), 0).x;
		float rb = texelFetch(merge_data, ivec2(int(mod(fl + 1.0, nf)), r0 + 1), 0).x;
		float rr = max(mix(ra, rb, fr), 0.001);
		hm = max(1.0 - r / rr, 0.0) * p3.x * p3.y;
	}
	return hm - p0.w;
}

// Highest of the merged roofs at v (they form one roof surface), -1 where
// none of them is.
float merge_height_all(vec2 v)
{
	float hb = -1.0;
	for (int pi = 0; pi < merge_count; pi++)
	{
		float hp = merge_height(v, pi);
		if (hp >= 0.0)
		{
			hb = max(hb, hp);
		}
	}
	return hb;
}

bool in_shape(vec2 p)
{
	bool inside = false;
	for (int i = 0; i < edge_count; i++)
	{
		vec4 e = texelFetch(edges, ivec2(i, 0), 0);
		if ((e.y > p.y) != (e.w > p.y) && p.x < (e.z - e.x) * (p.y - e.y) / (e.w - e.y) + e.x)
		{
			inside = !inside;
		}
	}
	return inside;
}

// This roof's own height at p (local), the same value as in fragment(), for
// tests away from the pixel. -1 outside the shape.
float own_height(vec2 p)
{
	if (roof_mode == 2)
	{
		vec2 q = p - center;
		float r = length(q);
		float nf = float(lut_n);
		float f = (atan(q.y, q.x) + 3.14159265) / 6.28318531 * nf - 0.5;
		float fl = floor(f);
		float fr = f - fl;
		vec4 a0 = texelFetch(lut, ivec2(int(mod(fl, nf)), 0), 0);
		vec4 a1 = texelFetch(lut, ivec2(int(mod(fl + 1.0, nf)), 0), 0);
		float rr = max(mix(a0.x, a1.x, fr), 0.001);
		if (abs(a0.x - a1.x) > 0.08 * max(a0.x, a1.x))
		{
			rr = max(fr < 0.5 ? a0.x : a1.x, 0.001);
		}
		if (star_shape)
		{
			if (r >= rr)
			{
				return -1.0;
			}
		}
		else if (!in_shape(p))
		{
			return -1.0;
		}
		float d_ref = max(ref_d, 0.001);
		float t = (1.0 - clamp(r / rr, 0.0, 1.0)) * d_ref * pitch_scale;
		float eb = eave_band * pitch_scale;
		float dd = max(rr - r, 0.0) * pitch_scale;
		float rrp = rr * pitch_scale;
		float full = d_ref * pitch_scale;
		if (eb > 0.0 && rrp > eb * 2.0 && full > eb * 2.0)
		{
			t = dd <= eb ? dd : eb + (dd - eb) * (full - eb) / (rrp - eb);
		}
		if (!smooth_shape && seam_soft > 0.0 && edge_count > 0)
		{
			// Faceted roof: lower envelope of the edge planes.
			float q1 = 100000000.0;
			for (int i = 0; i < edge_count; i++)
			{
				vec4 e = texelFetch(edges, ivec2(i, 0), 0);
				vec4 en = texelFetch(edges, ivec2(i, 1), 0);
				float ad = texelFetch(edges, ivec2(i, 3), 0).x;
				q1 = min(q1, dot(e.xy - p, en.xy) / max(ad, 0.001));
			}
			t = max(q1, 0.0) * d_ref * pitch_scale;
		}
		return t;
	}
	if (roof_mode == 3)
	{
		bool inside = false;
		float best = 100000000.0;
		for (int i = 0; i < edge_count; i++)
		{
			vec4 e = texelFetch(edges, ivec2(i, 0), 0);
			vec4 fl = texelFetch(edges, ivec2(i, 1), 0);
			vec4 nb = texelFetch(edges, ivec2(i, 2), 0);
			if ((e.y > p.y) != (e.w > p.y) && p.x < (e.z - e.x) * (p.y - e.y) / (e.w - e.y) + e.x)
			{
				inside = !inside;
			}
			vec2 ab = e.zw - e.xy;
			float h = dot(p - e.xy, ab) / max(dot(ab, ab), 0.000001);
			bool inner = dot(p - e.xy, fl.xy) <= 0.0;
			bool ext = (h >= 0.0 && h <= 1.0)
				|| (inner && h < 0.0 && fl.z > 0.5 && dot(p - e.xy, nb.xy + normalize(ab)) > 0.0)
				|| (inner && h > 1.0 && fl.w > 0.5 && dot(p - e.zw, normalize(ab) + nb.zw) < 0.0);
			float dd = ext ? abs(dot(p - e.xy, fl.xy)) : length(p - e.xy - ab * clamp(h, 0.0, 1.0));
			if (!ext && ((h < 0.0 && fl.z > 0.5) || (h > 1.0 && fl.w > 0.5)))
			{
				dd = 100000000.0;
			}
			best = min(best, dd);
		}
		return inside ? best * pitch_scale : -1.0;
	}
	if (!in_shape(p))
	{
		return -1.0;
	}
	vec2 size = vec2(textureSize(albedo, 0));
	vec2 base = rotate_uv(p / size, rotation);
	if (mirror)
	{
		float rt = round_end_t(base * size, v_max * size.y, v_min * size.y, round_start, round_end, round_x0, round_x1, round_a);
		if (rt > -1.5)
		{
			return rt < 0.0 ? -1.0 : rt * pitch_scale;
		}
	}
	float t = (v_max - base.y) * size.y;
	if (mirror)
	{
		t = min(t, (base.y - v_min) * size.y);
	}
	return t * pitch_scale;
}

// Is this roof really drawn at p? (inside the shape, above its visible eave,
// and not hidden under a merged roof that rises higher.)
bool roof_drawn(vec2 p)
{
	float ho = own_height(p);
	if (ho < 0.0)
	{
		return false;
	}
	ho -= own_vis;
	if (ho < 0.0)
	{
		return false;
	}
	float hb = merge_height_all(p);
	return hb < 0.0 || ho + merge_raise >= hb;
}

// Bake: share of a disc of radius skirt_w around v where this roof is drawn
// (0.5 on a straight edge of the drawn part, falling to 0 at skirt_w from it).
float bake_coverage(vec2 v)
{
	float acc = 0.0;
	float n = float(bake_n);
	for (int i = 0; i < bake_n; i++)
	{
		float fi = float(i);
		float rad = sqrt((fi + 0.5) / n) * skirt_w;
		float ang = fi * 2.39996323;
		if (roof_drawn(v + vec2(cos(ang), sin(ang)) * rad))
		{
			acc += 1.0;
		}
	}
	return acc / n;
}

// Skirt: soft shadow on the roof below, all around the drawn part of this
// roof (junction lines, sides without an eave, corners), from the bake.
// Valley shadow profile: x = 1 on the line where the roofs meet, 0 at its
// width; smooth at both ends.
float valley_fade(float x)
{
	x = clamp(x, 0.0, 1.0);
	return x * x * (3.0 - 2.0 * x);
}

vec4 skirt_shadow(vec2 v)
{
	float c = textureLod(bake_tex, (v - bake_pos) / bake_size, 0.0).r;
	if (c <= 0.004)
	{
		return vec4(0.0);
	}
	// Only on a merged roof (inside its visible eave).
	if (merge_height_all(v) < 0.0)
	{
		return vec4(0.0);
	}
	// c = share of a disc of radius skirt_w covered by the roof above: back
	// to the distance from its edge, so this side fades exactly like the
	// other one (valley_fade).
	float x = 1.0;
	if (c < 0.5)
	{
		float lo = 0.0;
		float hi = 1.0;
		for (int i = 0; i < 10; i++)
		{
			float u = (lo + hi) * 0.5;
			float f = (acos(u) - u * sqrt(1.0 - u * u)) / 3.14159265;
			if (f > c)
			{
				lo = u;
			}
			else
			{
				hi = u;
			}
		}
		x = 1.0 - (lo + hi) * 0.5;
	}
	// Nothing deep under the drawn part itself (it would show through
	// translucent textures).
	return vec4(0.0, 0.0, 0.0, valley_strength * valley_fade(x) * (1.0 - smoothstep(0.8, 0.97, c)));
}

float course_rand(float k)
{
	return fract(sin(k * 12.9898 + 4.1414) * 43758.5453);
}

// Round Ends: arc length on the ellipse (ra along the ridge, rr across) from
// its near-slope end to angle phi (Simpson, 8 steps).
float round_arc(float phi, float ra, float rr)
{
	float h = phi / 8.0;
	float acc = 0.0;
	for (int i = 0; i <= 8; i++)
	{
		float th = h * float(i);
		float f = sqrt(ra * ra * cos(th) * cos(th) + rr * rr * sin(th) * sin(th));
		float wgt = (i == 0 || i == 8) ? 1.0 : (i % 2 == 1 ? 4.0 : 2.0);
		acc += wgt * f;
	}
	return acc * h / 3.0;
}

// ── Colour and Modify Things (same steps as its universal shader) ──

vec3 ct_rgb2hsv(vec3 c)
{
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 ct_hsv2rgb(vec3 c)
{
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// Colourable pixel (red enough), with the asset pack's values.
bool ct_red_enough(vec4 color)
{
	bool is_red = abs(color.g - color.b) <= ct_red_tolerance;
	bool within_sat = 1.0 - ((color.g + color.b) * 0.5) >= ct_min_saturation;
	float redness = color.r - (color.g + color.b) * 0.5;
	return is_red && within_sat && redness > ct_min_redness;
}

// Hue, lightness, contrast, levels and invert. skip_hue / skip_light: the
// colourable pixels it protects.
vec3 ct_adjust(vec3 c, bool skip_hue, bool skip_light)
{
	if (!skip_hue && abs(ct_hue_shift) > 0.001)
	{
		vec3 hsv = ct_rgb2hsv(c);
		hsv.x = fract(hsv.x + ct_hue_shift * 0.5);
		c = ct_hsv2rgb(hsv);
	}
	if (!skip_light && abs(ct_lightness) > 0.001)
	{
		if (ct_lightness > 0.0)
		{
			c = mix(c, vec3(1.0), ct_lightness);
		}
		else
		{
			c = mix(c, vec3(0.0), -ct_lightness);
		}
	}
	if (abs(ct_contrast) > 0.001)
	{
		if (ct_contrast > 0.0)
		{
			c = clamp((c - vec3(0.5)) * (1.0 + ct_contrast * 2.0) + vec3(0.5), 0.0, 1.0);
		}
		else
		{
			c = mix(c, vec3(0.5), -ct_contrast);
		}
	}
	float range = max(ct_sat_whites - ct_sat_blacks, 0.001);
	c = clamp((c - vec3(ct_sat_blacks)) / range, 0.0, 1.0);
	c = pow(c, vec3(1.0 / ct_sat_midtones));
	c = mix(vec3(ct_sat_out_blacks), vec3(ct_sat_out_whites), c);
	if (ct_invert)
	{
		c = vec3(1.0) - c;
	}
	return c;
}

// The colour of a texel (rgba, before the modulate).
vec4 ct_colour(vec4 color)
{
	bool red = ct_is_colourable && ct_red_enough(color);
	if (ct_is_colourable && ct_apply_base_color && ct_apply_grayscale && ct_apply_saturation)
	{
		// Colourable texture with a colour: the red pixels take it.
		float range = ct_max_gray - ct_min_gray;
		vec3 sc;
		if (red)
		{
			float gray = clamp((color.r - ct_min_gray) / range, 0.0, 1.0);
			vec3 base_hsv = ct_rgb2hsv(ct_base_color.rgb);
			float sat = ct_protect_sat ? base_hsv.y : base_hsv.y * ct_saturation;
			sc = ct_hsv2rgb(vec3(base_hsv.x, sat, gray * base_hsv.z));
		}
		else
		{
			float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
			gray = clamp((gray - ct_min_gray) / range, 0.0, 1.0);
			sc = mix(vec3(gray), color.rgb, ct_saturation);
		}
		return vec4(ct_adjust(sc, red && ct_protect_hue, red && ct_protect_light), color.a);
	}
	if ((!ct_is_colourable || red) && ct_apply_grayscale)
	{
		float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
		if (red)
		{
			gray = color.r;
		}
		if (ct_apply_gradient)
		{
			vec4 gc = textureLod(ct_gradient_tex, vec2(gray, 0.0), 0.0);
			return vec4(gc.rgb, gc.a * color.a);
		}
		if (abs(ct_min_gray - ct_max_gray) <= 0.0001)
		{
			// White: plain grey level.
			return vec4(vec3(ct_min_gray), color.a);
		}
		gray = clamp((gray - ct_min_gray) / (ct_max_gray - ct_min_gray), 0.0, 1.0);
		if (ct_apply_saturation)
		{
			vec3 sc;
			if (ct_apply_base_color)
			{
				vec3 base_hsv = ct_rgb2hsv(ct_base_color.rgb);
				sc = ct_hsv2rgb(vec3(base_hsv.x, base_hsv.y * ct_saturation, gray * base_hsv.z));
			}
			else
			{
				sc = mix(vec3(gray), color.rgb, ct_saturation);
			}
			return vec4(ct_adjust(sc, false, false), color.a);
		}
		return vec4(vec3(gray), color.a);
	}
	return color;
}

// Edge blur: smoothed distance to the outline it stored (vectors).
float ct_smin(float a, float b, float k)
{
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

float ct_edge_sdf(vec2 p, vec2 a, vec2 b)
{
	vec2 ab = b - a;
	vec2 ap = p - a;
	if (dot(ab, ab) > 0.0)
	{
		float t = clamp(dot(ap, ab) / dot(ab, ab), 0.0, 1.0);
		return length(p - (a + t * ab));
	}
	return length(p - a);
}

vec2 ct_vector(int i)
{
	ivec2 coord = ivec2(i % ct_vectorsTextureWidth, i / ct_vectorsTextureWidth);
	return texelFetch(ct_vectors, coord, 0).xy * 10000.0;
}

float ct_polygon_sdf(vec2 p)
{
	float min_dist = 1000000.0;
	float k = ct_edge_softness * min(ct_render_rect_size.x, ct_render_rect_size.y);
	if (length(ct_shadow_direction) < 0.05)
	{
		for (int i = 0; i < ct_vectorsCount; i++)
		{
			vec2 a = ct_vector(i);
			vec2 b = ct_vector((i + 1) % ct_vectorsCount);
			min_dist = ct_smin(min_dist, ct_edge_sdf(p, a, b), k);
		}
	}
	else
	{
		// Only the sides away from the shadow direction.
		for (int i = 0; i < ct_vectorsCount; i++)
		{
			if (ct_index_first_non_shadow + i > ct_index_last_non_shadow)
			{
				break;
			}
			vec2 a = ct_vector((ct_index_first_non_shadow + i) % ct_vectorsCount);
			vec2 b = ct_vector((ct_index_first_non_shadow + i + 1) % ct_vectorsCount);
			min_dist = ct_smin(min_dist, ct_edge_sdf(p, a, b), k);
		}
	}
	return min_dist;
}

vec4 ct_edge_blur(vec4 color, vec2 v)
{
	float dist = ct_polygon_sdf(v - ct_render_rect_position);
	float scaled_blur = ct_blur_range * 256.0;
	float alpha = 1.0;
	if (dist < 0.0)
	{
		alpha = 0.0;
	}
	else if (dist < scaled_blur)
	{
		alpha = dist / scaled_blur;
	}
	if (ct_reverse_alpha)
	{
		alpha = clamp(1.0 - alpha, 0.0, 1.0);
	}
	if (ct_use_texture)
	{
		color.a *= alpha;
	}
	else
	{
		// Plain white with the texture's alpha.
		color = vec4(vec3(1.0), color.a * alpha);
	}
	return color;
}

// Ridge Caps: one cap piece. a: along the cap (texels, from where its tiles
// start), sx: across the cap (-1..1 on its sides), et:
// past its end (0..1 on the rounded end, along end_dir), hw: half width.
// Adds the cap's small shadow on the roof beside it to shadow.
// Light factor of a face with normal n: the shadowed side gets darker than
// the lit side gets lighter.
float shade_light(vec2 n)
{
	float d = dot(n, light_dir);
	float k = d < 0.0 ? 1.3 : 0.6;
	return max(1.0 + shade * k * d, 0.0);
}

// Half width of a cap (ridge or hip), in local pixels.
// Cap Brightness, Hue and Saturation (on the hips, the ridges or both:
// cap_tone_on 0 / 1 / 2).
vec3 cap_tone(vec3 c, bool is_ridge)
{
	if ((cap_tone_on == 0 && is_ridge) || (cap_tone_on == 1 && !is_ridge))
	{
		return c;
	}
	c = pow(max(c, vec3(0.0)), vec3(cap_gamma));
	if (abs(cap_hue) > 0.0001 || abs(cap_sat - 1.0) > 0.0001)
	{
		vec3 hsv = ct_rgb2hsv(c);
		hsv.x = fract(hsv.x + cap_hue);
		hsv.y = clamp(hsv.y * cap_sat, 0.0, 1.0);
		c = ct_hsv2rgb(hsv);
	}
	return c;
}

float cap_hw(bool is_ridge, float cosn)
{
	if (cap_style == 3)
	{
		// Roof Tool strips: as wide as they are tall (as DD draws them).
		vec2 ps = vec2(is_ridge ? textureSize(cap_ridge_tex, 0) : textureSize(cap_hip_tex, 0));
		return max(ps.y, 2.0) * 0.5 * (is_ridge ? cap_scale : cap_scale_hip);
	}
	return cap_base * mix(0.8, 1.15, clamp(-cosn, 0.0, 1.0)) * (is_ridge ? cap_scale : cap_scale_hip) * 0.5;
}

// Half width of the visible part of a cap (Roof Tool strips: without their
// transparent margins).
float cap_vhw(bool is_ridge, float hw)
{
	if (cap_style == 3)
	{
		vec2 vis = is_ridge ? cap_ridge_vis : cap_hip_vis;
		return max(vis.y - vis.x, 0.04) * hw;
	}
	return hw;
}

vec4 cap_piece(float a, float sx, float et, vec2 across, vec2 end_dir, float hw, vec4 tint, vec2 size, float cpx, inout float shadow, bool is_ridge)
{
	float r = length(vec2(sx, max(et, 0.0)));
	if (cap_style == 3 && cap_outline != 2)
	{
		// Roof Tool strip: shadow around its visible part.
		vec2 vis = is_ridge ? cap_ridge_vis : cap_hip_vis;
		float vh = max((vis.y - vis.x) * 0.5, 0.02);
		float vv = ((0.5 + 0.5 * sx) - (vis.x + vis.y) * 0.5) / vh;
		float rv = length(vec2(vv, max(et, 0.0) * 0.5 / vh));
		if (rv > 1.0)
		{
			float spread = max(vh * 2.0 * hw, cpx * 4.0);
			shadow = max(shadow, 1.0 - clamp((rv - 1.0) * vh * 2.0 * hw / spread, 0.0, 1.0));
		}
	}
	if (r > 1.0)
	{
		// Small shadow beside the cap (none when it fades out: Blurred, and
		// none for Roof Tool strips: they get one from their own shape).
		if (cap_outline != 2 && cap_style != 3)
		{
			shadow = max(shadow, 1.0 - clamp((r - 1.0) / 0.6, 0.0, 1.0));
		}
		return vec4(0.0);
	}
	vec2 cuv;
	float k_len;
	if (cap_style == 3)
	{
		// The roof's own ridge / hip strip, laid along the line.
		vec2 ps = vec2(is_ridge ? textureSize(cap_ridge_tex, 0) : textureSize(cap_hip_tex, 0));
		float k = ps.y / (2.0 * hw);
		vec2 puv = vec2(a * k / ps.x, 0.5 + 0.5 * sx);
		float lod = max(log2(cpx * k), 0.0);
		// Rounded end: a half circle as wide as the strip's visible part,
		// with a dark line as thick as the one along its sides.
		vec2 vs = is_ridge ? cap_ridge_vis : cap_hip_vis;
		float vhs = max((vs.y - vs.x) * 0.5, 0.02);
		float e_al = max(et, 0.0) * 0.5 / vhs;
		float e_rv = length(vec2(((0.5 + 0.5 * sx) - (vs.x + vs.y) * 0.5) / vhs, e_al));
		float e_px = (1.0 - e_rv) * vhs * 2.0 * hw;
		float e_k = et > 0.0 ? clamp(e_px / cpx + 0.5, 0.0, 1.0) : 1.0;
		if (e_k <= 0.0)
		{
			return vec4(0.0);
		}
		vec4 pc;
		if (is_ridge)
		{
			pc = textureLod(cap_ridge_tex, puv, lod);
		}
		else
		{
			pc = textureLod(cap_hip_tex, puv, lod);
		}
		vec3 pcc = ct_on ? ct_colour(pc).rgb : pc.rgb * tint.rgb;
		pcc = cap_tone(pcc, is_ridge);
		if (shade > 0.0)
		{
			pcc *= shade_light(across * sx * 0.5 + end_dir * max(et, 0.0));
		}
		float p_ink = max(ink_h * 0.03, cpx * 1.2);
		if (cap_outline == 1)
		{
			pcc *= mix(1.0, 0.15, 1.0 - smoothstep(p_ink * 0.5, p_ink, (1.0 - r) * hw));
		}
		float s_ink = (is_ridge ? cap_ridge_ink : cap_hip_ink) * 2.0 * hw;
		if (et > 0.0 && s_ink > 0.0)
		{
			s_ink = max(s_ink, cpx * 1.2);
			pcc *= mix(1.0, 0.12, (1.0 - smoothstep(s_ink - cpx, s_ink, e_px)) * smoothstep(0.0, 0.4, e_al));
		}
		float pk = clamp((1.0 - r) * hw / cpx + 0.5, 0.0, 1.0) * pc.a * e_k;
		if (cap_outline == 2)
		{
			pk *= smoothstep(0.0, 0.55, 1.0 - r);
		}
		return vec4(pcc, pk);
	}
	if (cap_style == 1)
	{
		// One tile column turned along the line, fitted to the width.
		float col_w = tile_n > 0.0 ? size.x / tile_n : max(row_h, 1.0);
		k_len = 2.0 * hw / col_w;
		cuv = vec2((0.5 + 0.5 * sx) * col_w / size.x, band_start + mod(a / k_len, band));
	}
	else
	{
		// One course of the texture laid along the line.
		float rh = min(max(row_h, 1.0), band);
		k_len = 2.0 * hw / rh;
		float cy = row_y0 + (0.5 - 0.5 * sx) * rh;
		cuv = vec2(a / k_len / size.x, band_start + mod(cy - band_start, band));
	}
	vec4 cap = textureLod(albedo, vec2(cuv.x, cuv.y / size.y), max(log2(cpx / k_len), 0.0));
	vec3 cc = ct_on ? ct_colour(cap).rgb : cap.rgb * tint.rgb;
	cc = cap_tone(cc, is_ridge);
	// Rounded: darker toward its sides and end, lit across.
	cc *= 1.0 - 0.3 * r * r;
	if (shade > 0.0)
	{
		cc *= shade_light(across * sx + end_dir * max(et, 0.0));
	}
	float c_ink = max(ink_h * 0.03, cpx * 1.2);
	if (cap_outline == 1)
	{
		cc *= mix(1.0, 0.15, 1.0 - smoothstep(c_ink * 0.5, c_ink, (1.0 - r) * hw));
	}
	float ck = clamp((1.0 - r) * hw / cpx + 0.5, 0.0, 1.0) * smoothstep(0.3, 0.7, cap.a);
	if (cap_outline == 2)
	{
		// Blurred: the cap fades out toward its sides and ends.
		ck *= smoothstep(0.0, 0.55, 1.0 - r);
	}
	return vec4(cc, ck);
}

// Distance from v to face i as the Hip mode measures it: past an inner
// corner the face's plane runs on (on the far side of the valley only).
float hip_face_d(vec2 v, int i)
{
	vec4 e = texelFetch(edges, ivec2(i, 0), 0);
	vec4 fl = texelFetch(edges, ivec2(i, 1), 0);
	vec4 nb = texelFetch(edges, ivec2(i, 2), 0);
	vec2 ab = e.zw - e.xy;
	float h = dot(v - e.xy, ab) / max(dot(ab, ab), 0.000001);
	bool inner = dot(v - e.xy, fl.xy) <= 0.0;
	bool ext = (h >= 0.0 && h <= 1.0)
		|| (inner && h < 0.0 && fl.z > 0.5 && dot(v - e.xy, nb.xy + normalize(ab)) > 0.0)
		|| (inner && h > 1.0 && fl.w > 0.5 && dot(v - e.zw, normalize(ab) + nb.zw) < 0.0);
	if (!ext && ((h < 0.0 && fl.z > 0.5) || (h > 1.0 && fl.w > 0.5)))
	{
		// Around an inner corner the distance to the corner point is not a
		// roof face (round swirl, and a false seam next to the valley).
		return 100000000.0;
	}
	return ext ? abs(dot(v - e.xy, fl.xy)) : length(v - e.xy - ab * clamp(h, 0.0, 1.0));
}

// Ridge Caps: the face whose outline a ridge's tiles follow (a curved one if
// any, so that they run on unbroken around curves).
int cap_ref(int i, int j)
{
	bool ci = texelFetch(edges, ivec2(i, 3), 0).y > 0.5;
	bool cj = texelFetch(edges, ivec2(j, 3), 0).y > 0.5;
	if (ci != cj)
	{
		return ci ? i : j;
	}
	return i < j ? i : j;
}

// hip_face_d, but around a sharp inner corner the plane also runs on on the
// near side of the valley (virt: only there): finds the lines meeting at the
// top of a valley (cap_end cuts them where they really end). Not around the
// small inner corners of a curved outline (planes there come too close).
float cap_face_d(vec2 v, int i, out bool virt)
{
	vec4 e = texelFetch(edges, ivec2(i, 0), 0);
	vec4 fl = texelFetch(edges, ivec2(i, 1), 0);
	vec4 nb = texelFetch(edges, ivec2(i, 2), 0);
	vec2 ab = e.zw - e.xy;
	vec2 dn = normalize(ab);
	float h = dot(v - e.xy, ab) / max(dot(ab, ab), 0.000001);
	bool inner = dot(v - e.xy, fl.xy) <= 0.0;
	bool side_a = dot(v - e.xy, nb.xy + dn) > 0.0;
	bool side_b = dot(v - e.zw, dn + nb.zw) < 0.0;
	bool ext = (h >= 0.0 && h <= 1.0)
		|| (inner && h < 0.0 && fl.z > 0.5 && (dot(nb.xy, dn) <= 0.766 || side_a))
		|| (inner && h > 1.0 && fl.w > 0.5 && (dot(dn, nb.zw) <= 0.766 || side_b));
	virt = ext && ((h < 0.0 && !side_a) || (h > 1.0 && !side_b));
	if (!ext && ((h < 0.0 && fl.z > 0.5) || (h > 1.0 && fl.w > 0.5)))
	{
		return 100000000.0;
	}
	return ext ? abs(dot(v - e.xy, fl.xy)) : length(v - e.xy - ab * clamp(h, 0.0, 1.0));
}

// Ridge Caps: does face i's plane hold at q (not only a plane running on
// past a sharp inner corner, see cap_face_d)?
bool cap_holds(vec2 q, int i)
{
	vec4 e = texelFetch(edges, ivec2(i, 0), 0);
	vec4 fl = texelFetch(edges, ivec2(i, 1), 0);
	vec4 nb = texelFetch(edges, ivec2(i, 2), 0);
	vec2 ab = e.zw - e.xy;
	vec2 dn = normalize(ab);
	float h = dot(q - e.xy, ab) / max(dot(ab, ab), 0.000001);
	bool inner = dot(q - e.xy, fl.xy) <= 0.0;
	if (h < 0.0 && fl.z > 0.5 && dot(nb.xy, dn) <= 0.766 && !(inner && dot(q - e.xy, nb.xy + dn) > 0.0))
	{
		return false;
	}
	if (h > 1.0 && fl.w > 0.5 && dot(dn, nb.zw) <= 0.766 && !(inner && dot(q - e.zw, dn + nb.zw) < 0.0))
	{
		return false;
	}
	return true;
}

// Ridge Caps: is p on the line between faces a and b, with face c farther?
bool cap_runs(vec2 p, int a, int b, int c)
{
	float da = hip_face_d(p, a);
	return da < 10000000.0 && hip_face_d(p, b) < 10000000.0 && hip_face_d(p, c) > da;
}

// Ridge Caps: does the line between faces a and b end where face c comes in
// (the three planes meet at x)? dir: the way past that end. The caps meeting
// there end rounded and overlap (lowest r kept): a mitre where the face
// between them is narrow, a rounded corner around a valley's top.
bool cap_end(int a, int b, int c, out vec2 x, out vec2 dir)
{
	x = vec2(0.0);
	dir = vec2(0.0);
	if (c < 0)
	{
		return false;
	}
	vec4 ea = texelFetch(edges, ivec2(a, 0), 0);
	vec2 na = texelFetch(edges, ivec2(a, 1), 0).xy;
	vec4 eb = texelFetch(edges, ivec2(b, 0), 0);
	vec2 nb = texelFetch(edges, ivec2(b, 1), 0).xy;
	vec4 ec = texelFetch(edges, ivec2(c, 0), 0);
	vec2 nc = texelFetch(edges, ivec2(c, 1), 0).xy;
	vec2 r1 = na - nb;
	vec2 r2 = na - nc;
	float det = r1.x * r2.y - r1.y * r2.x;
	if (abs(det) < 0.000001)
	{
		return false;
	}
	float ha = dot(ea.xy, na);
	float c1 = ha - dot(eb.xy, nb);
	float c2 = ha - dot(ec.xy, nc);
	x = vec2(c1 * r2.y - c2 * r1.y, r1.x * c2 - r2.x * c1) / det;
	vec2 cd = normalize(vec2(-r1.y, r1.x));
	float pr = max(cap_base * max(cap_scale, cap_scale_hip) * 0.5, 1.0);
	bool s1 = cap_runs(x + cd * pr, a, b, c);
	bool s2 = cap_runs(x - cd * pr, a, b, c);
	if (s1 == s2)
	{
		return false;
	}
	dir = s1 ? -cd : cd;
	return true;
}

// Ridge Caps on Hip roofs: the cap on the line where faces i and j meet
// (none on valleys). end_on: it ends at end_p, rounded, toward end_dir.
// r: 0 on the line, 1 on the cap's sides; where caps meet, the one with the
// lowest r is kept (mitred joints).
vec4 crease_cap(vec2 v, int i, int j, bool end_on, vec2 end_p, vec2 end_dir, vec4 tint, vec2 size, float cpx, inout float shadow, out float r, out float tip)
{
	r = 100.0;
	tip = 0.0;
	if (i < 0 || j < 0 || i == j)
	{
		return vec4(0.0);
	}
	vec4 ei = texelFetch(edges, ivec2(i, 0), 0);
	vec4 fi = texelFetch(edges, ivec2(i, 1), 0);
	vec4 ej = texelFetch(edges, ivec2(j, 0), 0);
	vec4 fj = texelFetch(edges, ivec2(j, 1), 0);
	if ((j == (i + 1) % edge_count && fi.w > 0.5) || (i == (j + 1) % edge_count && fj.w > 0.5))
	{
		return vec4(0.0);
	}
	vec2 g = fi.xy - fj.xy;
	float l2 = dot(g, g);
	if (l2 < 0.000001)
	{
		return vec4(0.0);
	}
	float cosn = dot(fi.xy, fj.xy);
	float hw = cap_hw(cosn < -0.7, cosn);
	float dd = dot(ej.xy - v, fj.xy) - dot(ei.xy - v, fi.xy);
	float s = dd / sqrt(l2);
	if (abs(s) > hw * 1.7)
	{
		return vec4(0.0);
	}
	// Point of the line, and one orientation whichever face looks at it.
	vec2 q = v - dd * g / l2;
	if (!end_on && (!cap_holds(q, i) || !cap_holds(q, j)))
	{
		// Not a line of this roof there (a plane running on past an inner
		// corner, see cap_face_d).
		return vec4(0.0);
	}
	float o = i < j ? 1.0 : -1.0;
	vec2 across = normalize(g) * o;
	float a;
	if (cosn < -0.7)
	{
		// Ridge: measured along the outline of one face (curved outlines
		// included, see _cap_runs), so the tiles run on unbroken.
		int rf = cap_ref(i, j);
		vec4 er = rf == i ? ei : ej;
		vec2 nr = rf == i ? fi.xy : fj.xy;
		vec4 sr = texelFetch(edges, ivec2(rf, 3), 0);
		a = sr.z + dot(q - er.xy, normalize(er.zw - er.xy)) - dot(er.xy - q, nr) * sr.w;
	}
	else
	{
		// Hip: laid from the eave corner up (its height over how fast it
		// rises), so two hips meeting at the top match.
		a = dot(ei.xy - q, fi.xy) / max(abs(dot(vec2(-across.y, across.x), fi.xy)), 0.2);
	}
	float et = end_on ? dot(q - end_p, end_dir) / hw : 0.0;
	vec2 e_dir = end_dir;
	// Hip reaching an outer corner of the outline: ends there, rounded or
	// cut square, its end tip_len past the corner (the part outside the
	// shape is drawn by a child shape, see tip_mode).
	bool c_i = j == (i + 1) % edge_count;
	bool c_j = i == (j + 1) % edge_count;
	float sq_d = 100000.0;
	if (c_i || c_j)
	{
		vec2 cn = c_i ? ei.zw : ej.zw;
		vec2 d_out = fi.xy + fj.xy;
		if (dot(d_out, d_out) > 0.000001)
		{
			d_out = normalize(d_out);
			float hv = cap_vhw(cosn < -0.7, hw);
			if (cap_corner == 1)
			{
				// Centre of the round: its tip tip_len past the corner.
				float et_c = dot(q - (cn + d_out * (tip_len - 1.0) * hv), d_out) / hw;
				tip = smoothstep(-3.0, -2.0, et_c);
				if (et_c > max(et, 0.0))
				{
					et = et_c;
					e_dir = d_out;
				}
			}
			else
			{
				// Square end: cut like the outline's corner (a point) or flat,
				// tip_len past it. sq_d: distance to that cut (> 0 inside).
				vec2 cs = cn + d_out * tip_len * hv;
				if (cap_corner == 2)
				{
					// Flat: cut across the line.
					sq_d = dot(cs - q, d_out);
				}
				else
				{
					sq_d = min(dot(cs - v, fi.xy), dot(cs - v, fj.xy));
				}
				tip = smoothstep(-3.0, -2.0, dot(q - cs, d_out) / hw);
				if (sq_d < -cpx)
				{
					return vec4(0.0);
				}
			}
		}
	}
	float sx = o * s / hw;
	r = length(vec2(sx, max(et, 0.0)));
	vec4 ck = cap_piece(a, sx, et, across, e_dir, hw, tint, size, cpx, shadow, cosn < -0.7);
	float own_ink = cap_style == 3 ? (cosn < -0.7 ? cap_ridge_ink : cap_hip_ink) : 0.0;
	if (tip > 0.0 && cap_outline != 1 && own_ink <= 0.0)
	{
		// Ink line all around the tip (no roof around it there).
		float t_ink = max(ink_h * 0.04, cpx * 1.5);
		ck.rgb *= mix(1.0, 0.12, (1.0 - smoothstep(t_ink * 0.5, t_ink, (1.0 - r) * hw)) * tip);
	}
	if (sq_d < 100000.0)
	{
		// Square end: cut, with an ink line (as thick as the strip's own).
		float q_ink = own_ink > 0.0 ? max(own_ink * 2.0 * hw, cpx * 1.2) : max(ink_h * 0.04, cpx * 1.5);
		ck.rgb *= mix(1.0, 0.12, 1.0 - smoothstep(q_ink - cpx, q_ink, sq_d));
		ck.a *= clamp(sq_d / cpx + 0.5, 0.0, 1.0);
	}
	if (cap_ridge_top && cosn < -0.7)
	{
		// Ridge on top of the hips (kept first, see cap_keep).
		r -= 2.0;
	}
	return ck;
}

// Ridge Caps: is the line between faces a and b (b at distance db) only the
// meeting of two faces of a curved outline? Then the faces between them,
// turning from a toward b, are nearer: no such line (cone of a round end or
// of a rounded corner).
bool cap_bridged(vec2 v, int a, int b, float db)
{
	vec2 na = texelFetch(edges, ivec2(a, 1), 0).xy;
	vec2 nb = texelFetch(edges, ivec2(b, 1), 0).xy;
	if (dot(na, nb) < -0.94)
	{
		return false;
	}
	int fn = (a + 1) % edge_count;
	int fp = (a - 1 + edge_count) % edge_count;
	int st = dot(texelFetch(edges, ivec2(fn, 1), 0).xy, nb) >= dot(texelFetch(edges, ivec2(fp, 1), 0).xy, nb) ? 1 : -1;
	int f = a;
	vec2 nf = na;
	bool found = false;
	bool done = false;
	for (int k = 0; k < 3; k++)
	{
		if (!done)
		{
			int f2 = (f + st + edge_count) % edge_count;
			vec2 n2 = texelFetch(edges, ivec2(f2, 1), 0).xy;
			if (f2 == b || dot(n2, nf) <= 0.766)
			{
				done = true;
			}
			else if (dot(n2, nb) > 0.766 && hip_face_d(v, f2) < db)
			{
				found = true;
				done = true;
			}
			f = f2;
			nf = n2;
		}
	}
	return found;
}

// Ridge Caps: face i in the range of faces f0..f1 (around the outline)?
bool cap_in(int i, int f0, int f1)
{
	return f0 <= f1 ? (i >= f0 && i <= f1) : (i >= f0 || i <= f1);
}

// Ridge Caps: near the centre of a curved part of the outline (see
// _cap_ends), the line ending there is drawn from that list (rounded end),
// and lines between the curved part's own faces are no lines.
bool cap_skip(vec2 v, int a, int b, float reach)
{
	vec2 na = texelFetch(edges, ivec2(a, 1), 0).xy;
	vec2 nb = texelFetch(edges, ivec2(b, 1), 0).xy;
	bool hit = false;
	for (int k = 0; k < cap_ends; k++)
	{
		vec4 rec = texelFetch(edges, ivec2(k, 4), 0);
		if (length(v - rec.zw) < reach)
		{
			vec4 rg = texelFetch(edges, ivec2(k, 5), 0);
			int f0 = int(rg.z + 0.5);
			int f1 = int(rg.w + 0.5);
			vec2 nx = texelFetch(edges, ivec2(int(rec.x + 0.5), 1), 0).xy;
			vec2 ny = texelFetch(edges, ivec2(int(rec.y + 0.5), 1), 0).xy;
			if ((dot(na, nx) > 0.766 && dot(nb, ny) > 0.766) || (dot(na, ny) > 0.766 && dot(nb, nx) > 0.766)
				|| cap_in(a, f0, f1) || cap_in(b, f0, f1))
			{
				hit = true;
			}
		}
	}
	return hit;
}

// Ridge Caps: keeps the two caps with the lowest r (blended over one pixel
// where they meet).
void cap_keep(vec4 c, float r, inout vec4 c1, inout float r1, inout vec4 c2, inout float r2)
{
	if (c.a > 0.0)
	{
		if (r < r1)
		{
			c2 = c1;
			r2 = r1;
			c1 = c;
			r1 = r;
		}
		else if (r < r2)
		{
			c2 = c;
			r2 = r;
		}
	}
}

// tip_mode: the caps' tips past the outline's corners, outside the shape.
vec4 cap_tip_mode(vec2 v, vec4 tint, float cpx)
{
	vec2 size = vec2(textureSize(albedo, 0));
	vec4 c_1 = vec4(0.0);
	vec4 c_2 = vec4(0.0);
	float r_1 = 100.0;
	float r_2 = 100.0;
	float reach = max(cap_hw(true, -1.0), cap_hw(false, 0.0)) * 3.0;
	for (int c = 0; c < edge_count; c++)
	{
		vec4 e = texelFetch(edges, ivec2(c, 0), 0);
		if (length(v - e.zw) < reach)
		{
			int j = (c + 1) % edge_count;
			vec2 fc = texelFetch(edges, ivec2(c, 1), 0).xy;
			vec2 fj = texelFetch(edges, ivec2(j, 1), 0).xy;
			// Outside the shape there (the corner's two sides).
			// (a little inside too: no gap along the outline)
			if (dot(v - e.zw, fc) > -cpx * 1.5 || dot(v - e.zw, fj) > -cpx * 1.5)
			{
				float sh = 0.0;
				float rk;
				float tk;
				vec4 ck = crease_cap(v, c, j, true, e.zw, vec2(0.0), tint, size, cpx, sh, rk, tk);
				cap_keep(ck, rk, c_1, r_1, c_2, r_2);
			}
		}
	}
	float a = c_1.a + c_2.a * (1.0 - c_1.a);
	vec3 col = (c_1.rgb * c_1.a + c_2.rgb * c_2.a * (1.0 - c_1.a)) / max(a, 0.0001);
	return vec4(col, a);
}

// Local position of a point given in the texture's rotated frame (braw).
vec2 cap_local(vec2 b, vec2 size)
{
	vec2 w = b / size - 0.5;
	float c = cos(rotation);
	float s = sin(rotation);
	return size * (vec2(c * w.x - s * w.y, s * w.x + c * w.y) + 0.5);
}

void vertex()
{
	v_local = VERTEX;
}

void fragment()
{
	if (skirt_mode)
	{
		COLOR = skirt_shadow(v_local);
	}
	else if (bake_mode)
	{
		COLOR = vec4(vec3(bake_coverage(v_local)), 1.0);
	}
	else if (tip_mode)
	{
		float tpx = max(max(length(dFdx(v_local)), length(dFdy(v_local))), 0.0001);
		COLOR = cap_tip_mode(v_local, COLOR, tpx);
	}
	else
	{
	vec2 size = vec2(textureSize(albedo, 0));
	float ux = 0.0;
	float t = 0.0;
	float lod = 0.0;
	vec2 face_n = vec2(0.0, -1.0);
	// Second face near a seam (ridge / hip line), blended when seam_soft > 0.
	float ux2 = 0.0;
	float t2 = 0.0;
	float w2 = 0.0;
	vec2 face_n2 = face_n;
	vec2 dx = dFdx(v_local);
	vec2 dy = dFdy(v_local);
	// Height of this roof at the pixel (distance from the eave), for merging.
	float h_own = 0.0;
	// Hard seams (Softer Seams off): how far the pixel is from the ridge /
	// hip line, as a height difference between the two faces.
	float seam_d = 100000000.0;
	// Change of seam_d per local unit, known exactly (screen derivatives
	// break on the seam itself, where seam_d has a kink).
	float seam_g = 1.0;
	// Hip roofs: the face this pixel is on, and its distance (Ridge Caps).
	int cap_f0 = -1;
	float cap_d0 = 0.0;
	// Round Ends (Gap Free, Two Slopes): pixel in a round end, its coverage
	// (anti-aliased rim) and distance to the rim (texels).
	bool in_round = false;
	float round_keep = 1.0;
	float round_rim = 0.0;
	if (roof_mode == 2)
	{
		vec2 p = v_local - center;
		float r = length(p);
		vec2 rd = r > 0.0001 ? p / r : vec2(0.0, -1.0);
		vec2 tg = vec2(-rd.y, rd.x);
		float nf = float(lut_n);
		float f = (atan(p.y, p.x) + 3.14159265) / 6.28318531 * nf - 0.5;
		float fl = floor(f);
		float fr = f - fl;
		int i0 = int(mod(fl, nf));
		int i1 = int(mod(fl + 1.0, nf));
		vec4 a0 = texelFetch(lut, ivec2(i0, 0), 0);
		vec4 a1 = texelFetch(lut, ivec2(i1, 0), 0);
		float rr = max(mix(a0.x, a1.x, fr), 0.001);
		float p1 = a1.z;
		if (p1 < a0.z - 0.5) { p1 += 1.0; }
		else if (p1 > a0.z + 0.5) { p1 -= 1.0; }
		float per = fract(mix(a0.z, p1, fr));
		if (abs(a0.x - a1.x) > 0.08 * max(a0.x, a1.x))
		{
			// The outline jumps between two samples (a corner seen edge-on
			// from the top point): no blending across the jump, it is a crease.
			vec4 an = fr < 0.5 ? a0 : a1;
			rr = max(an.x, 0.001);
			per = fract(an.z);
		}
		float d = rr;
		face_n = rd;
		if (!smooth_shape)
		{
			d = mix(a0.y, a1.y, fr);
			vec4 b0 = texelFetch(lut, ivec2(i0, 1), 0);
			vec4 b1 = texelFetch(lut, ivec2(i1, 1), 0);
			vec2 nn = mix(b0.xy, b1.xy, fr);
			face_n = length(nn) > 0.0001 ? normalize(nn) : rd;
		}
		float s = clamp(r / rr, 0.0, 1.0);
		// Rows follow the outline shrunk toward the top (level courses of a
		// cone): same number of rows in every direction, closer together on
		// the steep side when the top point is moved.
		float d_ref = max(ref_d, 0.001);
		t = (1.0 - s) * d_ref * pitch_scale;
		// The eave (cut-outs, shadow under the tiles) keeps its real width
		// all around: on the side the top was moved toward, the homothetic
		// rows would squeeze it into a dark line, on the far side stretch it.
		float eb = eave_band * pitch_scale;
		float dd = max(rr - r, 0.0) * pitch_scale;
		float rrp = rr * pitch_scale;
		float full = d_ref * pitch_scale;
		if (eb > 0.0 && rrp > eb * 2.0 && full > eb * 2.0)
		{
			t = dd <= eb ? dd : eb + (dd - eb) * (full - eb) / (rrp - eb);
		}
		if (profile_on && full > 0.0)
		{
			// Curved slope: rows closer together where it is steep (domes:
			// near the eave), farther apart where it is flat. The eave band
			// keeps its width.
			float e0 = (eb > 0.0 && full > eb * 2.0) ? eb : 0.0;
			if (t > e0)
			{
				float uc = clamp((t - e0) / (full - e0), 0.0, 1.0);
				vec4 pf = texture(profile_lut, vec2(uc, 0.5));
				t = e0 + (full * profile_len - e0) * pf.r;
				face_n *= pf.g;
			}
			else
			{
				// Eave band: same slope as the rim, so the shading reaches
				// the tile tips.
				face_n *= texture(profile_lut, vec2(0.0, 0.5)).g;
			}
		}
		// columns = texture repeats around the eave (outline / texture width).
		// Counts are made in single tiles (tile_n tiles across the texture).
		float ntile = tile_n > 0.0 ? tile_n : max(size.x / row_h, 1.0);
		float tiles_eave = columns * ntile;
		float cols = columns;
		float cpos = per;
		float course_shift = 0.0;
		if (taper)
		{
			// One tile count per course of tiles, like a real conical roof:
			// the tiles keep about the same width up to the top, the count
			// only changes on the row edges.
			float t0 = mod(size.y - edge_shift - row_y0, row_h);
			float kf = max(floor((t - t0) / row_h), 0.0);
			cols = course_tiles(kf, t0, d_ref, tiles_eave) / ntile;
			// Each course starts at a random point (pseudo-random per course:
			// regular steps draw spirals), so the courses never line up.
			course_shift = course_rand(kf) / ntile;
			if (seam_soft > 0.0)
			{
				// Soft course edges: blend with the neighbouring course.
				float d_lo = kf > 0.0 ? t - (t0 + kf * row_h) : 100000000.0;
				float d_hi = (t0 + (kf + 1.0) * row_h) - t;
				float kn = d_lo < d_hi ? kf - 1.0 : kf + 1.0;
				// Narrow: the edge sits on the joint between two courses, a
				// wide blend would ghost two different tile layouts.
				float course_soft = min(seam_soft, row_h * 0.12);
				float wc = 0.5 * clamp(1.0 - min(d_lo, d_hi) / course_soft, 0.0, 1.0);
				if (wc > 0.0)
				{
					ux2 = per * course_tiles(kn, t0, d_ref, tiles_eave) / ntile + course_rand(kn) / ntile;
					t2 = t;
					face_n2 = face_n;
					w2 = wc;
				}
			}
		}
		else if (tile_n > 0.0)
		{
			// A whole number of tiles loops without a seam.
			cols = max(floor(tiles_eave + 0.5), 1.0) / ntile;
		}
		ux = cpos * cols + course_shift;
		// No single tile found (thatch...): where the outline loops (cpos = 0)
		// a non-whole number of repeats leaves a seam, blend it with the
		// other side.
		if (seam_soft > 0.0 && tile_n <= 0.0)
		{
			float arc = min(cpos, 1.0 - cpos) * perimeter * s;
			float wl = 0.5 * clamp(1.0 - arc / seam_soft, 0.0, 1.0);
			if (wl > w2)
			{
				ux2 = (cpos < 0.5 ? cpos + 1.0 : cpos - 1.0) * cols + course_shift;
				t2 = t;
				face_n2 = face_n;
				w2 = wl;
			}
		}
		// Top point moved onto (or next to) an outline edge: that edge is
		// not an eave (like a wall against the roof), keep it straight. Right
		// next to it, eave rows (with their cut-outs) are replaced by the
		// same tiles a whole number of rows higher in the texture: the rows
		// keep their place and shape, only the cut-outs go away.
		float wall_min = 0.0;
		bool near_wall = false;
		if (apex_moved && edge_count > 0)
		{
			// Height of the eave cut-outs (texture rows below the opaque body).
			wall_min = max(size.y - edge_shift - body_end, 0.0) + 1.0;
			float zone = max(wall_min, row_h) / pitch_scale + 2.0;
			float d_wall = 100000000.0;
			float d_rim = 100000000.0;
			for (int i = 0; i < edge_count; i++)
			{
				float ad = texelFetch(edges, ivec2(i, 3), 0).x;
				vec4 e = texelFetch(edges, ivec2(i, 0), 0);
				vec2 ab = e.zw - e.xy;
				float h = clamp(dot(v_local - e.xy, ab) / max(dot(ab, ab), 0.000001), 0.0, 1.0);
				float de = length(v_local - e.xy - ab * h);
				if (ad > d_ref * 0.15)
				{
					d_rim = min(d_rim, de);
				}
				else
				{
					d_wall = min(d_wall, de);
				}
			}
			// The eave band of the real eaves (the curved outline...) keeps
			// its cut-outs: that is the roof's silhouette, down to the wall.
			float rim_band = wall_min / pitch_scale * 1.2 + 2.0;
			near_wall = d_wall < zone && d_rim > rim_band;
		}
		if (!smooth_shape && seam_soft > 0.0 && edge_count > 0)
		{
			// Pyramid faces = lower envelope of the edge planes: the face of
			// p is the edge with the smallest (distance / apex distance).
			float q1 = 100000000.0;
			float q2 = 100000000.0;
			int j1 = 0;
			int j2 = 0;
			for (int i = 0; i < edge_count; i++)
			{
				vec4 e = texelFetch(edges, ivec2(i, 0), 0);
				vec4 en = texelFetch(edges, ivec2(i, 1), 0);
				float ad = texelFetch(edges, ivec2(i, 3), 0).x;
				float q = dot(e.xy - v_local, en.xy) / max(ad, 0.001);
				if (q < q1) { q2 = q1; j2 = j1; q1 = q; j1 = i; }
				else if (q < q2) { q2 = q; j2 = i; }
			}
			float ad1 = texelFetch(edges, ivec2(j1, 3), 0).x;
			float wf = 0.5 * clamp(1.0 - (q2 - q1) * ad1 / seam_soft, 0.0, 1.0);
			t = max(q1, 0.0) * d_ref * pitch_scale;
			face_n = texelFetch(edges, ivec2(j1, 1), 0).xy;
			// Only one second sample: the facet seam wins over the loop seam
			// when it is the stronger blend.
			if (wf >= w2)
			{
				t2 = max(q2, 0.0) * d_ref * pitch_scale;
				ux2 = ux;
				face_n2 = texelFetch(edges, ivec2(j2, 1), 0).xy;
				w2 = wf;
			}
			else
			{
				t2 = t;
				face_n2 = face_n;
			}
		}
		h_own = t;
		if (near_wall)
		{
			float rh = max(row_h, 1.0);
			t += ceil(max(wall_min - t, 0.0) / rh) * rh;
			t2 += ceil(max(wall_min - t2, 0.0) / rh) * rh;
		}
		float ku = cols * size.x / (6.28318531 * max(r, 0.5));
		float kv = d_ref / rr * pitch_scale;
		vec2 gx = vec2(dot(dx, tg) * ku, dot(dx, rd) * kv);
		vec2 gy = vec2(dot(dy, tg) * ku, dot(dy, rd) * kv);
		lod = 0.5 * log2(max(max(dot(gx, gx), dot(gy, gy)), 0.00000001));
	}
	else if (roof_mode == 3)
	{
		float best = 100000000.0;
		float best2 = 100000000.0;
		int bi = 0;
		int bi2 = 0;
		for (int i = 0; i < edge_count; i++)
		{
			// Past an inner (reflex) corner the edge plane keeps going, on the
			// far side of the valley (corner bisector) only: there it is the
			// higher of the two planes (see hip_face_d).
			float dd = hip_face_d(v_local, i);
			if (dd < best)
			{
				best2 = best;
				bi2 = bi;
				best = dd;
				bi = i;
			}
			else if (dd < best2)
			{
				best2 = dd;
				bi2 = i;
			}
		}
		cap_f0 = bi;
		cap_d0 = best;
		seam_d = best2 - best;
		seam_g = length(texelFetch(edges, ivec2(bi, 1), 0).xy - texelFetch(edges, ivec2(bi2, 1), 0).xy);
		vec4 e0 = texelFetch(edges, ivec2(bi, 0), 0);
		vec2 outn = texelFetch(edges, ivec2(bi, 1), 0).xy;
		vec2 xa = vec2(outn.y, -outn.x);
		face_n = outn;
		t = best * pitch_scale;
		h_own = t;
		ux = dot(v_local - e0.xy, xa) / (size.x * tex_scale);
		if (seam_soft > 0.0)
		{
			vec4 e2 = texelFetch(edges, ivec2(bi2, 0), 0);
			vec2 outn2 = texelFetch(edges, ivec2(bi2, 1), 0).xy;
			vec2 xa2 = vec2(outn2.y, -outn2.x);
			face_n2 = outn2;
			t2 = best2 * pitch_scale;
			ux2 = dot(v_local - e2.xy, xa2) / (size.x * tex_scale);
			// Each face keeps its own tiles (the hip line is a real cut), so
			// the blend stays very thin: it only smooths the cut.
			float hip_soft = max(1.5, seam_soft * 0.15);
			w2 = 0.5 * clamp(1.0 - (best2 - best) / hip_soft, 0.0, 1.0);
		}
		vec2 gx = vec2(dot(dx, xa) / tex_scale, dot(dx, outn) * pitch_scale);
		vec2 gy = vec2(dot(dy, xa) / tex_scale, dot(dy, outn) * pitch_scale);
		lod = 0.5 * log2(max(max(dot(gx, gx), dot(gy, gy)), 0.00000001));
	}
	else
	{
		vec2 base = rotate_uv(v_local / size, rotation);
		base.x /= tex_scale;
		base.x += u_offset;
		vec2 bp = base * size;
		vec2 gx = dFdx(bp) * vec2(1.0, pitch_scale);
		vec2 gy = dFdy(bp) * vec2(1.0, pitch_scale);
		lod = 0.5 * log2(max(max(dot(gx, gx), dot(gy, gy)), 0.00000001));
		t = (v_max - base.y) * size.y * pitch_scale;
		ux = base.x;
		face_n = normalize(vec2(-sin(rotation) / size.x, cos(rotation) / size.y));
		if (mirror)
		{
			// Far slope = near slope turned 180° (+ ridge offset).
			float tf = (base.y - v_min) * size.y * pitch_scale;
			float uf = ridge_offset - base.x;
			vec2 nf2 = -face_n;
			if (tf < t)
			{
				float tt = t; t = tf; tf = tt;
				float uu = ux; ux = uf; uf = uu;
				vec2 nn2 = face_n; face_n = nf2; nf2 = nn2;
			}
			seam_d = tf - t;
			seam_g = 2.0 * size.y * pitch_scale * length(vec2(-sin(rotation) / size.x, cos(rotation) / size.y));
			if (seam_soft > 0.0)
			{
				t2 = tf;
				ux2 = uf;
				face_n2 = nf2;
				w2 = 0.5 * clamp(1.0 - (tf - t) / seam_soft, 0.0, 1.0);
			}
			if (round_start || round_end)
			{
				// Round Ends: half a cone around each end of the ridge, rows
				// following the rim; its tiles meet those of both slopes and
				// the two halves meet on the line of the ridge.
				vec2 braw = rotate_uv(v_local / size, rotation) * size;
				float yc = (v_max + v_min) * 0.5 * size.y;
				float rr = (v_max - v_min) * 0.5 * size.y;
				float side = 0.0;
				float xc = 0.0;
				if (round_start && braw.x < round_x0)
				{
					side = -1.0;
					xc = round_x0;
				}
				else if (round_end && braw.x > round_x1)
				{
					side = 1.0;
					xc = round_x1;
				}
				if (side != 0.0)
				{
					in_round = true;
					vec2 q = vec2(braw.x - xc, braw.y - yc);
					float ra = max(round_a, 0.001);
					float rho = length(vec2(q.x / ra, q.y / rr));
					float rmin = min(ra, rr);
					float px_t = max(max(length(dx), length(dy)), 0.0001);
					round_keep = clamp((1.0 - rho) * rmin / px_t + 0.5, 0.0, 1.0);
					round_rim = (1.0 - rho) * rmin;
					t = max(1.0 - rho, 0.0) * rr * pitch_scale;
					// Courses of tiles: one ring each (same shape as the rim),
					// so the tile edges stay square to the rim.
					float rh = max(row_h, 1.0);
					float t0 = mod(size.y - edge_shift - row_y0, rh);
					float kf = max(floor((t - t0) / rh), 0.0);
					float t_mid = kf < 0.5 ? (t0 + rh) * 0.5 : t0 + (kf + 0.5) * rh;
					float rho_k = max(1.0 - t_mid / (rr * pitch_scale), 0.25 * rh / rr);
					float wtex = size.x * tex_scale;
					// Angle on the ellipse: 0 at the near slope, pi at the far one.
					float phi = atan(side * q.x / ra, q.y / rr);
					float s_near = rho_k * round_arc(phi, ra, rr);
					float s_far = rho_k * round_arc(3.14159265 - phi, ra, rr);
					float u_j = xc / wtex + u_offset;
					float u_near = u_j + side * s_near / wtex;
					float u_far = ridge_offset - u_j - side * s_far / wtex;
					vec2 ax = normalize(vec2(cos(rotation) / size.x, sin(rotation) / size.y));
					vec2 ay = normalize(vec2(-sin(rotation) / size.x, cos(rotation) / size.y));
					vec2 en = vec2(q.x / (ra * ra), q.y / (rr * rr));
					face_n = length(en) > 0.0000001 ? normalize(en.x * ax + en.y * ay) : ay;
					face_n2 = face_n;
					ux = phi < 1.5707963 ? u_near : u_far;
					t2 = t;
					w2 = 0.0;
					seam_d = 100000000.0;
					if (seam_soft > 0.0)
					{
						ux2 = phi < 1.5707963 ? u_far : u_near;
						w2 = 0.5 * clamp(1.0 - abs(phi - 1.5707963) * rho_k * rr / seam_soft, 0.0, 1.0);
					}
				}
			}
		}
		h_own = t;
	}
	vec4 original = roof_sample(ux, t, lod, size);
	if (w2 > 0.0)
	{
		// The second face only tints where both faces are opaque: the
		// silhouette (eave cut-outs, corners) stays the first face's, so
		// the blend never spills past the corners.
		vec4 other = roof_sample(ux2, t2, lod, size);
		float wb = w2 * other.a;
		original.rgb = mix(original.rgb, other.rgb, wb);
		w2 = wb;
	}
	vec3 texel = original.rgb * COLOR.rgb;
	float alpha = COLOR.a * original.a;
	if (ct_on)
	{
		// Colour and Modify Things: its colour steps replace the pattern
		// colour (COLOR); its tint and opacity come with the modulate.
		vec4 cc = original;
		if (ct_has_edge_blur)
		{
			cc = ct_edge_blur(cc, v_local);
		}
		cc = ct_colour(cc);
		texel = cc.rgb;
		alpha = cc.a;
	}
	else if (custom_color)
	{
		texel = original.rgb;
		float redness = original.r - (original.g + original.b) * 0.5;
		if (redness > 0.0)
		{
			float intensity = smoothstep(0.0, 0.5, redness);
			texel = mix(original.rgb, COLOR.rgb * original.r, intensity);
		}
	}
	if (use_wear)
	{
		vec2 wear_size = vec2(textureSize(wear, 0)) * 2.0;
		texel *= texture(wear, v_local / wear_size).rgb;
	}
	if (shade > 0.0 && (roof_mode != 1 || mirror))
	{
		// Light of each face, blended across soft seams (the normals of two
		// slopes can be opposite, so the light values are mixed, not them).
		float l1 = shade_light(face_n);
		float l2 = shade_light(face_n2);
		texel *= mix(l1, l2, w2);
	}
	// Ink lines only on the opaque roof: drawn over the half-transparent
	// shadow rows under the eave they would show as dark streaks.
	float ink_a = smoothstep(0.6, 0.95, original.a);
	// Side Lines: ink line on every side of the shape where the texture
	// shows a plain cut (no cut-out edge of its own), whatever the drawn
	// shape (straight, curved, diagonal): eaves when the texture has no
	// cut-out bottom edge, and always the sides that are not an eave (Gap
	// Free gable ends, Centered walls the top was moved onto, thicker as
	// the top gets closer).
	if (edge_count > 0 && side_ink && !in_round)
	{
		vec2 odx = dFdx(v_local);
		vec2 ody = dFdy(v_local);
		float opx = max(max(length(odx), length(ody)), 0.000001);
		float o_ink = max(ink_h * 0.04, opx * 1.5);
		vec2 eave_n = normalize(vec2(-sin(rotation) / size.x, cos(rotation) / size.y));
		float dark = 0.0;
		for (int i = 0; i < edge_count; i++)
		{
			float wgt = eave_cut ? 0.0 : 1.0;
			if (roof_mode == 1)
			{
				float c = dot(texelFetch(edges, ivec2(i, 1), 0).xy, eave_n);
				if (!(c > 0.7 || (mirror && c < -0.7)))
				{
					wgt = 1.0;
				}
				if (mirror && (round_start || round_end))
				{
					// The ends a Round End is added to are not cut.
					vec4 er = texelFetch(edges, ivec2(i, 0), 0);
					float xa = rotate_uv(er.xy / size, rotation).x * size.x;
					float xb = rotate_uv(er.zw / size, rotation).x * size.x;
					if ((round_start && max(xa, xb) <= round_x0 + 1.0) || (round_end && min(xa, xb) >= round_x1 - 1.0))
					{
						wgt = 0.0;
					}
				}
			}
			else if (roof_mode == 2 && apex_moved)
			{
				float ad = texelFetch(edges, ivec2(i, 3), 0).x;
				wgt = max(wgt, clamp(1.0 - ad / max(ref_d * 0.3, 0.001), 0.0, 1.0) * 0.8);
			}
			if (wgt <= 0.0)
			{
				continue;
			}
			vec4 e = texelFetch(edges, ivec2(i, 0), 0);
			vec2 ab = e.zw - e.xy;
			float h = clamp(dot(v_local - e.xy, ab) / max(dot(ab, ab), 0.000001), 0.0, 1.0);
			float de = length(v_local - e.xy - ab * h);
			float w = o_ink * wgt;
			dark = max(dark, 1.0 - smoothstep(w * 0.5, w, de));
		}
		texel *= mix(1.0, 0.12, dark * ink_a);
	}
	// Ink line + crease shadow along hard seams, like the merge cut.
	vec2 sdx = dFdx(v_local);
	vec2 sdy = dFdy(v_local);
	float spx = max(max(length(sdx), length(sdy)), 0.000001);
	if (seam_lines && !ridge_caps && seam_soft <= 0.0 && seam_d < 10000000.0 && (roof_mode == 3 || (roof_mode == 1 && mirror)))
	{
		float ds = seam_d / max(seam_g, 0.0001);
		float srh = ink_h;
		float s_ink = max(srh * 0.03, spx);
		float s_shadow = srh * 0.6;
		if (ds < s_shadow && shade > 0.0)
		{
			// Darker on the face turned away from the light, scaled by the
			// Shading strength.
			float away = 0.5 - 0.5 * dot(face_n, light_dir);
			float amount = min(shade * 2.0, 1.0) * (0.2 + 0.8 * away) * 0.75;
			float f = 1.0 - ds / s_shadow;
			texel *= 1.0 - amount * f * f;
		}
		if (ds < s_ink)
		{
			// Full ink over the eave's cut-outs too (where ink_a fades it).
			float s_cov = (1.0 - smoothstep(s_ink * 0.5, s_ink, ds)) * max(ink_a, 1.0 - alpha);
			texel *= mix(1.0, 0.12, s_cov);
			// Also over the cut-outs of the eave (non seamless textures): the
			// line runs on to the real corner of the shape and covers the
			// notch the two eaves leave there.
			if (alpha < 1.0 && s_cov > 0.0)
			{
				float na = alpha + s_cov * (1.0 - alpha);
				texel = (texel * alpha + vec3(0.03) * s_cov * (1.0 - alpha)) / max(na, 0.0001);
				alpha = na;
			}
		}
	}
	if (in_round && side_ink && !eave_cut)
	{
		// Plain eave all around the round end: ink line on the rim.
		float rpx = max(max(length(dx), length(dy)), 0.000001);
		float r_ink = max(ink_h * 0.04, rpx * 1.5);
		texel *= mix(1.0, 0.12, (1.0 - smoothstep(r_ink * 0.5, r_ink, round_rim)) * ink_a);
	}
	if (ridge_caps)
	{
		float cpx = max(max(length(dx), length(dy)), 0.0001);
		float cap_sh = 0.0;
		float tip_k = 0.0;
		// The two caps with the lowest r (see crease_cap).
		vec4 cap_1 = vec4(0.0);
		vec4 cap_2 = vec4(0.0);
		float r_1 = 100.0;
		float r_2 = 100.0;
		float hw_max = max(cap_hw(true, -1.0), cap_hw(false, 0.0));
		if (roof_mode == 3)
		{
			// The lines bounding this pixel's face: with the nearest face
			// turned away from it (b1) and the nearest turned away from both
			// (b2). Faces turned by less than ~40° are one curved surface.
			int fa = cap_f0;
			vec2 na = texelFetch(edges, ivec2(fa, 1), 0).xy;
			int b1 = -1;
			int b2 = -1;
			int b3 = -1;
			float d1 = 100000000.0;
			float d2 = 100000000.0;
			float d3 = 100000000.0;
			vec2 n1 = vec2(0.0);
			for (int e = 0; e < edge_count; e++)
			{
				vec2 ne = texelFetch(edges, ivec2(e, 1), 0).xy;
				bool virt = false;
				float de = 100000000.0;
				if (e != fa && dot(ne, na) <= 0.766)
				{
					de = cap_face_d(v_local, e, virt);
				}
				if (virt)
				{
					// Plane running on past a sharp inner corner: a third
					// candidate (its line, if any, ends at the valley's top).
					if (de < d3)
					{
						b3 = e;
						d3 = de;
					}
				}
				else if (de < 10000000.0)
				{
					if (de < d1)
					{
						if (b1 >= 0 && dot(n1, ne) <= 0.766)
						{
							b2 = b1;
							d2 = d1;
						}
						else if (b2 >= 0 && dot(texelFetch(edges, ivec2(b2, 1), 0).xy, ne) > 0.766)
						{
							b2 = -1;
							d2 = 100000000.0;
						}
						b1 = e;
						d1 = de;
						n1 = ne;
					}
					else if (de < d2 && dot(n1, ne) <= 0.766)
					{
						b2 = e;
						d2 = de;
					}
				}
			}
			float reach = hw_max * 1.8;
			// Lines ending at the centre of a curved part: rounded end there.
			for (int k = 0; k < cap_ends; k++)
			{
				vec4 rec = texelFetch(edges, ivec2(k, 4), 0);
				if (length(v_local - rec.zw) < reach)
				{
					float rk;
					float tk;
					vec4 ck = crease_cap(v_local, int(rec.x + 0.5), int(rec.y + 0.5), true, rec.zw, -texelFetch(edges, ivec2(k, 5), 0).xy, COLOR, size, cpx, cap_sh, rk, tk);
					tip_k = max(tip_k, tk * ck.a);
					cap_keep(ck, rk, cap_1, r_1, cap_2, r_2);
				}
			}
			if (cap_ridge_top && b1 >= 0 && b2 >= 0 && dot(n1, texelFetch(edges, ivec2(b2, 1), 0).xy) < -0.7)
			{
				// Ridge on top of the hips: its rounded end runs on over the
				// face where they meet (the hips' face).
				vec2 jx;
				vec2 jd;
				if (cap_end(b1, b2, fa, jx, jd) && length(v_local - jx) < reach)
				{
					float rk;
					float tk;
					vec4 ck = crease_cap(v_local, b1, b2, true, jx, jd, COLOR, size, cpx, cap_sh, rk, tk);
					cap_keep(ck, rk, cap_1, r_1, cap_2, r_2);
				}
			}
			// The cap can only reach this pixel when the faces' heights are
			// close (|s| < 1.7 half widths, |n_a - n_b| <= 2).
			float near_d = hw_max * 3.4;
			for (int c = 0; c < 3; c++)
			{
				int bc = c == 0 ? b1 : (c == 1 ? b2 : b3);
				float dc = c == 0 ? d1 : (c == 1 ? d2 : d3);
				// The other lines it may end at.
				int o1 = c == 0 ? b2 : b1;
				int o2 = c == 2 ? b2 : b3;
				if (bc >= 0 && dc - cap_d0 < near_d && !cap_bridged(v_local, fa, bc, dc) && !cap_skip(v_local, fa, bc, reach))
				{
					float rk;
					float tk;
					vec2 jx;
					vec2 jd;
					bool je = cap_end(fa, bc, o1, jx, jd);
					if (!je)
					{
						je = cap_end(fa, bc, o2, jx, jd);
					}
					vec4 ck = crease_cap(v_local, fa, bc, je, jx, jd, COLOR, size, cpx, cap_sh, rk, tk);
					tip_k = max(tip_k, tk * ck.a);
					cap_keep(ck, rk, cap_1, r_1, cap_2, r_2);
				}
			}
		}
		else if (roof_mode == 1 && mirror)
		{
			// Gap Free, Two Slopes: one ridge along the shape, ending rounded
			// at the centre of each round end.
			float hw = cap_hw(true, -1.0);
			vec2 gr = vec2(-sin(rotation) / size.x, cos(rotation) / size.y);
			vec2 gn = normalize(gr);
			vec2 along = vec2(-gn.y, gn.x);
			vec2 braw = rotate_uv(v_local / size, rotation) * size;
			float yc = (v_max + v_min) * 0.5 * size.y;
			float sx = (braw.y - yc) / (size.y * length(gr)) / hw;
			float et = 0.0;
			vec2 end_dir = vec2(0.0);
			if (round_start || round_end)
			{
				// Way the ridge runs toward round_x1.
				vec2 xdir = dot(along, vec2(cos(rotation), sin(rotation) * size.x / size.y)) >= 0.0 ? along : -along;
				if (round_start)
				{
					float e0 = dot(v_local - cap_local(vec2(round_x0, yc), size), -xdir) / hw;
					if (e0 > et)
					{
						et = e0;
						end_dir = -xdir;
					}
				}
				if (round_end)
				{
					float e1 = dot(v_local - cap_local(vec2(round_x1, yc), size), xdir) / hw;
					if (e1 > et)
					{
						et = e1;
						end_dir = xdir;
					}
				}
			}
			vec4 ck = cap_piece(dot(v_local, along), sx, et, gn, end_dir, hw, COLOR, size, cpx, cap_sh, true);
			cap_keep(ck, length(vec2(sx, max(et, 0.0))), cap_1, r_1, cap_2, r_2);
		}
		texel *= 1.0 - (cap_style == 3 ? 0.5 : 0.35) * cap_sh * cap_sh * ink_a;
		vec3 t_before = texel;
		float a_before = alpha;
		float cap_cov;
		if (cap_style == 3)
		{
			// Roof Tool strips (partly transparent): laid one over the
			// other, the nearest on top, cross-faded around the line where
			// they meet.
			float a1 = cap_1.a;
			if (cap_2.a > 0.0)
			{
				// Only where the other strip is there to show through.
				float wx = cap_fade > 0.0 ? 0.5 + 0.5 * smoothstep(0.0, cap_fade, r_2 - r_1) : clamp((r_2 - r_1) * hw_max / cpx + 0.5, 0.5, 1.0);
				a1 *= 1.0 - (1.0 - wx) * cap_2.a;
			}
			texel = mix(texel, cap_2.rgb, cap_2.a);
			texel = mix(texel, cap_1.rgb, a1);
			cap_cov = 1.0 - (1.0 - cap_2.a) * (1.0 - a1);
		}
		else
		{
			// Where two caps meet (mitred), blend them over about a pixel.
			float cw = cap_2.a > 0.0 ? (cap_fade > 0.0 ? 0.5 + 0.5 * smoothstep(0.0, cap_fade, r_2 - r_1) : clamp((r_2 - r_1) * hw_max / cpx + 0.5, 0.5, 1.0)) : 1.0;
			vec4 cap_c = mix(cap_2, cap_1, cw);
			texel = mix(texel, cap_c.rgb, cap_c.a);
			cap_cov = cap_c.a;
		}
		// The caps also cover the cut-outs of the eave (corners of non
		// seamless textures): the roof's transparency does not hide them.
		if (alpha < 1.0 && cap_cov > 0.0)
		{
			float na = alpha + cap_cov * (1.0 - alpha);
			texel = (texel - t_before * (1.0 - cap_cov) * (1.0 - alpha)) / max(na, 0.0001);
			alpha = na;
		}
		// Side Lines: the caps are cut by the outline too, ink line there.
		// Always where they cover a cut-out of the eave (non seamless
		// texture): the eave's own ink is not there.
		float cap_a = max(cap_1.a, cap_2.a);
		if ((side_ink || a_before < 0.99) && cap_a > 0.0 && edge_count > 0)
		{
			float c_ink = max(ink_h * 0.04, cpx * 1.5);
			float de_min = 1000000.0;
			for (int i = 0; i < edge_count; i++)
			{
				vec4 e = texelFetch(edges, ivec2(i, 0), 0);
				vec2 ab = e.zw - e.xy;
				float h = clamp(dot(v_local - e.xy, ab) / max(dot(ab, ab), 0.000001), 0.0, 1.0);
				de_min = min(de_min, length(v_local - e.xy - ab * h));
			}
			// (the cap is opaque even where the roof texture is not)
			// (none on the caps' tips: they run on past the outline)
			texel *= mix(1.0, 0.12, (1.0 - smoothstep(c_ink * 0.5, c_ink, de_min)) * max(cap_a - tip_k, 0.0));
		}
	}
	float keep = round_keep;
	if (merge_on)
	{
		// Where the roof below rises higher, it shows through: the two
		// roofs meet on their real intersection line. Heights are measured
		// from the visible eave of each roof. (The soft shadow along the
		// junction is drawn by the skirt, behind this shape.)
		vec2 pdx = dFdx(v_local);
		vec2 pdy = dFdy(v_local);
		float px_w = max(max(length(pdx), length(pdy)), 0.000001);
		float hb = merge_height_all(v_local);
		float dh = (h_own - own_vis + merge_raise) - hb;
		// Heights change by about 1-3 per unit (roof slopes): clamped, so the
		// garbage derivatives on the shape's own border cannot make a far cut
		// look close.
		float gdh = clamp(length(vec2(dFdx(dh), dFdy(dh))) / px_w, 0.05, 6.0);
		// Ink line on the junction: half on each roof (thin).
		float ink_w = junction_ink > 0.0 ? max(ink_h * 0.054 * junction_ink, px_w * 0.9 * min(junction_ink, 1.0)) : 0.0;
		float cut_band = 0.0;
		bool kept = true;
		float d_edge = 100000000.0;
		if (hb >= 0.0)
		{
			float sd = dh / max(gdh, 0.0001);
			kept = sd >= 0.0;
			d_edge = abs(sd);
			// Faces lying in the same plane (roofs sharing an edge and a
			// slope): no junction line there, nor valley shadow.
			if (length(vec2(dFdx(dh), dFdy(dh))) / px_w < 0.02)
			{
				d_edge = 100000000.0;
			}
			keep *= clamp(sd / px_w + 0.5, 0.0, 1.0);
		}
		if (kept && d_edge < valley_w)
		{
			// Valley shadow on this roof too (the roof below gets the same
			// one from the skirt): darkest on the line, fading out smoothly.
			texel *= 1.0 - valley_strength * valley_fade(1.0 - d_edge / max(valley_w, 0.001)) * ink_a;
		}
		if (d_edge < ink_w)
		{
			float jband = 1.0 - smoothstep(ink_w * 0.5, ink_w, d_edge);
			if (kept)
			{
				texel *= mix(1.0, 0.12, jband * ink_a);
				// No see-through seam between the two halves.
				keep = max(keep, jband);
			}
			else
			{
				// The other half, drawn over the roof below.
				cut_band = 0.88 * jband;
			}
		}
		if (!kept && cut_band > 0.0)
		{
			texel = vec3(0.0);
			alpha = cut_band;
			keep = 1.0;
		}
	}
	COLOR = vec4(texel, alpha * keep);
	}
}
"""

var _shader: Shader = null
var _tex_info := {}       # texture instance id -> analysis Dictionary
var _states := {}         # "node-id-N" -> {"mat", "sig", "lut"}
const TOOL_DEFAULTS = {"enabled": false, "mode": MODE_FILL, "mirror": false, "round_ends": 0, "merge": false, "seams": SEAMS_SOFT, "profile": PROFILE_CONE}
var _tool_cfg := TOOL_DEFAULTS.duplicate()   # Pattern Tool: next shapes (reset with every map)
var _world_ref = null
var _pruned := false
var _prev_next_id := -1
var _select_tool = null
var _sel_sig := ""
var _sel_shapes := []
var _ui := {}             # "tool" / "select" -> controls Dictionary
var _updating_ui := false
var _copy_refs := []      # roof shapes of the last Select Tool selection: {key, sig, tex, cfg}
var _pending := []        # new pattern shapes waiting to be matched: {nid, frames}


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func initialize() -> void:
	_shader = Shader.new()
	_shader.code = SHADER_CODE
	# Bakes left by an earlier instance of the mod (reload).
	if _g != null and _g.Editor != null and _g.Editor.is_inside_tree():
		var stale = _g.Editor.get_tree().root.get_node_or_null(BAKE_HOLDER)
		if stale != null:
			stale.name = BAKE_HOLDER + "Old"
			stale.queue_free()
	_lib_load_settings()
	_build_ui()
	# Other mods find this instance here (weak: a mods reload frees it).
	Engine.set_meta(API_META, weakref(self))
	print("[BetterRoofPatterns] initialized")


func update(_delta) -> void:
	_api_frame = Engine.get_idle_frames()
	_warm_shader()
	if (_lib_on or _lib_dirty) and _api_frame % 10 == 0:
		_lib_sync()
		_lib_dirty = false
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		_clear_captures()
		return
	if _g.World != _world_ref:
		_world_ref = _g.World
		_drop_all_states()
		_reset_tool_cfg()
		_pruned = false
		_prev_next_id = -1
		_sel_sig = ""
		_sel_shapes = []
		_pending = []
	_process_captures()
	if not _g.World.has_method("HasNodeID"):
		return
	var store = _get_store()
	if store == null:
		return
	if not _pruned:
		_pruned = true
		_prune_store(store)
	_detect_new_shapes(store)
	_match_pending(store)
	_light_hash = hash(_g.ModMapData.get(GLOBAL_KEY)) if _g.ModMapData is Dictionary else 0
	_sync_all(store)
	_process_bakes()
	_update_selection(store)


# ── Store ─────────────────────────────────────────────────────────────────────

func _get_store():
	if not (_g.ModMapData is Dictionary):
		return null
	if not _g.ModMapData.has(STORE_KEY) or not (_g.ModMapData[STORE_KEY] is Dictionary):
		_g.ModMapData[STORE_KEY] = {}
	return _g.ModMapData[STORE_KEY]


func _prune_store(store: Dictionary) -> void:
	# Drops entries of shapes that no longer exist (done once per map load:
	# during a session, a deleted shape can come back through undo).
	for key in store.keys():
		var nid = _id_of_key(key)
		if nid < 0 or not _g.World.HasNodeID(nid) or not (store[key] is Dictionary):
			store.erase(key)


func _id_of_key(key) -> int:
	if not (key is String) or not key.begins_with("node-id-"):
		return -1
	return int(key.substr(8))


func _key_of(node) -> String:
	if node == null or not is_instance_valid(node) or not node.has_meta("node_id"):
		return ""
	return "node-id-" + str(node.get_meta("node_id"))


func _is_pattern_shape(node) -> bool:
	return node != null and is_instance_valid(node) and node is Polygon2D and node.has_method("SetNewRotation")


func _full_cfg(cfg) -> Dictionary:
	var out = DEFAULT_CFG.duplicate()
	if cfg is Dictionary:
		for k in cfg.keys():
			out[k] = cfg[k]
	out["mode"] = _valid_mode(int(out["mode"]))
	for k in ["curve", "repeat", "cap_width_hip", "cap_tip", "cap_fade", "cap_bright", "cap_hue", "cap_sat", "cap_width", "edge", "u_offset", "merge_height", "valley_line", "valley_opacity", "valley_width", "scale", "ridge_offset", "pitch", "shade", "light", "apex_x", "apex_y"]:
		out[k] = float(out[k])
	for k in ["mirror", "taper", "soft_seams", "apex_on", "shade_on", "merge", "side_ink", "apex_lock", "ridge_caps", "size_link"]:
		out[k] = bool(out[k])
	# Seams: older roofs only have Softer Seams / Ridge Caps.
	if not (cfg is Dictionary and cfg.has("seams")):
		out["seams"] = SEAMS_CAPS if out["ridge_caps"] else (SEAMS_SOFT if out["soft_seams"] else SEAMS_LINE)
	out["seams"] = int(clamp(int(out["seams"]), SEAMS_NONE, SEAMS_CAPS))
	out["profile"] = int(clamp(int(out["profile"]), PROFILE_CONE, PROFILE_ONION))
	out["soft_seams"] = out["seams"] >= SEAMS_SOFT
	out["ridge_caps"] = out["seams"] == SEAMS_CAPS
	# Cap Outline: None / Line / Blurred (older roofs: on / off).
	if cfg is Dictionary and not cfg.has("cap_outline") and cfg.has("cap_ink"):
		out["cap_outline"] = 1 if bool(cfg["cap_ink"]) else 0
	out.erase("cap_ink")
	out["cap_outline"] = int(clamp(int(out["cap_outline"]), 0, 2))
	out["round_ends"] = int(clamp(int(out["round_ends"]), 0, 3))
	out["cap_style"] = int(clamp(int(out["cap_style"]), 0, CAP_PATH))
	out["cap_path_ridge"] = str(out["cap_path_ridge"])
	out["cap_path_hip"] = str(out["cap_path_hip"])
	# Older roofs: one Cap Width for both.
	if not (cfg is Dictionary and cfg.has("cap_width_hip")):
		out["cap_width_hip"] = float(out["cap_width"])
	out["cap_width_on"] = int(clamp(int(out["cap_width_on"]), 0, 2))
	out["cap_corners"] = int(clamp(int(out["cap_corners"]), 0, 2))
	# Cap Recolor: on for older roofs with a recolor set.
	if not (cfg is Dictionary and cfg.has("cap_recolor")):
		out["cap_recolor"] = out["cap_bright"] != 0.0 or out["cap_hue"] != 0.0 or out["cap_sat"] != 0.0
	out["cap_recolor"] = bool(out["cap_recolor"])
	out["cap_recolor_on"] = int(clamp(int(out["cap_recolor_on"]), 0, 2))
	out["ridge_ends"] = int(clamp(int(out["ridge_ends"]), 0, 1))
	return out


func _valid_mode(m: int) -> int:
	if m == MODE_CENTER or m == MODE_HIP:
		return m
	return MODE_FILL


func _active_tool() -> String:
	if _g.Editor == null:
		return ""
	var n = _g.Editor.get("ActiveToolName")
	return str(n) if n != null else ""


# ── New shapes drawn with the Pattern Tool ────────────────────────────────────

func _detect_new_shapes(store: Dictionary) -> void:
	var nid_now = _g.World.get("nextNodeID")
	if nid_now == null:
		return
	var cur = int(nid_now)
	if _prev_next_id < 0 or cur < _prev_next_id:
		_prev_next_id = cur
		return
	if cur == _prev_next_id:
		return
	var active = _active_tool()
	if active == "PatternShapeTool" and bool(_tool_cfg.get("enabled", false)):
		for nid in range(_prev_next_id, cur):
			if not _g.World.HasNodeID(nid):
				continue
			var nd = _g.World.GetNodeByID(nid)
			if _is_pattern_shape(nd) and not _never_roof(nd, nid):
				var cfg = _full_cfg({})
				cfg["mode"] = int(_tool_cfg.get("mode", MODE_FILL))
				cfg["mirror"] = bool(_tool_cfg.get("mirror", false))
				cfg["round_ends"] = int(_tool_cfg.get("round_ends", 0))
				cfg["merge"] = bool(_tool_cfg.get("merge", false))
				cfg["seams"] = int(_tool_cfg.get("seams", SEAMS_SOFT))
				cfg["profile"] = int(_tool_cfg.get("profile", PROFILE_CONE))
				store["node-id-" + str(nid)] = cfg
	elif active != "PatternShapeTool":
		# Paste / duplicate (Select Tool), prefabs...: new pattern shapes are
		# matched with the roofs they were copied from.
		for nid in range(_prev_next_id, cur):
			_pending.append({"nid": nid, "frames": 0})
	_prev_next_id = cur


# Copy / paste: DD pastes a pattern shape with the same local points and
# texture (only its position changes), so a new shape is a copy of a roof
# when both match. Sources: the roofs selected when the copy was made (they
# may have been cut since) and every roof still on the map.
func _match_pending(store: Dictionary) -> void:
	if _pending.empty():
		return
	var keep = []
	var refs = null
	for item in _pending:
		var nid = int(item["nid"])
		if not _g.World.HasNodeID(nid):
			item["frames"] += 1
			if item["frames"] < 30:
				keep.append(item)
			continue
		var nd = _g.World.GetNodeByID(nid)
		var key = "node-id-" + str(nid)
		if not _is_pattern_shape(nd) or store.has(key) or _never_roof(nd, nid):
			continue
		var sig = _shape_sig(nd)
		if sig == "":
			item["frames"] += 1
			if item["frames"] < 30:
				keep.append(item)
			continue
		if refs == null:
			refs = _roof_refs(store)
		var tex = _tex_path(nd)
		for r in refs:
			if r["sig"] == sig and (r["tex"] == "" or tex == "" or r["tex"] == tex) and r["key"] != key:
				store[key] = _full_cfg(r["cfg"])
				break
	_pending = keep


func _roof_refs(store: Dictionary) -> Array:
	var refs = []
	for r in _copy_refs:
		var cfg = store[r["key"]] if store.has(r["key"]) else r["cfg"]
		refs.append({"key": r["key"], "sig": r["sig"], "tex": r["tex"], "cfg": cfg})
	for key in store.keys():
		var nid = _id_of_key(key)
		if nid < 0 or not _g.World.HasNodeID(nid):
			continue
		var nd = _g.World.GetNodeByID(nid)
		if _is_pattern_shape(nd):
			refs.append({"key": key, "sig": _shape_sig(nd), "tex": _tex_path(nd), "cfg": store[key]})
	return refs


func _shape_sig(node) -> String:
	var poly = node.polygon
	if poly.size() < 3:
		return ""
	var parts = PoolStringArray()
	for p in poly:
		parts.append("%.1f,%.1f" % [p.x, p.y])
	return parts.join(";")


# Pattern shapes that are never roofs: shapes other mods mark with SKIP_META,
# and the building shadows of Soft Shadows (listed in its own registry).
func _never_roof(nd, nid: int) -> bool:
	if nd != null and is_instance_valid(nd) and nd.has_meta(SKIP_META):
		return true
	if _g != null and _g.ModMapData is Dictionary:
		var reg = _g.ModMapData.get(SHADOW_REGISTRY)
		if reg is Dictionary and reg.has(str(nid)):
			return true
	return false


func _tex_path(node) -> String:
	var tex = node.get("_Texture")
	if tex == null or not (tex is Resource):
		return ""
	return str(tex.resource_path)


# ── Material sync ─────────────────────────────────────────────────────────────

func _sync_all(store: Dictionary) -> void:
	_roof_cache = null
	if store.empty():
		return
	for key in store.keys():
		var nid = _id_of_key(key)
		if nid < 0 or not _g.World.HasNodeID(nid):
			_drop_state(key)
			continue
		var nd = _g.World.GetNodeByID(nid)
		if not _is_pattern_shape(nd):
			continue
		if _never_roof(nd, nid):
			# Made a roof by mistake (a building shadow drawn while the Pattern
			# Tool's Roof Builder option was on): back to a plain pattern.
			store.erase(key)
			_restore_shape(nd, key)
			continue
		_sync_shape(nd, key, store[key])


func _sync_shape(node, key: String, cfg) -> void:
	var mat = node.material
	if mat == null:
		# Plain colour pattern (X, first of the list): no material at all.
		# The roof gets a plain white texture, coloured by the shape colour.
		var pm = ShaderMaterial.new()
		pm.shader = _shader
		pm.set_shader_param("albedo", _plain_tex())
		var prot = node.get("_Rotation")
		pm.set_shader_param("rotation", float(prot) if prot != null else 0.0)
		pm.set_shader_param("custom_color", false)
		var pst = _states.get(key)
		if pst != null:
			pst["dead"] = true
		var nst = {"mat": pm, "sig": "", "lut": null}
		if pst != null and pst.get("bake") != null:
			nst["bake"] = pst["bake"]
		_states[key] = nst
		node.material = pm
		mat = pm
	if not (mat is ShaderMaterial) or mat.shader == null:
		return
	var st = _states.get(key)
	if st == null or st["mat"] != mat:
		var reuse = false
		if mat.shader != _shader:
			var code = mat.shader.code
			# Free Transform (Unofficial Patch) owns this shape for now.
			if code.find("ft_corner_tl") >= 0:
				_remove_skirt(node, st)
				_remove_tips(node)
				return
			var nm = null
			if _is_ct_material(mat):
				# Coloured by Colour and Modify Things: its settings go into the
				# roof material already built when there is one (only the
				# colours change, nothing is rebuilt).
				reuse = st != null and st["mat"] is ShaderMaterial and st["mat"].shader == _shader
				if reuse:
					nm = st["mat"]
				else:
					nm = ShaderMaterial.new()
					nm.shader = _shader
				_ct_take(node, mat, nm)
				# Its edge blur / gradient can change the visible outline.
				_geo_rev += 1
			else:
				var albedo = mat.get_shader_param("albedo")
				if albedo == null:
					return
				var custom = false
				if code.find("roof_mode") >= 0:
					custom = mat.get_shader_param("custom_color") == true
				else:
					custom = code.find("redness") >= 0
				nm = ShaderMaterial.new()
				nm.shader = _shader
				nm.set_shader_param("albedo", albedo)
				var rot = mat.get_shader_param("rotation")
				nm.set_shader_param("rotation", float(rot) if rot != null else 0.0)
				nm.set_shader_param("use_wear", mat.get_shader_param("use_wear") == true)
				var wear = mat.get_shader_param("wear")
				if wear != null:
					nm.set_shader_param("wear", wear)
				nm.set_shader_param("custom_color", custom)
			node.material = nm
			mat = nm
		if not reuse:
			var old_bake = st.get("bake") if st != null else null
			if st != null:
				st["dead"] = true
			st = {"mat": mat, "sig": "", "lut": null}
			if old_bake != null:
				st["bake"] = old_bake
			_states[key] = st
	# Cheap check first (runs for every roof at every frame): nothing to do
	# while the shape, its settings and the light are unchanged. Merged roofs
	# also look again whenever any roof of the map changed.
	var merged = cfg is Dictionary and bool(cfg.get("merge", false))
	var ck = _cheap_key(node, mat, cfg)
	if st.get("ck") == ck and (not merged or st.get("rev") == _map_rev):
		return
	if st.get("ck") != ck:
		_map_rev += 1
	# Cap Style Roof Pieces on a texture without them (pasted settings,
	# texture changed...): back to Auto.
	if cfg is Dictionary and int(cfg.get("cap_style", 0)) == 3 and not _has_pieces(mat.get_shader_param("albedo")):
		cfg["cap_style"] = 0
		ck = _cheap_key(node, mat, cfg)
	st["ck"] = ck
	st["rev"] = _map_rev
	var full = _full_cfg(cfg)
	# Light settings only change a few uniforms: kept out of the geometry
	# signature so they never rebuild the roof or its shadow.
	var gcfg = full.duplicate()
	for k in ["shade", "light", "shade_on"]:
		gcfg.erase(k)
	var sig = _signature(node, mat, gcfg) + "|" + str(node.get_global_transform()) + "|" + str(node.is_inside_tree())
	var lsig = str([full["shade"], full["light"], full["shade_on"], _global_light()])
	st["xform"] = node.get_global_transform()
	st["merge"] = null
	if full["merge"]:
		st["merge"] = _find_merge_partner(node, key)
		if st["merge"] != null:
			sig += "|" + st["merge"]["sig"]
	if sig == st["sig"]:
		if lsig != st.get("lsig", ""):
			st["lsig"] = lsig
			_set_light(mat, full, st)
			_update_tips(node, mat)
		return
	st["sig"] = sig
	_geo_rev += 1
	st["lsig"] = lsig
	update_material(mat, node.polygon, full, st)
	_update_skirt(node, mat, full, st)
	_update_tips(node, mat)


# Colour and Modify Things (uchideshi34) colours a pattern by giving it a
# material of its own (its universal shader: pattern_tex / texture_rotation
# where DD's pattern materials have albedo / rotation).
func _is_ct_material(mat: ShaderMaterial) -> bool:
	if mat.get_shader_param("pattern_tex") == null or mat.get_shader_param("albedo") != null:
		return false
	var code = mat.shader.code
	return code.find("is_pattern") >= 0 and code.find("texture_rotation") >= 0


# Copies the settings of a Colour and Modify Things material into a roof
# material: texture, rotation and colour settings ("ct_" uniforms). The
# material is kept (meta), to give it back when the shape stops being a roof.
func _ct_take(node, src: ShaderMaterial, dst: ShaderMaterial) -> void:
	var rot = src.get_shader_param("texture_rotation")
	if rot == null:
		rot = node.get("_Rotation")
	dst.set_shader_param("albedo", src.get_shader_param("pattern_tex"))
	dst.set_shader_param("rotation", float(rot) if rot != null else 0.0)
	# Its shader has no wear and colours the colourable pixels itself.
	dst.set_shader_param("use_wear", false)
	dst.set_shader_param("custom_color", false)
	dst.set_shader_param("ct_on", true)
	for name in CT_PARAMS:
		var v = src.get_shader_param(name)
		dst.set_shader_param("ct_" + name, v if v != null else CT_PARAMS[name])
	dst.set_meta(CT_META, src)


func _cheap_key(node, mat: ShaderMaterial, cfg) -> Array:
	var rot = mat.get_shader_param("rotation")
	var tex = mat.get_shader_param("albedo")
	var p = node.get_parent()
	return [hash(cfg), hash(node.polygon), node.get_global_transform(), rot,
		tex.get_instance_id() if tex != null else 0, node.z_index,
		p.z_index if p is Node2D else 0, node.get_index() if p != null else -1,
		node.is_inside_tree(), _light_hash]


# Merge With Roof Below: the roofs drawn below this shape that overlap it
# (the most overlapping first, MAX_MERGE at most). Returns
# {"list": [{poly, cfg, xf (this shape's local -> its local), tex, rot}], "sig"}
# or null.
func _find_merge_partner(node, key: String):
	var store = _get_store()
	if store == null:
		return null
	var rect = _global_rect(node)
	var found = []
	for r in _roof_list(store):
		if r["key"] == key or not rect.intersects(r["rect"]) or not store.has(r["key"]):
			continue
		var nd = r["node"]
		if not is_instance_valid(nd) or not _drawn_below(nd, node):
			continue
		var area = rect.clip(r["rect"]).get_area()
		if area > 0.0:
			found.append([area, nd, _full_cfg(store[r["key"]])])
	if found.empty():
		return null
	found.sort_custom(self, "_sort_by_first_desc")
	var lst = []
	var sig = ""
	for f in found.slice(0, MAX_MERGE - 1):
		var pn = f[1]
		var xf = pn.get_global_transform().affine_inverse() * node.get_global_transform()
		var ptex = null
		if pn.material is ShaderMaterial:
			ptex = pn.material.get_shader_param("albedo")
		if ptex == null:
			ptex = pn.get("_Texture")
		var prot = 0.0
		if pn.material is ShaderMaterial and pn.material.get_shader_param("rotation") != null:
			prot = float(pn.material.get_shader_param("rotation"))
		lst.append({"poly": pn.polygon, "cfg": f[2], "xf": xf, "tex": ptex, "rot": prot,
			"pxf": pn.get_global_transform()})
		sig += "%.3f|%s|%s|%s|%d|%.4f;" % [_poly_hash(pn.polygon), str(xf), str(pn.get_global_transform()), str(f[2]),
			ptex.get_instance_id() if ptex != null else 0, prot]
	return {"list": lst, "sig": sig}


func _sort_by_first_desc(a, b) -> bool:
	return a[0] > b[0]


# Every roof of the map with its box on the map, listed once per frame (the
# merge search of each roof only compares boxes).
func _roof_list(store: Dictionary) -> Array:
	if _roof_cache == null:
		_roof_cache = []
		for k in store.keys():
			var nid = _id_of_key(k)
			if nid < 0 or not _g.World.HasNodeID(nid):
				continue
			var nd = _g.World.GetNodeByID(nid)
			if _is_pattern_shape(nd):
				_roof_cache.append({"key": k, "node": nd, "rect": _global_rect(nd)})
	return _roof_cache


# True when a is drawn before (under) b: lower layer, or same layer and
# earlier in the list.
func _drawn_below(a, b) -> bool:
	var pa = a.get_parent()
	var pb = b.get_parent()
	if pa == null or pb == null:
		return false
	var za = a.z_index + (pa.z_index if pa is Node2D else 0)
	var zb = b.z_index + (pb.z_index if pb is Node2D else 0)
	if za != zb:
		return za < zb
	if pa == pb:
		return a.get_index() < b.get_index()
	return false


func _global_rect(node) -> Rect2:
	var poly = node.polygon
	var xf = node.get_global_transform()
	if poly.size() == 0:
		return Rect2(xf.origin, Vector2.ZERO)
	var r = Rect2(xf.xform(poly[0]), Vector2.ZERO)
	for p in poly:
		r = r.expand(xf.xform(p))
	return r


# Changes when any point of the polygon changes (engine hash: this runs for
# every roof at every frame).
func _poly_hash(poly: PoolVector2Array) -> float:
	return float(hash(poly))


func _signature(node, mat, cfg: Dictionary) -> String:
	var poly = node.polygon
	var rot = mat.get_shader_param("rotation")
	var tex = mat.get_shader_param("albedo")
	var tid = tex.get_instance_id() if tex != null else 0
	return "%d|%d|%s|%d|%s" % [poly.size(), hash(poly), str(rot), tid, str(cfg)]


const SKIRT_NAME = "BRPContactShadow"
const TIPS_NAME = "BRPCapTips"
const BAKE_HOLDER = "BetterRoofPatternsBakes"
const BAKE_SAMPLES = 64           # disc samples per baked texel
const BAKE_TEXELS_PER_W = 6.0     # baked texels across the shadow width
const BAKE_MAX = 384              # largest side of a bake, in texels
const BAKE_DRAFT_SAMPLES = 16     # quick bake while settings / roofs change
const BAKE_DRAFT_TEXELS_PER_W = 2.5
const BAKE_DRAFT_MAX = 160
const BAKE_DRAFT_BUDGET = 3000000.0
const BAKE_SETTLE_MS = 350        # no change for this long -> full-quality bake
const BAKES_PER_FRAME = 2         # full-quality bakes started per frame at most
const BAKE_BUDGET = 60000000.0    # texture reads allowed for one bake

var _bake_root = null             # holds the bake Viewports (under the scene root)
var _roof_cache = null            # this frame's roofs: [{key, node, rect}], built on demand
var _lut_cache := {}              # "polygon hash|top" -> build_round_lut() result
var _map_rev := 0                 # bumped when any roof changes (merged roofs re-check)
var _geo_rev := 0                 # bumped when the shape of any roof changes (not its light)
var _light_hash := 0              # Global Lighting, hashed once per frame
var _bake_queue := []             # states waiting for their full-quality bake


# Contact shadow of a merged roof on the roofs below it. The drawn part of the
# roof (what is left after the merge) is blurred once into a small texture, in
# a Viewport of its own (only when something changes), and a rectangle drawn
# just behind the shape darkens the roofs below with it. So the shadow follows
# the real visible outline: junction lines, sides without an eave and corners
# alike, and nothing anywhere else.
func _update_skirt(node, mat: ShaderMaterial, cfg: Dictionary, st: Dictionary = {}) -> void:
	var full = _full_cfg(cfg)
	var need = full["merge"] and mat.get_shader_param("merge_on") == true \
		and node.is_inside_tree() and node.polygon.size() >= 3
	if not need:
		_remove_skirt(node, st)
		return
	# Only what changes the visible part of the roof triggers a new bake
	# (Tile Width, taper, light... do not).
	var m = st.get("merge")
	var tex = mat.get_shader_param("albedo")
	var bkey = str([hash(node.polygon), full["mode"], full["apex_on"], full["apex_x"], full["apex_y"],
		node.get_global_transform() if full["apex_on"] and full["apex_lock"] else null,
		full["edge"], full["pitch"], full["mirror"], full["round_ends"], full["seams"], full["merge_height"],
		full["valley_width"], full["valley_opacity"],
		mat.get_shader_param("rotation"), tex.get_instance_id() if tex != null else 0,
		m.get("sig", "") if m != null else ""])
	var sk = node.get_node_or_null(SKIRT_NAME)
	var bake = st.get("bake")
	var bake_ok = bake != null and is_instance_valid(bake["vp"]) and is_instance_valid(bake["poly"])
	if sk != null and bake_ok and st.get("bake_key") == bkey:
		return
	st["bake_key"] = bkey
	var rh = mat.get_shader_param("row_h")
	var vw = mat.get_shader_param("valley_w")
	var w = max(float(vw) if vw != null else _valley_w(min(float(rh), 128.0) if rh != null else 64.0), 1.0)
	# Area covered (shape space): the shape's box plus the reach of the shadow.
	var poly: PoolVector2Array = node.polygon
	var rect = Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	rect = rect.grow(w * 1.25 + 2.0)
	var corners = PoolVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)])
	if not bake_ok:
		var vp = Viewport.new()
		vp.size = Vector2(8, 8)
		vp.transparent_bg = true
		vp.usage = Viewport.USAGE_2D
		vp.disable_3d = true
		vp.hdr = false
		vp.gui_disable_input = true
		vp.render_target_v_flip = true
		vp.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
		vp.render_target_update_mode = Viewport.UPDATE_DISABLED
		_bake_holder(node.get_tree()).add_child(vp)
		var bp = Polygon2D.new()
		vp.add_child(bp)
		bake = {"vp": vp, "poly": bp}
		st["bake"] = bake
	bake["poly"].polygon = corners
	var bm = mat.duplicate()
	bm.set_shader_param("bake_mode", true)
	bm.set_shader_param("skirt_w", w)
	bake["poly"].material = bm
	st["bake_rect"] = rect
	st["bake_w"] = w
	st["bake_cost"] = _bake_cost(mat, poly.size(), st)
	# Quick, rough bake now; the full-quality one once the settings have not
	# changed for a moment (sliders being dragged, a roof being moved...).
	_run_bake(st, false)
	st["bake_full_at"] = OS.get_ticks_msec() + BAKE_SETTLE_MS
	if not st.get("bake_queued", false):
		st["bake_queued"] = true
		_bake_queue.append(st)
	# The rectangle behind the shape.
	if sk == null:
		sk = Polygon2D.new()
		sk.name = SKIRT_NAME
		sk.show_behind_parent = true
		node.add_child(sk)
	sk.polygon = corners
	var btex = bake["vp"].get_texture()
	btex.flags = Texture.FLAG_FILTER
	var sm = mat.duplicate()
	sm.set_shader_param("skirt_mode", true)
	sm.set_shader_param("skirt_w", w)
	sm.set_shader_param("bake_tex", btex)
	sm.set_shader_param("bake_pos", rect.position)
	sm.set_shader_param("bake_size", rect.size)
	sk.material = sm


# Renders the bake of a state: rough (few samples, small) or full quality.
func _run_bake(st: Dictionary, full_quality: bool) -> void:
	var bake = st.get("bake")
	if bake == null or not is_instance_valid(bake["vp"]) or not is_instance_valid(bake["poly"]):
		return
	var rect: Rect2 = st["bake_rect"]
	var w = float(st["bake_w"])
	var samples = BAKE_SAMPLES if full_quality else BAKE_DRAFT_SAMPLES
	var tpw = BAKE_TEXELS_PER_W if full_quality else BAKE_DRAFT_TEXELS_PER_W
	var mx = BAKE_MAX if full_quality else BAKE_DRAFT_MAX
	var budget = BAKE_BUDGET if full_quality else BAKE_DRAFT_BUDGET
	var k = tpw / w
	k = min(k, float(mx) / max(rect.size.x, rect.size.y))
	k = min(k, sqrt(budget / (float(samples) * float(st.get("bake_cost", 100.0))) / (rect.size.x * rect.size.y)))
	var bw = int(clamp(ceil(rect.size.x * k), 8, mx))
	var bh = int(clamp(ceil(rect.size.y * k), 8, mx))
	var vp = bake["vp"]
	if vp.size != Vector2(bw, bh):
		vp.size = Vector2(bw, bh)
	var bp = bake["poly"]
	var sc = Vector2(float(bw) / rect.size.x, float(bh) / rect.size.y)
	bp.scale = sc
	bp.position = -rect.position * sc
	if bp.material is ShaderMaterial:
		bp.material.set_shader_param("bake_n", samples)
	vp.render_target_update_mode = Viewport.UPDATE_ONCE


# Full-quality bakes of the roofs that stopped changing, a few per frame.
func _process_bakes() -> void:
	if _bake_queue.empty():
		return
	var now = OS.get_ticks_msec()
	var keep = []
	var done = 0
	for st in _bake_queue:
		if st.get("dead", false) or st.get("bake") == null:
			st["bake_queued"] = false
			continue
		if done < BAKES_PER_FRAME and now >= int(st.get("bake_full_at", 0)):
			_run_bake(st, true)
			st["bake_queued"] = false
			done += 1
		else:
			keep.append(st)
	_bake_queue = keep


# Runs every waiting full-quality bake now (test harness).
func flush_bakes() -> void:
	for st in _bake_queue:
		if not st.get("dead", false) and st.get("bake") != null:
			_run_bake(st, true)
		st["bake_queued"] = false
	_bake_queue = []


# Texture reads for one bake sample (to keep big or complex roofs affordable).
func _bake_cost(mat: ShaderMaterial, n_points: int, st: Dictionary) -> float:
	var n = float(min(n_points, MAX_EDGES))
	var mode = int(mat.get_shader_param("roof_mode"))
	var cost = 6.0
	if mode == MODE_HIP:
		cost += n * 3.0
	elif mode == MODE_CENTER:
		if mat.get_shader_param("star_shape") != true:
			cost += n
		var soft = mat.get_shader_param("seam_soft")
		if mat.get_shader_param("smooth_shape") != true and soft != null and float(soft) > 0.0:
			cost += n * 3.0
	else:
		cost += n
	return cost + float(st.get("merge_cost", 0.0))


func _bake_holder(tree: SceneTree) -> Node:
	if _bake_root == null or not is_instance_valid(_bake_root):
		_bake_root = tree.root.get_node_or_null(BAKE_HOLDER)
		if _bake_root == null:
			_bake_root = Node.new()
			_bake_root.name = BAKE_HOLDER
			tree.root.add_child(_bake_root)
	return _bake_root


# Ridge Caps on Hip roofs with a non seamless texture: their rounded tips go
# a little past the outline's corners. Small squares around the corners, drawn
# above the shape with a copy of its material (tip_mode), show that part.
func _update_tips(node, mat: ShaderMaterial) -> void:
	var holder = node.get_node_or_null(TIPS_NAME)
	var poly: PoolVector2Array = node.polygon
	var n = poly.size()
	var need = n >= 3 and int(mat.get_shader_param("roof_mode")) == MODE_HIP \
		and mat.get_shader_param("ridge_caps") == true \
		and int(mat.get_shader_param("edge_count")) > 0
	if not need:
		_remove_tips(node)
		return
	# Reach of a tip: a few cap half widths.
	var cs = max(float(mat.get_shader_param("cap_scale")), float(mat.get_shader_param("cap_scale_hip")))
	var hw = float(mat.get_shader_param("cap_base")) * 1.15 * cs * 0.5
	if int(mat.get_shader_param("cap_style")) == 3:
		for k in ["cap_ridge_tex", "cap_hip_tex"]:
			var t = mat.get_shader_param(k)
			if t is Texture:
				hw = max(hw, t.get_height() * 0.5 * cs)
	var tl = mat.get_shader_param("tip_len")
	var reach = max(hw, 1.0) * (3.0 + max(float(tl) if tl != null else 0.0, 0.0))
	# Outer corners (turning by more than ~20 degrees).
	var area = 0.0
	for k in range(n):
		area += poly[k].cross(poly[(k + 1) % n])
	var quads = []
	for k in range(n):
		var a = poly[(k + n - 1) % n]
		var b = poly[k]
		var c = poly[(k + 1) % n]
		var d1 = b - a
		var d2 = c - b
		if d1.length_squared() < 0.0001 or d2.length_squared() < 0.0001:
			continue
		var cr = d1.normalized().cross(d2.normalized())
		if cr * sign(area) > 0.34 and quads.size() < 64:
			quads.append(b)
	if holder == null:
		holder = Node2D.new()
		holder.name = TIPS_NAME
		node.add_child(holder)
	var tm = mat.duplicate()
	tm.set_shader_param("tip_mode", true)
	var kids = holder.get_children()
	for k in range(max(kids.size(), quads.size())):
		if k >= quads.size():
			holder.remove_child(kids[k])
			kids[k].queue_free()
			continue
		var p: Polygon2D = kids[k] if k < kids.size() else null
		if p == null:
			p = Polygon2D.new()
			holder.add_child(p)
		var q: Vector2 = quads[k]
		p.polygon = PoolVector2Array([q + Vector2(-reach, -reach), q + Vector2(reach, -reach),
			q + Vector2(reach, reach), q + Vector2(-reach, reach)])
		p.color = node.color
		p.material = tm


func _remove_tips(node) -> void:
	if node != null and is_instance_valid(node):
		var tips = node.get_node_or_null(TIPS_NAME)
		if tips != null:
			node.remove_child(tips)
			tips.queue_free()


func _remove_skirt(node, st) -> void:
	if node != null and is_instance_valid(node):
		var sk = node.get_node_or_null(SKIRT_NAME)
		if sk != null:
			node.remove_child(sk)
			sk.queue_free()
	_free_bake(st)


func _free_bake(st) -> void:
	if not (st is Dictionary):
		return
	st.erase("bake_key")
	var bake = st.get("bake")
	if bake != null:
		if is_instance_valid(bake["vp"]):
			bake["vp"].queue_free()
		st.erase("bake")


func _drop_state(key: String) -> void:
	var st = _states.get(key)
	if st == null:
		return
	_free_bake(st)
	st["dead"] = true
	_states.erase(key)
	_map_rev += 1
	_geo_rev += 1


func _drop_all_states() -> void:
	for key in _states.keys():
		_free_bake(_states[key])
		_states[key]["dead"] = true
	_states.clear()
	_bake_queue = []
	_lut_cache.clear()
	_clear_captures()


# ── Public API for other mods ─────────────────────────────────────────────────
# Soft Shadows' Building Shadow tool asks for the outline of the VISIBLE
# pixels of the roofs under the cursor (with every roof overlapping them) to
# cast their shadow. Found through Engine meta API_META (a WeakRef to this
# instance); roof_api_alive() tells whether this instance is still running.

const API_META = "RoofBuilderForPatterns"
const API_VERSION = 2
const CAP_MAX = 1024              # largest side of an outline capture, in pixels
const CAP_PIXELS = 200000         # pixels of a capture at most (tracing cost)
const CAP_PAD = 4                 # empty border around a capture, in pixels
const CAP_ALPHA = 0.5             # alpha from which a pixel counts as visible
const CAP_EPS = 1.0               # outline simplification, in capture pixels
const CAP_WAIT = 2                # frames between a capture and its read-back
const CAP_RETRY = 8               # frames an empty capture is rendered again
const CAP_CACHE_MAX = 16
const CAP_TOUCH = 2.0             # roofs closer than this (px) belong together

var _api_frame := -1              # last frame update() ran
var _cap_cache := {}              # group key -> outlines (world coordinates)
var _cap_order := []              # cached group keys, oldest first
var _cap_jobs := {}               # group key -> capture being rendered


func roof_api_version() -> int:
	return API_VERSION


# False once this instance stopped running (mods reloaded or disabled).
func roof_api_alive() -> bool:
	return _api_frame >= 0 and Engine.get_idle_frames() - _api_frame <= 3


# Changes whenever the shape of a roof changes, not its light (lets other mods
# drop what they cached).
func roof_api_revision() -> int:
	return _geo_rev


# Global Lighting: one light for every roof of the map (saved with the map).
# {"on": bool, "shade": strength 0..1, "light": where the light comes from,
# in degrees, 0 = top, clockwise}.
func roof_global_light() -> Dictionary:
	return _global_light()


# Changes Global Lighting (any of "on", "shade", "light"); the roofs follow on
# the next frame.
func roof_set_global_light(fields: Dictionary) -> void:
	var f = {}
	if fields.has("on"):
		f["on"] = bool(fields["on"])
	if fields.has("shade"):
		f["shade"] = clamp(float(fields["shade"]), 0.0, 1.0)
	if fields.has("light"):
		f["light"] = fposmod(float(fields["light"]), 360.0)
	if not f.empty():
		_set_global_light(f)


# Outlines of the visible pixels of the roofs at world_pos on the current
# level, taken together with every roof overlapping them (and the roofs
# overlapping those...), and with the roofs overlapping one of the `extra`
# polygons (world coordinates, e.g. the outline of a building).
# Returns an Array of outlines (Arrays of Vector2 in world coordinates,
# counter-clockwise, one per separate visible part, holes filled), [] when
# there is no roof there, or null while the roofs are being rendered: ask
# again on a later frame (2 or 3 frames later).
# inset > 0: the outlines are shrunk to stay at least that far inside the
# visible pixels (the precision of the outlines is accounted for).
func roof_outlines_at(world_pos: Vector2, extra: Array = [], inset: float = 0.0):
	var group = _roof_group_at(world_pos, extra)
	if group.empty():
		return []
	var gkey = _group_key(group)
	if _cap_cache.has(gkey):
		var res = _cap_cache[gkey]
		var out = []
		for ring in res["rings"]:
			if inset <= 0.0:
				out.append(ring.duplicate())
				continue
			for piece in Geometry.offset_polygon_2d(PoolVector2Array(ring), -(inset + float(res["err"])), Geometry.JOIN_MITER):
				if piece.size() >= 3 and not Geometry.is_polygon_clockwise(piece):
					out.append(Array(piece))
		return out
	if not _cap_jobs.has(gkey):
		_start_capture(gkey, group)
		if _cap_cache.has(gkey):
			return []
	return null


# The roofs of the group at world_pos: [{key, node, poly (world), rect}].
func _roof_group_at(world_pos: Vector2, extra: Array) -> Array:
	if _g == null or _g.World == null or not is_instance_valid(_g.World) \
			or not _g.World.is_inside_tree() or not _g.World.has_method("GetCurrentLevel"):
		return []
	var level = _g.World.GetCurrentLevel()
	var store = _get_store()
	if level == null or store == null or store.empty():
		return []
	var roofs = []
	for key in store.keys():
		var nid = _id_of_key(key)
		if nid < 0 or not _g.World.HasNodeID(nid):
			continue
		var nd = _g.World.GetNodeByID(nid)
		if not _is_pattern_shape(nd) or not nd.is_inside_tree() or nd.polygon.size() < 3 \
				or not level.is_a_parent_of(nd) or not nd.is_visible_in_tree():
			continue
		if not (nd.material is ShaderMaterial) or nd.material.shader != _shader or _never_roof(nd, nid):
			continue
		var xf = nd.get_global_transform()
		var wp = PoolVector2Array()
		for p in nd.polygon:
			wp.append(xf.xform(p + nd.offset))
		roofs.append({"key": key, "node": nd, "poly": wp, "rect": _points_rect(wp)})
	var extras = []
	for e in extra:
		if e.size() >= 3:
			extras.append({"poly": PoolVector2Array(e), "rect": _points_rect(e)})
	var n = roofs.size()
	var in_group = []
	var queue = []
	for i in range(n):
		var r = roofs[i]
		var hit = r["rect"].has_point(world_pos) and Geometry.is_point_in_polygon(world_pos, r["poly"])
		if not hit:
			for e in extras:
				if _roofs_touch(r, e):
					hit = true
					break
		in_group.append(hit)
		if hit:
			queue.append(i)
	while not queue.empty():
		var i = queue.pop_back()
		for j in range(n):
			if not in_group[j] and _roofs_touch(roofs[i], roofs[j]):
				in_group[j] = true
				queue.append(j)
	var group = []
	for i in range(n):
		if in_group[i]:
			group.append(roofs[i])
	return group


# Do roof a and polygon b overlap, or come closer than CAP_TOUCH?
func _roofs_touch(a: Dictionary, b: Dictionary) -> bool:
	if not a["rect"].grow(CAP_TOUCH).intersects(b["rect"]):
		return false
	if not a.has("grown"):
		var best = a["poly"]
		var best_area = 0.0
		for g in Geometry.offset_polygon_2d(a["poly"], CAP_TOUCH):
			var ga = _ring_area(g)
			if not Geometry.is_polygon_clockwise(g) and ga > best_area:
				best_area = ga
				best = g
		a["grown"] = best
	return not Geometry.intersect_polygons_2d(a["grown"], b["poly"]).empty()


func _points_rect(pts) -> Rect2:
	var r = Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


func _ring_area(pts) -> float:
	var a = 0.0
	var n = pts.size()
	for i in range(n):
		a += pts[i].cross(pts[(i + 1) % n])
	return abs(a) * 0.5


# Everything that changes the visible pixels of the group.
func _group_key(group: Array) -> String:
	var store = _get_store()
	var parts = []
	for r in group:
		var nd = r["node"]
		var mat = nd.material
		var tex = mat.get_shader_param("albedo")
		var cfg = _full_cfg(store.get(r["key"]) if store != null else null)
		for k in ["shade", "light", "shade_on"]:
			cfg.erase(k)
		var st = _states.get(r["key"], {})
		# Colour and Modify Things (edge blur, gradient alpha): a new material
		# of its own for every change.
		var ct = mat.get_meta(CT_META) if mat.has_meta(CT_META) and mat.get_shader_param("ct_on") == true else null
		parts.append([r["key"], hash(nd.polygon), nd.offset, nd.get_global_transform(),
			mat.get_shader_param("rotation"), tex.get_instance_id() if tex != null else 0,
			hash(cfg), st.get("sig", ""), ct.get_instance_id() if ct != null else 0])
	return str(parts)


# Renders the roofs of a group (their own materials, plain white) into a
# Viewport; the pixels are read back and traced a few frames later.
func _start_capture(gkey: String, group: Array) -> void:
	if not _g.World.is_inside_tree():
		_cache_outlines(gkey, [])
		return
	var rect = group[0]["rect"]
	for r in group:
		rect = rect.merge(r["rect"])
	var k = min(1.0, float(CAP_MAX - 2 * CAP_PAD) / max(max(rect.size.x, rect.size.y), 1.0))
	k = min(k, sqrt(float(CAP_PIXELS) / max(rect.size.x * rect.size.y, 1.0)))
	var vp = Viewport.new()
	vp.size = Vector2(int(ceil(rect.size.x * k)) + 2 * CAP_PAD, int(ceil(rect.size.y * k)) + 2 * CAP_PAD)
	vp.transparent_bg = true
	vp.usage = Viewport.USAGE_2D
	vp.disable_3d = true
	vp.hdr = false
	vp.gui_disable_input = true
	vp.render_target_v_flip = true
	vp.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = Viewport.UPDATE_ONCE
	_bake_holder(_g.World.get_tree()).add_child(vp)
	var cxf = Transform2D(Vector2(k, 0.0), Vector2(0.0, k), Vector2(CAP_PAD, CAP_PAD) - rect.position * k)
	for r in group:
		var nd = r["node"]
		var cp = Polygon2D.new()
		cp.polygon = nd.polygon
		cp.offset = nd.offset
		cp.color = Color(1, 1, 1, 1)
		cp.material = nd.material
		cp.transform = cxf * nd.get_global_transform()
		vp.add_child(cp)
	var now = Engine.get_idle_frames()
	_cap_jobs[gkey] = {"vp": vp, "k": k, "origin": rect.position, "frame": now, "start": now}


# Reads back and traces the captures rendered since the last frames (one per
# frame: tracing takes a few milliseconds).
func _process_captures() -> void:
	if _cap_jobs.empty():
		return
	var now = Engine.get_idle_frames()
	var traced = false
	for gkey in _cap_jobs.keys():
		var job = _cap_jobs[gkey]
		var vp = job["vp"]
		if not is_instance_valid(vp):
			_cap_jobs.erase(gkey)
			continue
		if now < int(job["frame"]) + CAP_WAIT or traced:
			continue
		traced = true
		var img = vp.get_texture().get_data()
		var bm = BitMap.new()
		if img != null and not img.is_empty():
			bm.create_from_image_alpha(img, CAP_ALPHA)
		if (img == null or img.is_empty() or bm.get_true_bit_count() == 0) and now < int(job["start"]) + CAP_RETRY:
			# Nothing drawn yet: render once more.
			job["frame"] = now
			vp.render_target_update_mode = Viewport.UPDATE_ONCE
			continue
		_cap_jobs.erase(gkey)
		vp.queue_free()
		var rings = _trace_outlines(bm, job) if img != null and not img.is_empty() else []
		_cache_outlines(gkey, rings, (CAP_EPS + 0.5) / float(job["k"]))


# Visible pixels -> outlines in world coordinates.
func _trace_outlines(bm: BitMap, job: Dictionary) -> Array:
	var count = bm.get_true_bit_count()
	if count == 0:
		return []
	var full = Rect2(Vector2.ZERO, bm.get_size())
	var polys = bm.opaque_to_polygons(full, CAP_EPS)
	var area = 0.0
	for poly in polys:
		area += _ring_area(poly)
	if area < float(count) * 0.9:
		# The tracing loses what touches the rest by a corner only (all of
		# it, when it starts there): close the mask and trace again.
		bm.grow_mask(1, full)
		bm.grow_mask(-1, full)
		polys = bm.opaque_to_polygons(full, CAP_EPS)
	var k = float(job["k"])
	var org: Vector2 = job["origin"]
	var pad = Vector2(CAP_PAD, CAP_PAD)
	var out = []
	for poly in polys:
		if poly.size() < 3 or _ring_area(poly) < 16.0:
			continue
		var ring = []
		for p in poly:
			ring.append(org + (p - pad) / k)
		if Geometry.is_polygon_clockwise(PoolVector2Array(ring)):
			ring.invert()
		out.append(ring)
	return out


# err: how far (world px) an outline may stray outside the visible pixels.
func _cache_outlines(gkey: String, outlines: Array, err: float = 0.0) -> void:
	if _cap_cache.has(gkey):
		_cap_order.erase(gkey)
	_cap_cache[gkey] = {"rings": outlines, "err": err}
	_cap_order.append(gkey)
	while _cap_order.size() > CAP_CACHE_MAX:
		_cap_cache.erase(_cap_order.pop_front())


func _clear_captures() -> void:
	if not _cap_jobs.empty():
		for job in _cap_jobs.values():
			if is_instance_valid(job["vp"]):
				job["vp"].queue_free()
		_cap_jobs.clear()
	if not _cap_cache.empty():
		_cap_cache.clear()
		_cap_order.clear()


func _restore_shape(node, key: String) -> void:
	# Lets DD rebuild its own pattern material (SetOptions replaces any
	# material whose shader is not DD's).
	_remove_skirt(node if _is_pattern_shape(node) else null, _states.get(key))
	_remove_tips(node if _is_pattern_shape(node) else null)
	_drop_state(key)
	if not _is_pattern_shape(node):
		return
	var mat = node.material
	if not (mat is ShaderMaterial) or mat.shader != _shader:
		return
	var tex = node.get("_Texture")
	var rot = node.get("_Rotation")
	if tex == null:
		tex = mat.get_shader_param("albedo")
	if tex == _plain:
		# Plain colour pattern: back to no material.
		node.material = null
		return
	if rot == null:
		rot = mat.get_shader_param("rotation")
	var src = mat.get_meta(CT_META) if mat.has_meta(CT_META) else null
	if mat.get_shader_param("ct_on") == true and src is ShaderMaterial and src.shader != null:
		# Coloured by Colour and Modify Things: its own material comes back
		# (with the current rotation), the colours stay.
		src.set_shader_param("texture_rotation", float(rot) if rot != null else 0.0)
		node.material = src
		return
	node.call("SetOptions", tex, node.color, float(rot) if rot != null else 0.0)


# Public (also used by the test harness): pushes every uniform for cfg.
func update_material(mat: ShaderMaterial, poly: PoolVector2Array, cfg: Dictionary, st: Dictionary) -> void:
	var tex = mat.get_shader_param("albedo")
	if tex == null or not (tex is Texture):
		return
	var info = analyze_texture(tex)
	var mode = int(cfg.get("mode", MODE_FILL))
	mat.set_shader_param("roof_mode", mode)
	mat.set_shader_param("band_start", info["band_start"])
	# Repeat Point: moves where the repeated band of the texture wraps.
	var band = clamp(info["band"] + float(cfg.get("repeat", 0.0)), 8.0, max(info["h"] - info["band_start"], 8.0))
	mat.set_shader_param("band", band)
	mat.set_shader_param("edge_shift", info["empty"] + float(cfg.get("edge", 0.0)))
	mat.set_shader_param("fade", info.get("fade", 0.0))
	mat.set_shader_param("body_end", info.get("body_end", info["h"]))
	mat.set_shader_param("eave_band", max(info["h"] - info["empty"] - float(cfg.get("edge", 0.0)) - info.get("body_end", info["h"]), 0.0))
	# Softer Seams: width (texels) of the blend across ridges / hip lines.
	var seams = int(cfg.get("seams", SEAMS_SOFT))
	var caps_ok = mode == MODE_HIP or (mode == MODE_FILL and bool(cfg.get("mirror", false)))
	# Ridge Caps where there are none: soft seams.
	if seams == SEAMS_CAPS and not caps_ok:
		seams = SEAMS_SOFT
	var soft = max(16.0, info["h"] * 0.035) if seams >= SEAMS_SOFT else 0.0
	mat.set_shader_param("seam_lines", seams != SEAMS_NONE)
	mat.set_shader_param("seam_soft", soft)
	mat.set_shader_param("tex_scale", _tex_scale(cfg))
	mat.set_shader_param("side_ink", bool(cfg.get("side_ink", true)))
	mat.set_shader_param("ridge_caps", seams == SEAMS_CAPS)
	mat.set_shader_param("cap_outline", int(cfg.get("cap_outline", 1)))
	mat.set_shader_param("cap_corner", int(cfg.get("cap_corners", 1)))
	mat.set_shader_param("tip_len", clamp(float(cfg.get("cap_tip", 35.0)), -300.0, 200.0) / 100.0)
	var rends = int(cfg.get("ridge_ends", 0))
	mat.set_shader_param("cap_ridge_top", rends == 1)
	mat.set_shader_param("cap_fade", clamp(float(cfg.get("cap_fade", 15.0)), 0.0, 100.0) / 100.0 if rends == 0 else 0.0)
	# Cap Brightness -100..100 %: gamma 2 .. 0.5.
	# Cap Brightness -100..100 %: gamma 4 .. 0.25.
	# (only with Cap Recolor on)
	var rc = bool(cfg.get("cap_recolor", false))
	mat.set_shader_param("cap_tone_on", int(cfg.get("cap_recolor_on", 2)))
	mat.set_shader_param("cap_gamma", pow(4.0, -clamp(float(cfg.get("cap_bright", 0.0)), -100.0, 100.0) / 100.0) if rc else 1.0)
	mat.set_shader_param("cap_hue", clamp(float(cfg.get("cap_hue", 0.0)), -180.0, 180.0) / 360.0 if rc else 0.0)
	# Cap Saturation -100..100 %: grey .. twice as saturated.
	mat.set_shader_param("cap_sat", 1.0 + clamp(float(cfg.get("cap_sat", 0.0)), -100.0, 100.0) / 100.0 if rc else 1.0)
	mat.set_shader_param("cap_scale", clamp(float(cfg.get("cap_width", 100.0)), 10.0, 500.0) / 100.0)
	mat.set_shader_param("cap_scale_hip", clamp(float(cfg.get("cap_width_hip", cfg.get("cap_width", 100.0))), 10.0, 500.0) / 100.0)
	# Cap width from the tile rows (textures without rows: a quarter of the
	# texture height at most).
	var crh = float(info.get("row_h", info["h"]))
	if crh >= info["h"] * 0.9:
		# No tile rows found (thatch...).
		crh = min(info["h"] * 0.25, 80.0)
	var tn = float(info.get("tile_n", 0.0))
	var cstyle = int(cfg.get("cap_style", 0))
	var pieces = _roof_pieces(mat.get_shader_param("albedo"))
	var has_pieces = pieces.has("ridge") and pieces.has("hip")
	if cstyle == CAP_PATH:
		# Path Tool textures (the hip one: the ridge's when not set). Missing
		# (pack not loaded...): back to Auto.
		var prt = _path_tex(str(cfg.get("cap_path_ridge", "")))
		var pht = _path_tex(str(cfg.get("cap_path_hip", "")))
		if prt == null:
			prt = pht
		if pht == null:
			pht = prt
		if prt != null:
			pieces = {"ridge": prt, "hip": pht}
			has_pieces = true
			cstyle = 3
		else:
			cstyle = 0
	if cstyle == 3 and not has_pieces:
		cstyle = 0
	if cstyle == 0 and has_pieces:
		cstyle = 3
	if cstyle == 3:
		mat.set_shader_param("cap_ridge_tex", pieces["ridge"])
		mat.set_shader_param("cap_hip_tex", pieces["hip"])
		mat.set_shader_param("cap_ridge_vis", _strip_vis(pieces["ridge"]))
		mat.set_shader_param("cap_hip_vis", _strip_vis(pieces["hip"]))
		mat.set_shader_param("cap_ridge_ink", _strip_ink(pieces["ridge"]))
		mat.set_shader_param("cap_hip_ink", _strip_ink(pieces["hip"]))
	if cstyle == 0:
		# Auto: narrow single tiles (half-round tiles...) are turned along the
		# line, anything else (slates, bricks, thatch...) laid as a band.
		cstyle = 1 if tn > 0.0 and info["w"] / tn <= crh * 1.2 else 2
	mat.set_shader_param("cap_style", cstyle)
	mat.set_shader_param("ink_h", _ink_h(info))
	# Cap width base: one tile (turned tiles) or one course (band).
	var cbase = min(info["w"] / tn if cstyle == 1 and tn > 0.0 else crh, 128.0)
	if cstyle == 3:
		cbase = float(pieces["ridge"].get_height())
	mat.set_shader_param("cap_base", cbase)
	# The texture draws its own eave edge (transparent rows under the tiles).
	mat.set_shader_param("eave_cut", info.get("body_end", info["h"]) < info["h"] - 0.5)
	mat.set_shader_param("row_h", info.get("row_h", info["h"]))
	mat.set_shader_param("row_y0", info.get("row_y0", 0.0))
	mat.set_shader_param("tile_n", info.get("tile_n", 0.0))
	_set_light(mat, cfg, st)
	_set_merge(mat, cfg, st)
	mat.set_shader_param("merge_raise", float(cfg.get("merge_height", 0.0)))
	# Merge settings (cog): junction line, valley shadow opacity and width.
	mat.set_shader_param("valley_w", max(_valley_w(_ink_h(info)) * float(cfg.get("valley_width", 100.0)) / 100.0, 1.0))
	mat.set_shader_param("valley_strength", clamp(float(cfg.get("valley_opacity", 35.0)) / 100.0, 0.0, 1.0))
	mat.set_shader_param("junction_ink", max(float(cfg.get("valley_line", 100.0)) / 100.0, 0.0))
	mat.set_shader_param("own_vis", _vis_offset(info, cfg))
	if mode == MODE_CENTER:
		_update_round(mat, poly, cfg, info, st)
	elif mode == MODE_HIP:
		_update_hip(mat, poly, cfg, info, st)
	else:
		_update_fill(mat, poly, cfg, info)
		_set_edges(mat, poly, _area_centroid(poly), st)


# Distance (texels, like t) from the shape outline to the visible eave.
func _vis_offset(info: Dictionary, cfg: Dictionary) -> float:
	var shift = info["empty"] + float(cfg.get("edge", 0.0))
	return max(info["h"] - shift - info.get("vis_end", info["h"]), 0.0)


var _profile_cache = {}
var _profile_lens = {}


# Slope length of a profile, in shape radii (see profile_len in the shader).
func _profile_len(kind: int, curve: float) -> float:
	_profile_tex(kind, curve)
	return float(_profile_lens.get("%d_%d" % [kind, int(round(clamp(curve, 0.0, 100.0)))], 1.0))


# Centered roofs, Profile: lookup table (see profile_lut in the shader).
# Height z of the slope at radius share rho (0 top, 1 eave), top at z = h.
# curve (0..100, 50 = default): how steep the slope gets at the eave; higher
# = rows packed tighter there.
func _profile_tex(kind: int, curve: float = 50.0) -> ImageTexture:
	curve = clamp(curve, 0.0, 100.0)
	var key = "%d_%d" % [kind, int(round(curve))]
	if _profile_cache.has(key):
		return _profile_cache[key]
	# Dome: 1 - k r², k = 0.92 at 0, 0.992 at 50, 0.9992 at 100.
	var dk = 1.0 - 0.008 * pow(10.0, (50.0 - curve) / 50.0)
	# Spire: flare exponent 0.45 at 50 (0.15 .. 1.35).
	var be = 0.45 * pow(3.0, (curve - 50.0) / 50.0)
	var n = 1024
	var rho = []
	var z = []
	for i in range(n + 1):
		var r = float(i) / n
		var zz = 0.0
		match kind:
			PROFILE_DOME:
				# Not quite vertical at the eave (rows there would get too thin).
				zz = sqrt(max(1.0 - r * r * dk, 0.0))
			PROFILE_LOW_DOME:
				zz = 0.5 * sqrt(max(1.0 - r * r * dk, 0.0))
			PROFILE_ONION:
				# Onion: round shoulder like a dome, then a concave spike
				# up to a pointed top.
				zz = 0.6 * sqrt(max(1.0 - r * r * r * r * dk, 0.0)) + 0.8 * pow(1.0 - r, 5.0)
			_:
				# Spire: steep near the eave, pointed top.
				zz = 0.9 * pow(1.0 - r, 0.6) * pow(max(1.0 - r * r, 0.0), be)
		rho.append(r)
		z.append(zz)
	# Rows along the slope from the eave (rho = 1) up. Where the slope is
	# flat the rows keep the width they have on a stretched cone; where it
	# is steep (rows seen squeezed) extra rows are added: each stretch of
	# slope counts its length times its steepness^(gamma - 1).
	var arc = []
	arc.resize(n + 1)
	arc[n] = 0.0
	var length = 0.0
	for i in range(n - 1, -1, -1):
		var gamma = PROFILE_ROW_GAMMA
		if kind == PROFILE_SPIRE:
			# Spire: wide rows on the sides, many more toward the point.
			gamma = lerp(PROFILE_ROW_GAMMA_SPIRE, 1.0, smoothstep(0.35, 0.8, rho[i]))
		var seg = Vector2(rho[i + 1] - rho[i], z[i + 1] - z[i]).length()
		length += seg
		# (capped: near-vertical slopes would get rows thinner than a pixel)
		arc[i] = arc[i + 1] + seg * pow(min(seg * n, 6.0), gamma - 1.0)
	var total = max(arc[0], 0.000001)
	var cone_n = sin(deg2rad(40.0))
	var img = Image.new()
	img.create(PROFILE_LUT_N, 1, false, Image.FORMAT_RGBAF)
	img.lock()
	# Inverse lookup walks the slope once (u only grows).
	var j = 0
	for k in range(PROFILE_LUT_N):
		var u = float(k) / (PROFILE_LUT_N - 1)
		# Cone share u <-> radius share 1 - u.
		var fi = clamp((1.0 - u) * n, 0.0, n - 1.0)
		var i0 = int(fi)
		var a = lerp(arc[i0], arc[i0 + 1], fi - i0) / total
		var sl = abs(z[i0 + 1] - z[i0]) * n
		var nh = sl / sqrt(1.0 + sl * sl)
		# Inverse: radius share where the slope length share is u.
		while j < n and arc[n - j - 1] / total < u:
			j += 1
		var a0 = arc[n - j] / total
		var a1 = arc[max(n - j - 1, 0)] / total
		var inv = (float(j) + (clamp((u - a0) / max(a1 - a0, 0.000001), 0.0, 1.0) if j < n else 0.0)) / n
		img.set_pixel(k, 0, Color(a, clamp(nh / cone_n, 0.0, 1.6), clamp(inv, 0.0, 1.0), 1.0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	_profile_cache[key] = tex
	_profile_lens[key] = total / max(length, 0.000001)
	return tex


# Size of ink lines and seam shadows: the tile row height, or a fixed share of
# the texture when it has no rows (thatch, hay: the "row" would be the whole
# texture, giving huge lines).
func _ink_h(info: Dictionary) -> float:
	var rh = float(info.get("row_h", info["h"]))
	if rh >= info["h"] * 0.9:
		rh = min(info["h"] * 0.25, 80.0)
	return clamp(rh, 1.0, 128.0)


# Width of the valley shadow of merged roofs (world px), from the tile row height.
func _valley_w(row_h: float) -> float:
	return min(max(row_h, 1.0) * 0.64, 84.0)


func _set_merge(mat: ShaderMaterial, cfg: Dictionary, st: Dictionary) -> void:
	var m = st.get("merge")
	if not bool(cfg.get("merge", false)) or m == null:
		mat.set_shader_param("merge_on", false)
		return
	# Old single-partner form (test harness).
	var lst = m["list"] if m.has("list") else [m]
	var rows = []
	var width = LUT_N
	for e in lst:
		var poly: PoolVector2Array = e["poly"]
		var ptex = e.get("tex")
		if poly.size() < 3 or ptex == null or not (ptex is Texture):
			continue
		width = int(max(width, min(poly.size(), MAX_EDGES)))
		rows.append(e)
	if rows.empty():
		mat.set_shader_param("merge_on", false)
		return
	var img = Image.new()
	img.create(width, rows.size() * 5, false, Image.FORMAT_RGBAF)
	img.lock()
	var cost = 0.0
	for pi in range(rows.size()):
		var e = rows[pi]
		var pcfg = _full_cfg(e["cfg"])
		var poly: PoolVector2Array = e["poly"]
		var n = int(min(poly.size(), MAX_EDGES))
		var pinfo = analyze_texture(e["tex"])
		var pmode = int(pcfg["mode"])
		var xf: Transform2D = e["xf"]
		var r0 = pi * 5
		var pitch = clamp(float(pcfg.get("pitch", 0.0)), 0.0, 80.0)
		var pscale = 1.0 / cos(deg2rad(pitch))
		var center = Vector2.ZERO
		var ref_d = 0.0
		var star = 0.0
		if pmode == MODE_CENTER:
			var apex = null
			if bool(pcfg.get("apex_on", false)):
				apex = _apex_for(poly, pcfg, e.get("pxf"))
			var data = build_round_lut(poly, apex)
			if not data.empty():
				center = data["center"]
				ref_d = data["ref_d"]
				star = 1.0 if data["star"] else 0.0
				var li = data["image"]
				li.lock()
				for k in range(LUT_N):
					img.set_pixel(k, r0 + 1, Color(li.get_pixel(k, 0).r, 0.0, 0.0, 0.0))
				li.unlock()
		var size = Vector2(pinfo["w"], pinfo["h"])
		var rot = float(e.get("rot", 0.0))
		var vmax = 0.0
		var vmin = 0.0
		if pmode == MODE_FILL:
			vmax = -INF
			vmin = INF
			for p in poly:
				var uv = _rotate_uv(p / size, rot)
				vmax = max(vmax, uv.y)
				vmin = min(vmin, uv.y)
		img.set_pixel(0, r0, Color(float(pmode), float(n), 1.0 if bool(pcfg.get("mirror", false)) else 0.0, _vis_offset(pinfo, pcfg)))
		img.set_pixel(1, r0, Color(xf.x.x, xf.x.y, xf.y.x, xf.y.y))
		img.set_pixel(2, r0, Color(xf.origin.x, xf.origin.y, center.x, center.y))
		img.set_pixel(3, r0, Color(ref_d, pscale, rot, star))
		if star > 0.5:
			cost += 8.0
		else:
			cost += float(n) * (3.0 if pmode == MODE_HIP else 1.0) + 8.0
		img.set_pixel(4, r0, Color(size.x, size.y, vmax, vmin))
		var pre = _round_ends(poly, size, rot, pcfg) if pmode == MODE_FILL else [false, false, 0.0, 0.0, 1.0]
		img.set_pixel(5, r0, Color((1.0 if pre[0] else 0.0) + (2.0 if pre[1] else 0.0), pre[2], pre[3], pre[4]))
		var ei = _edges_image(poly, n)
		ei.lock()
		for i in range(n):
			for r in range(3):
				img.set_pixel(i, r0 + 2 + r, ei.get_pixel(i, r))
		ei.unlock()
	img.unlock()
	var dtex = st.get("merge_tex")
	if dtex == null:
		dtex = ImageTexture.new()
		st["merge_tex"] = dtex
	dtex.create_from_image(img, 0)
	mat.set_shader_param("merge_on", true)
	mat.set_shader_param("merge_data", dtex)
	mat.set_shader_param("merge_count", rows.size())
	mat.set_shader_param("merge_lut_n", LUT_N)
	st["merge_cost"] = cost


func _set_light(mat: ShaderMaterial, cfg: Dictionary, st: Dictionary = {}) -> void:
	var pitch = clamp(float(cfg.get("pitch", 0.0)), 0.0, 80.0)
	mat.set_shader_param("pitch_scale", 1.0 / cos(deg2rad(pitch)))
	var strength = float(cfg.get("shade", 0.0))
	var angle = float(cfg.get("light", 315.0))
	var gl = _global_light()
	if gl["on"]:
		strength = gl["shade"]
		angle = gl["light"]
	# 100 % = the shading that 75 % used to give.
	var shade = clamp(strength, 0.0, 1.0) * 0.75 if bool(cfg.get("shade_on", true)) else 0.0
	mat.set_shader_param("shade", shade)
	# Light angle on the map: 0° = from the top, clockwise. light_dir points
	# toward the light, turned into the shape's own space so moving or
	# rotating the shape never turns its shadows.
	var light = deg2rad(angle)
	var dir = Vector2(sin(light), -cos(light))
	var xf = st.get("xform")
	if xf is Transform2D:
		var local = xf.affine_inverse().basis_xform(dir)
		if local.length() > 0.000001:
			dir = local.normalized()
	mat.set_shader_param("light_dir", dir)


# Global Lighting (one light for every roof of the map, saved with the map).
func _global_light() -> Dictionary:
	var out = {"on": false, "shade": float(DEFAULT_CFG["shade"]), "light": float(DEFAULT_CFG["light"])}
	if _g == null or not (_g.get("ModMapData") is Dictionary):
		return out
	var d = _g.ModMapData.get(GLOBAL_KEY)
	if d is Dictionary:
		out["on"] = bool(d.get("on", false))
		out["shade"] = float(d.get("shade", out["shade"]))
		out["light"] = float(d.get("light", out["light"]))
	return out


func _set_global_light(fields: Dictionary) -> void:
	if _g == null or not (_g.get("ModMapData") is Dictionary):
		return
	var d = _global_light()
	for k in fields.keys():
		d[k] = fields[k]
	_g.ModMapData[GLOBAL_KEY] = d
	_light_hash = hash(d)


# Tile Width: 100% = DD's own size. Stretches the tiles sideways only (the
# row height stays the texture's), not the shape.
func _tex_scale(cfg: Dictionary) -> float:
	return clamp(float(cfg.get("scale", 100.0)), 10.0, 1000.0) / 100.0


func _update_fill(mat: ShaderMaterial, poly: PoolVector2Array, cfg: Dictionary, info: Dictionary) -> void:
	var size = Vector2(info["w"], info["h"])
	var rot_v = mat.get_shader_param("rotation")
	var rot = float(rot_v) if rot_v != null else 0.0
	var v_max = -INF
	var v_min = INF
	for p in poly:
		var uv = _rotate_uv(p / size, rot)
		v_max = max(v_max, uv.y)
		v_min = min(v_min, uv.y)
	if v_max == -INF:
		v_max = 0.0
		v_min = 0.0
	mat.set_shader_param("v_max", v_max)
	mat.set_shader_param("v_min", v_min)
	mat.set_shader_param("mirror", bool(cfg.get("mirror", false)))
	# Far slope = near slope turned 180°, shifted by a fraction of a tile so
	# the two sides do not meet in a perfect mirror at the ridge.
	mat.set_shader_param("ridge_offset", float(cfg.get("ridge_offset", 0.0)) / 100.0)
	mat.set_shader_param("u_offset", float(cfg.get("u_offset", 0.0)) / 100.0)
	var re = _round_ends(poly, size, rot, cfg)
	mat.set_shader_param("round_start", re[0])
	mat.set_shader_param("round_end", re[1])
	mat.set_shader_param("round_x0", re[2])
	mat.set_shader_param("round_x1", re[3])
	mat.set_shader_param("round_a", re[4])


# Round Ends (Gap Free + Two Slopes): [start on, end on, centre of the start
# round end, centre of the end one (texels along the ridge, texture space),
# length of the round ends along the ridge].
func _round_ends(poly: PoolVector2Array, size: Vector2, rot: float, cfg) -> Array:
	var ends = int(cfg.get("round_ends", 0)) if bool(cfg.get("mirror", false)) else 0
	if ends <= 0 or poly.size() < 3:
		return [false, false, 0.0, 0.0, 1.0]
	var xmin = INF
	var xmax = -INF
	var ymin = INF
	var ymax = -INF
	for p in poly:
		var b = _rotate_uv(p / size, rot) * size
		xmin = min(xmin, b.x)
		xmax = max(xmax, b.x)
		ymin = min(ymin, b.y)
		ymax = max(ymax, b.y)
	# Half ellipses inside the shape: as long as the half width of the roof
	# (a half cone), shorter on a short roof so they are never cut.
	var r = (ymax - ymin) * 0.5
	var a = min(r, (xmax - xmin) * (0.5 if ends == 3 else 1.0))
	a = max(a, 0.001)
	return [ends == 1 or ends == 3, ends >= 2, xmin + a, xmax - a, a]


func _update_round(mat: ShaderMaterial, poly: PoolVector2Array, cfg: Dictionary, info: Dictionary, st: Dictionary) -> void:
	var apex = null
	if bool(cfg.get("apex_on", false)):
		apex = _apex_for(poly, cfg, st.get("xform"))
	var data = build_round_lut(poly, apex)
	if data.empty():
		return
	var lut = st.get("lut")
	if lut == null:
		lut = ImageTexture.new()
		st["lut"] = lut
	lut.create_from_image(data["image"], 0)
	var taper = bool(cfg.get("taper", true))
	var perimeter = data["perimeter"]
	var base = max(1.0, perimeter / max(info["w"] * _tex_scale(cfg), 1.0))
	mat.set_shader_param("lut", lut)
	mat.set_shader_param("lut_n", LUT_N)
	mat.set_shader_param("center", data["center"])
	mat.set_shader_param("columns", base)
	mat.set_shader_param("perimeter", perimeter)
	# Rows are spaced for the longest side: on the other sides they get
	# closer together (steeper), never stretched.
	mat.set_shader_param("ref_d", data["ref_d"])
	mat.set_shader_param("row_h", info.get("row_h", info["h"]))
	mat.set_shader_param("row_y0", info.get("row_y0", 0.0))
	mat.set_shader_param("tile_n", info.get("tile_n", 0.0))
	mat.set_shader_param("taper", taper)
	var prof = int(cfg.get("profile", PROFILE_CONE))
	mat.set_shader_param("profile_on", prof != PROFILE_CONE)
	if prof != PROFILE_CONE:
		mat.set_shader_param("profile_lut", _profile_tex(prof, float(cfg.get("curve", 50.0))))
		mat.set_shader_param("profile_len", _profile_len(prof, float(cfg.get("curve", 50.0))))
	mat.set_shader_param("smooth_shape", data["smooth"])
	mat.set_shader_param("star_shape", data["star"])
	mat.set_shader_param("apex_moved", apex != null)
	_set_edges(mat, poly, data["center"], st)


# Hip roof: every edge is an eave, tile rows run parallel to the nearest edge.
# A rectangle gets a ridge along its length, a square becomes a pyramid.
func _update_hip(mat: ShaderMaterial, poly: PoolVector2Array, _cfg: Dictionary, _info: Dictionary, st: Dictionary) -> void:
	_set_edges(mat, poly, _area_centroid(poly), st)


# Edge table rows 0-2 (see _set_edges), also used for a merged roof.
func _edges_image(poly: PoolVector2Array, n: int) -> Image:
	var area = 0.0
	for i in range(n):
		area += poly[i].cross(poly[(i + 1) % n])
	var sgn = 1.0 if area >= 0.0 else -1.0
	var dirs = []
	for i in range(n):
		dirs.append((poly[(i + 1) % n] - poly[i]).normalized())
	var img = Image.new()
	img.create(n, 3, false, Image.FORMAT_RGBAF)
	img.lock()
	for i in range(n):
		var a = poly[i]
		var b = poly[(i + 1) % n]
		var d_prev = dirs[(i - 1 + n) % n]
		var d_this = dirs[i]
		var d_next = dirs[(i + 1) % n]
		var outn = Vector2(d_this.y, -d_this.x) * sgn
		var reflex_a = 1.0 if d_prev.cross(d_this) * sgn < -0.0001 else 0.0
		var reflex_b = 1.0 if d_this.cross(d_next) * sgn < -0.0001 else 0.0
		img.set_pixel(i, 0, Color(a.x, a.y, b.x, b.y))
		img.set_pixel(i, 1, Color(outn.x, outn.y, reflex_a, reflex_b))
		img.set_pixel(i, 2, Color(d_prev.x, d_prev.y, d_next.x, d_next.y))
	img.unlock()
	return img


# Edge table shared by Hip roofs and faceted Centered roofs.
# Row 0: a, b. Row 1: outward normal, reflex flags at a / b.
# Row 2: direction of the previous edge, direction of the next edge.
# Row 3: perpendicular distance from the top point to the edge line, then
# Ridge Caps data (part of a curved outline, S0, T': see _cap_runs).
# Rows 4-5 (Ridge Caps): lines ending at a curved part (see _cap_ends).
func _set_edges(mat: ShaderMaterial, poly: PoolVector2Array, apex: Vector2, st: Dictionary) -> void:
	var n = poly.size()
	if n < 3:
		mat.set_shader_param("edge_count", 0)
		return
	n = int(min(n, MAX_EDGES))
	var area = 0.0
	for i in range(n):
		area += poly[i].cross(poly[(i + 1) % n])
	var sgn = 1.0 if area >= 0.0 else -1.0
	var dirs = []
	var acc = 0.0
	for i in range(n):
		dirs.append((poly[(i + 1) % n] - poly[i]).normalized())
		acc += poly[i].distance_to(poly[(i + 1) % n])
	var nrm = []
	var lens = []
	for i in range(n):
		nrm.append(Vector2(dirs[i].y, -dirs[i].x) * sgn)
		lens.append(poly[i].distance_to(poly[(i + 1) % n]))
	var runs = _cap_runs(n, dirs, nrm, lens, sgn)
	var ends = _cap_ends(poly, n, dirs, nrm, sgn, runs["soft"], runs["tt"])
	var img = Image.new()
	img.create(n, 6, false, Image.FORMAT_RGBAF)
	img.lock()
	for i in range(n):
		var a = poly[i]
		var b = poly[(i + 1) % n]
		var d_prev = dirs[(i - 1 + n) % n]
		var d_this = dirs[i]
		var d_next = dirs[(i + 1) % n]
		var outn = nrm[i]
		var reflex_a = 1.0 if d_prev.cross(d_this) * sgn < -0.0001 else 0.0
		var reflex_b = 1.0 if d_this.cross(d_next) * sgn < -0.0001 else 0.0
		var apex_d = max((a - apex).dot(outn), 0.001)
		img.set_pixel(i, 0, Color(a.x, a.y, b.x, b.y))
		img.set_pixel(i, 1, Color(outn.x, outn.y, reflex_a, reflex_b))
		img.set_pixel(i, 2, Color(d_prev.x, d_prev.y, d_next.x, d_next.y))
		img.set_pixel(i, 3, Color(apex_d, runs["curved"][i], runs["s0"][i], runs["tp"][i]))
	for k in range(ends.size()):
		var e = ends[k]
		img.set_pixel(k, 4, Color(e[0], e[1], e[2].x, e[2].y))
		img.set_pixel(k, 5, Color(e[3].x, e[3].y, e[4], e[5]))
	img.unlock()
	var etex = st.get("edges")
	if etex == null:
		etex = ImageTexture.new()
		st["edges"] = etex
	etex.create_from_image(img, 0)
	mat.set_shader_param("edges", etex)
	mat.set_shader_param("edge_count", n)
	mat.set_shader_param("cap_ends", ends.size())
	st["perimeter"] = acc


# Ridge Caps on Hip roofs: runs of faces joined at small turns (curved
# outlines). Per face: part of such a run (1 / 0), and S0, T' such that a
# point of a ridge at depth d is at S0 + (along the face) - d * T' along the
# run, unbroken from one face to the next (ridge tiles follow curves).
func _cap_runs(n: int, dirs: Array, nrm: Array, lens: Array, sgn: float) -> Dictionary:
	var soft = []
	var tt = []
	for i in range(n):
		var ip = (i - 1 + n) % n
		var ok = nrm[ip].dot(nrm[i]) > CAP_SIM
		soft.append(ok)
		# tan(half the turn at the vertex), > 0 at outer corners.
		var turn = atan2(dirs[ip].cross(dirs[i]), dirs[ip].dot(dirs[i])) * sgn
		tt.append(tan(turn * 0.5) if ok else 0.0)
	var start = -1
	for i in range(n):
		if not soft[i]:
			start = i
			break
	if start < 0:
		# Curved all around: start where it turns the most.
		start = 0
		for i in range(n):
			if abs(tt[i]) > abs(tt[start]):
				start = i
	var curved = []
	var s0 = []
	var tp = []
	for i in range(n):
		curved.append(1.0 if soft[i] or soft[(i + 1) % n] else 0.0)
		s0.append(0.0)
		tp.append(0.0)
	var run = []
	var acc_s = 0.0
	var acc_t = 0.0
	for k in range(n + 1):
		var i = (start + k) % n
		if k == 0 or k == n or not soft[i]:
			# Close the run, centred on its middle.
			for j in run:
				s0[j] -= acc_s * 0.5
			run = []
			acc_s = 0.0
			acc_t = 0.0
			if k == n:
				break
		var ta = tt[i] if run.size() > 0 else 0.0
		tp[i] = acc_t + ta
		s0[i] = acc_s
		var nx = (i + 1) % n
		var tb = tt[nx] if soft[nx] and nx != start else 0.0
		acc_t += ta + tb
		acc_s += lens[i]
		run.append(i)
	return {"soft": soft, "tt": tt, "curved": curved, "s0": s0, "tp": tp}


# Ridge Caps on Hip roofs: lines ending where a curved part of the outline
# begins (round ends, rounded corners). The faces of a curved part all shrink
# to about one point (its centre); the faces on both sides of the curved part
# meet in a line that ends there. Each: [face, face, end point, direction
# from the end along the line, first and last face of the curved part].
func _cap_ends(poly: PoolVector2Array, n: int, dirs: Array, nrm: Array, sgn: float, soft: Array, tt: Array) -> Array:
	var out = []
	var pts = []
	var dep = []
	for i in range(n):
		pts.append(null)
		dep.append(0.0)
		var ip = (i - 1 + n) % n
		var inx = (i + 1) % n
		if soft[i] and soft[inx] and tt[i] > 0.0 and tt[inx] > 0.0:
			var p = _cap_junction(poly, nrm, ip, i, inx)
			if p != null:
				var d = (poly[i] - p).dot(nrm[i])
				if d > 0.0 and Geometry.is_point_in_polygon(p, poly):
					pts[i] = p
					dep[i] = d
	var first = -1
	for i in range(n):
		if pts[i] == null:
			first = i
			break
	if first < 0:
		return out
	# Curved parts: consecutive faces shrinking to about the same point.
	var groups = []
	var cur = []
	for k in range(1, n + 1):
		var i = (first + k) % n
		if pts[i] != null and cur.size() > 0:
			var l = cur[cur.size() - 1]
			if pts[i].distance_to(pts[l]) > 0.6 * min(dep[i], dep[l]):
				groups.append(cur)
				cur = []
		if pts[i] != null:
			cur.append(i)
		elif cur.size() > 0:
			groups.append(cur)
			cur = []
	for grp in groups:
		if grp.size() < 2 or out.size() >= MAX_CAP_ENDS:
			continue
		var x = (grp[0] - 1 + n) % n
		var y = (grp[grp.size() - 1] + 1) % n
		if x == y or nrm[x].dot(nrm[y]) > CAP_SIM:
			continue
		var mid = grp[grp.size() / 2]
		var p = _cap_junction(poly, nrm, x, y, mid)
		if p == null:
			continue
		var g = nrm[x] - nrm[y]
		var u = Vector2(-g.y, g.x).normalized()
		if u.dot(nrm[mid] - nrm[x]) > 0.0:
			u = -u
		# The line must run on from there, between these two faces.
		var q = p + u * max((poly[x] - p).dot(nrm[x]) * 0.2, 1.0)
		var near = _cap_nearest2(poly, n, dirs, nrm, sgn, q)
		if not ((near[0] == x and near[1] == y) or (near[0] == y and near[1] == x)):
			continue
		out.append([float(x), float(y), p, u, float(grp[0]), float(grp[grp.size() - 1])])
	return out


# Point at the same height on the planes of faces i, j and k (or null).
func _cap_junction(poly: PoolVector2Array, nrm: Array, i: int, j: int, k: int):
	var r1 = nrm[i] - nrm[j]
	var r2 = nrm[i] - nrm[k]
	var det = r1.x * r2.y - r1.y * r2.x
	if abs(det) < 0.000001:
		return null
	var hi = poly[i].dot(nrm[i])
	var c1 = hi - poly[j].dot(nrm[j])
	var c2 = hi - poly[k].dot(nrm[k])
	return Vector2(c1 * r2.y - c2 * r1.y, r1.x * c2 - r2.x * c1) / det


# The two faces nearest to v, as the Hip shader measures (hip_face_d).
func _cap_nearest2(poly: PoolVector2Array, n: int, dirs: Array, nrm: Array, sgn: float, v: Vector2) -> Array:
	var b1 = -1
	var b2 = -1
	var d1 = INF
	var d2 = INF
	for i in range(n):
		var a = poly[i]
		var b = poly[(i + 1) % n]
		var ab = b - a
		var h = (v - a).dot(ab) / max(ab.length_squared(), 0.000001)
		var d_prev = dirs[(i - 1 + n) % n]
		var d_next = dirs[(i + 1) % n]
		var ra = d_prev.cross(dirs[i]) * sgn < -0.0001
		var rb = dirs[i].cross(d_next) * sgn < -0.0001
		var inner = (v - a).dot(nrm[i]) <= 0.0
		var ext = (h >= 0.0 and h <= 1.0) \
			or (inner and h < 0.0 and ra and (v - a).dot(d_prev + dirs[i]) > 0.0) \
			or (inner and h > 1.0 and rb and (v - b).dot(dirs[i] + d_next) < 0.0)
		var d = INF
		if ext:
			d = abs((v - a).dot(nrm[i]))
		elif not ((h < 0.0 and ra) or (h > 1.0 and rb)):
			d = v.distance_to(a + ab * clamp(h, 0.0, 1.0))
		if d < d1:
			b2 = b1
			d2 = d1
			b1 = i
			d1 = d
		elif d < d2:
			b2 = i
			d2 = d
	return [b1, b2]


func _rotate_uv(uv: Vector2, r: float) -> Vector2:
	var mid = 0.5
	return Vector2(
		cos(r) * (uv.x - mid) + sin(r) * (uv.y - mid) + mid,
		cos(r) * (uv.y - mid) - sin(r) * (uv.x - mid) + mid)


# Custom top position: (ax, ay) in -1..1 relative to the shape's bounding box
# (0, 0 = box centre). Pulled back toward the centroid if it falls outside.
# Custom top position. Locked: measured on the map (the shape's box as seen
# on the map), so rotating the shape does not move the top around it.
# Unlocked: measured on the shape, the top turns with it.
func _apex_for(poly: PoolVector2Array, cfg: Dictionary, xf) -> Vector2:
	var ax = float(cfg.get("apex_x", 0.0))
	var ay = float(cfg.get("apex_y", 0.0))
	if not (xf is Transform2D) or not bool(cfg.get("apex_lock", false)):
		return apex_position(poly, ax, ay)
	var wp = PoolVector2Array()
	for p in poly:
		wp.append(xf.xform(p))
	return xf.affine_inverse().xform(apex_position(wp, ax, ay))


func apex_position(poly: PoolVector2Array, ax: float, ay: float) -> Vector2:
	if poly.size() < 3:
		return Vector2.ZERO
	var mn = poly[0]
	var mx = poly[0]
	for p in poly:
		mn = Vector2(min(mn.x, p.x), min(mn.y, p.y))
		mx = Vector2(max(mx.x, p.x), max(mx.y, p.y))
	var half = (mx - mn) * 0.5
	var target = (mn + mx) * 0.5 + Vector2(clamp(ax, -1.0, 1.0) * half.x, clamp(ay, -1.0, 1.0) * half.y)
	if Geometry.is_point_in_polygon(target, poly):
		return target
	var inside = _area_centroid(poly)
	if not Geometry.is_point_in_polygon(inside, poly):
		return target
	var outside = target
	for _i in range(12):
		var mid = (inside + outside) * 0.5
		if Geometry.is_point_in_polygon(mid, poly):
			inside = mid
		else:
			outside = mid
	return inside


# ── Centered roof lookup table ────────────────────────────────────────────────
# For LUT_N angles around the top point: row 0 = (radius to the outline,
# perpendicular distance of the hit edge, position along the outline 0..1),
# row 1 = outward normal of the hit edge (faceted shading).

# Memoized: the same outline and top give the same table (slider moves, light
# changes and every merged roof above reuse it).
func build_round_lut(poly: PoolVector2Array, apex = null) -> Dictionary:
	var ck = "%d|%s" % [hash(poly), str(apex)]
	if _lut_cache.has(ck):
		return _lut_cache[ck]
	if _lut_cache.size() > 128:
		_lut_cache.clear()
	var data = _build_round_lut(poly, apex)
	_lut_cache[ck] = data
	return data


func _build_round_lut(poly: PoolVector2Array, apex = null) -> Dictionary:
	var n = poly.size()
	if n < 3:
		return {}
	var center = _area_centroid(poly) if apex == null else apex
	var cum = [0.0]
	var perimeter = 0.0
	for i in range(n):
		perimeter += poly[i].distance_to(poly[(i + 1) % n])
		cum.append(perimeter)
	if perimeter <= 0.0:
		return {}
	var img = Image.new()
	img.create(LUT_N, 2, false, Image.FORMAT_RGBAF)
	img.lock()
	var last_r = 1.0
	var max_d = 0.0
	var star = true
	for k in range(LUT_N):
		var a = -PI + TAU * (float(k) + 0.5) / float(LUT_N)
		var dir = Vector2(cos(a), sin(a))
		var best_t = -1.0
		var best_e = -1
		var best_u = 0.0
		var min_t = INF
		for e in range(n):
			var pa = poly[e]
			var seg = poly[(e + 1) % n] - pa
			var denom = dir.cross(seg)
			if abs(denom) < 0.000000001:
				continue
			var w = pa - center
			var t = w.cross(seg) / denom
			var u = w.cross(dir) / denom
			if u < -0.000001 or u > 1.000001 or t <= 0.0:
				continue
			min_t = min(min_t, t)
			if t > best_t:
				best_t = t
				best_e = e
				best_u = u
		# The outline is crossed once in every direction: the radius table
		# alone tells what is inside (no polygon test needed).
		if best_e < 0 or best_t - min_t > 0.5:
			star = false
		var r_val = last_r
		var d_val = last_r
		var p_val = float(k) / float(LUT_N)
		var nrm = dir
		if best_e >= 0:
			var pa2 = poly[best_e]
			var pb2 = poly[(best_e + 1) % n]
			var seg2 = pb2 - pa2
			var sl = seg2.length()
			r_val = best_t
			p_val = (cum[best_e] + sl * clamp(best_u, 0.0, 1.0)) / perimeter
			d_val = abs(seg2.cross(center - pa2)) / sl if sl > 0.0 else r_val
			nrm = Vector2(seg2.y, -seg2.x).normalized()
			if nrm.dot((pa2 + pb2) * 0.5 - center) < 0.0:
				nrm = -nrm
		last_r = r_val
		max_d = max(max_d, d_val)
		img.set_pixel(k, 0, Color(r_val, d_val, fposmod(p_val, 1.0), 0.0))
		img.set_pixel(k, 1, Color(nrm.x, nrm.y, 0.0, 0.0))
	img.unlock()
	# Many points = a smooth outline (circle, ellipse, curves): no facets,
	# even with a moved top point.
	return {"image": img, "center": center, "perimeter": perimeter, "ref_d": max_d,
		"smooth": n >= SMOOTH_MIN_POINTS, "star": star}


func _area_centroid(poly: PoolVector2Array) -> Vector2:
	var n = poly.size()
	var a = 0.0
	var cx = 0.0
	var cy = 0.0
	for i in range(n):
		var p = poly[i]
		var q = poly[(i + 1) % n]
		var c = p.cross(q)
		a += c
		cx += (p.x + q.x) * c
		cy += (p.y + q.y) * c
	if abs(a) < 0.000001:
		var m = Vector2.ZERO
		for p in poly:
			m += p
		return m / float(max(n, 1))
	return Vector2(cx, cy) / (3.0 * a)


# ── Texture analysis ──────────────────────────────────────────────────────────
# Finds the opaque body of the texture (rows mostly opaque), the fully empty
# rows below the eave, and the vertical period of the tile rows so that the
# repeated band is a whole number of rows (no visible seam).

func analyze_texture(tex: Texture) -> Dictionary:
	var id = tex.get_instance_id()
	if _tex_info.has(id):
		return _tex_info[id]
	var w = float(tex.get_width())
	var h = float(tex.get_height())
	# Analyses are kept on disk between sessions (by texture file and size).
	var dkey = ""
	if tex.resource_path != "":
		dkey = "%s|%dx%d" % [tex.resource_path, int(w), int(h)]
	if dkey != "":
		var disk = _tex_disk()
		if disk.has(dkey) and disk[dkey] is Dictionary:
			var cached = {}
			for k in disk[dkey].keys():
				cached[k] = float(disk[dkey][k])
			_tex_info[id] = cached
			return cached
	var info = {"w": w, "h": h, "band_start": 0.0, "band": h, "empty": 0.0, "fade": 0.0, "row_h": h, "row_y0": 0.0, "tile_n": 0.0, "body_end": h, "vis_end": h}
	_tex_info[id] = info
	var ok = _analyze_into(tex, info)
	if ok and dkey != "":
		_tex_disk()[dkey] = info.duplicate()
		_save_tex_disk()
	return info


var _tex_disk_data = null
var _plain = null


# Texture of the plain colour pattern (X): white, coloured by the shape.
func _plain_tex() -> ImageTexture:
	if _plain == null:
		var img = Image.new()
		img.create(256, 256, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 1, 1, 1))
		_plain = ImageTexture.new()
		_plain.create_from_image(img, Texture.FLAG_REPEAT | Texture.FLAG_FILTER)
	return _plain
var _warm_state := 0      # 0: not done, 1..: frames since the warm-up draw, -1: done


# The roof shader is big: the graphics driver compiles it the first time it is
# drawn, which froze the first roof made. It is drawn once at start instead,
# in a tiny hidden viewport.
func _warm_shader() -> void:
	if _warm_state < 0 or _shader == null or _g == null or not (_g.World is Node) or not is_instance_valid(_g.World) or not _g.World.is_inside_tree():
		return
	var holder = _bake_holder(_g.World.get_tree())
	if _warm_state == 0:
		var vp = Viewport.new()
		vp.name = "Warm"
		vp.size = Vector2(4, 4)
		vp.transparent_bg = true
		vp.usage = Viewport.USAGE_2D
		vp.disable_3d = true
		vp.gui_disable_input = true
		vp.render_target_update_mode = Viewport.UPDATE_ONCE
		var p = Polygon2D.new()
		p.polygon = PoolVector2Array([Vector2(0, 0), Vector2(4, 0), Vector2(4, 4), Vector2(0, 4)])
		var m = ShaderMaterial.new()
		m.shader = _shader
		p.material = m
		vp.add_child(p)
		holder.add_child(vp)
	_warm_state += 1
	if _warm_state > 3:
		var vp = holder.get_node_or_null("Warm")
		if vp != null:
			vp.queue_free()
		_warm_state = -1


func _tex_disk() -> Dictionary:
	if _tex_disk_data == null:
		_tex_disk_data = {}
		var f = File.new()
		if f.file_exists(TEX_CACHE_PATH) and f.open(TEX_CACHE_PATH, File.READ) == OK:
			var res = JSON.parse(f.get_as_text())
			f.close()
			if res.error == OK and res.result is Dictionary and int(res.result.get("version", 0)) == TEX_CACHE_VERSION and res.result.get("textures") is Dictionary:
				_tex_disk_data = res.result["textures"]
	return _tex_disk_data


func _save_tex_disk() -> void:
	var f = File.new()
	if f.open(TEX_CACHE_PATH, File.WRITE) == OK:
		f.store_string(JSON.print({"version": TEX_CACHE_VERSION, "textures": _tex_disk_data}))
		f.close()


# Returns false when the texture could not be read (nothing kept on disk).
func _analyze_into(tex: Texture, info: Dictionary) -> bool:
	var w = info["w"]
	var h = info["h"]
	var t0 = OS.get_ticks_msec()
	var img = tex.get_data()
	if img == null or img.is_empty():
		return false
	if img.is_compressed():
		if img.decompress() != OK:
			return false
	img.convert(Image.FORMAT_RGBA8)
	info["tile_n"] = _detect_tiles_across(img)
	var ih = img.get_height()
	if ih < 16:
		return true
	var sc = h / float(ih)
	img.resize(ANALYSIS_COLUMNS, ih, Image.INTERPOLATE_BILINEAR)
	var alpha = PoolRealArray()
	alpha.resize(ih)
	var grid = PoolRealArray()
	grid.resize(ih * ANALYSIS_COLUMNS)
	# Raw RGBA8 bytes: much faster than get_pixel.
	var px = img.get_data()
	var k3 = 1.0 / (3.0 * 255.0 * 255.0)
	var i = 0
	for y in range(ih):
		var sa = 0
		for x in range(ANALYSIS_COLUMNS):
			var a = px[i + 3]
			sa += a
			grid[y * ANALYSIS_COLUMNS + x] = float(px[i] + px[i + 1] + px[i + 2]) * a * k3
			i += 4
		alpha[y] = float(sa) / (255.0 * ANALYSIS_COLUMNS)
	# Visible edge of the eave: the lowest row that is at least half opaque
	# (used to merge roofs on what is actually drawn).
	var vis = ih
	while vis > 0 and alpha[vis - 1] < 0.5:
		vis -= 1
	info["vis_end"] = float(vis) * sc
	# Strict opacity first (a half-transparent first/last row inside the
	# repeated band shows as a thin line), lenient fallback for textures
	# that are slightly translucent everywhere.
	var body_start = 0
	var body_end = ih
	for threshold in [0.99, 0.9]:
		body_start = 0
		while body_start < ih and alpha[body_start] < threshold:
			body_start += 1
		body_end = ih
		while body_end > body_start and alpha[body_end - 1] < threshold:
			body_end -= 1
		if body_end - body_start >= 8:
			break
	if body_end - body_start < 8:
		return true
	var rows = _detect_rows(grid, body_start, body_end)
	if rows[0] > 0.0:
		info["row_h"] = rows[0] * sc
		info["row_y0"] = rows[1] * sc
	if body_start == 0 and body_end == ih:
		# Fully opaque texture: plain tiling, nothing to fix.
		return true
	var empty = 0
	while empty < ih and alpha[ih - 1 - empty] < 0.02:
		empty += 1
	var span = body_end - body_start
	var fade = int(max(8, round(ih * 0.025)))
	var band = span
	if span > fade * 3:
		band = _find_band(grid, body_start, span, fade)
	else:
		fade = 0
	info["band_start"] = float(body_start) * sc
	info["body_end"] = float(body_end) * sc
	info["band"] = float(band) * sc
	info["empty"] = float(empty) * sc
	info["fade"] = float(fade) * sc
	print("[BetterRoofPatterns] Texture analysed: %dx%d, body %d-%d, band %d, fade %d, empty %d, rows %.2f @ %.0f, %d tiles across (%d ms)" % [int(w), int(h), body_start, body_end, band, fade, empty, rows[0], rows[1], int(info["tile_n"]), OS.get_ticks_msec() - t0])
	return true


# Repeat height: the band [s, s + L) is tiled, so row s + L must look like
# row s (that is where the wrap happens). Every L is tested by comparing the
# rows just below s with the rows just below s + L, pixel by pixel (this also
# catches staggered rows and odd row heights), and the best match wins; among
# near-equal matches the tallest band is kept (less visible repetition).
# The remaining difference is hidden by a cross-fade of `fade` rows.
func _find_band(grid: PoolRealArray, s: int, span: int, fade: int) -> int:
	var cols = ANALYSIS_COLUMNS
	var l_min = int(max(int(span * 0.35), fade + 4))
	var l_max = span - fade
	if l_max <= l_min:
		return span
	# Coarse pass: 8 rows of the fade zone, every other column.
	var ks = []
	for i in range(8):
		ks.append(int(round(float(i) * float(fade - 1) / 7.0)))
	var scored = []
	for l in range(l_min, l_max + 1):
		var err = 0.0
		for k in ks:
			var ra = (s + k) * cols
			var rb = (s + l + k) * cols
			var x = 0
			while x < cols:
				var d = grid[ra + x] - grid[rb + x]
				err += d * d
				x += 2
		scored.append([err, l])
	scored.sort_custom(self, "_sort_by_first")
	# Fine pass on the best candidates: every row of the fade zone.
	var best_err = INF
	var fine = []
	for i in range(min(8, scored.size())):
		var l = scored[i][1]
		var err = 0.0
		for k in range(fade):
			var ra = (s + k) * cols
			var rb = (s + l + k) * cols
			for x in range(cols):
				var d = grid[ra + x] - grid[rb + x]
				err += d * d
		fine.append([err, l])
		best_err = min(best_err, err)
	var band = span
	var best_l = -1
	for f in fine:
		if f[0] <= best_err * 1.15 and f[1] > best_l:
			best_l = f[1]
	if best_l > 0:
		band = best_l
	return band


# Number of tiles across the texture (horizontal period), 0 if none found
# (thatch...). Circular autocorrelation of opaque rows (the texture tiles
# sideways); the smallest tile among the strong local maxima wins.
func _detect_tiles_across(src: Image) -> float:
	var img = src.duplicate()
	var cw = 256
	var ch = 16
	img.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
	var rows = []
	var px = img.get_data()
	var k3 = 1.0 / (3.0 * 255.0 * 255.0)
	for y in range(ch):
		var line = PoolRealArray()
		line.resize(cw)
		var sa = 0
		var mean = 0.0
		var i = y * cw * 4
		for x in range(cw):
			var a = px[i + 3]
			sa += a
			line[x] = float(px[i] + px[i + 1] + px[i + 2]) * a * k3
			mean += line[x]
			i += 4
		if float(sa) / (255.0 * cw) < 0.99:
			continue
		mean /= float(cw)
		for x in range(cw):
			line[x] -= mean
		rows.append(line)
	if rows.empty():
		return 0.0
	var variance = 0.0
	for line in rows:
		for x in range(cw):
			variance += line[x] * line[x]
	variance /= float(rows.size() * cw)
	if variance < 0.00000001:
		return 0.0
	# Circular autocorrelation at every whole lag once (lines doubled: no
	# modulo); fractional lags are blended from the two around them.
	var ac = PoolRealArray()
	ac.resize(cw / 2 + 2)
	for li in range(cw / 2 + 2):
		ac[li] = 0.0
	var need = {}
	for n in range(2, 65):
		var li = int(floor(float(cw) / float(n)))
		need[li] = true
		need[li + 1] = true
	for line in rows:
		var dbl = PoolRealArray(line)
		dbl.append_array(line)
		for li in need.keys():
			var acc = 0.0
			for x in range(cw):
				acc += dbl[x] * dbl[x + li]
			ac[li] += acc
	var scores = {}
	var best = -INF
	for n in range(2, 65):
		var lag = float(cw) / float(n)
		var li = int(floor(lag))
		var f = lag - float(li)
		var acc = ac[li] * (1.0 - f) + ac[li + 1] * f
		var sc = acc / float(rows.size() * cw) / variance
		scores[n] = sc
		best = max(best, sc)
	var found = 0
	for n in range(2, 65):
		var sc = scores[n]
		if sc < 0.4 or sc < best * 0.85:
			continue
		if n > 2 and scores[n - 1] > sc:
			continue
		if n < 64 and scores[n + 1] > sc:
			continue
		found = n
	return float(found)


# Height of one course of tiles (row-averaged autocorrelation: staggered rows
# count as separate courses) and the texture row of a course edge (the
# darkest line, i.e. the shadow under the overlapping course).
# Returns [row height, edge row] or [-1, 0].
func _detect_rows(grid: PoolRealArray, s: int, e: int) -> Array:
	var n = e - s
	if n < 32:
		return [-1.0, 0.0]
	var cols = ANALYSIS_COLUMNS
	var lum = PoolRealArray()
	lum.resize(n)
	var mean = 0.0
	for i in range(n):
		var acc = 0.0
		for x in range(cols):
			acc += grid[(s + i) * cols + x]
		lum[i] = acc / float(cols)
		mean += lum[i]
	mean /= float(n)
	var variance = 0.0
	for i in range(n):
		lum[i] -= mean
		variance += lum[i] * lum[i]
	variance /= float(n)
	if variance < 0.00000001:
		return [-1.0, 0.0]
	var n4 = n / 4
	var p4 = PoolRealArray()
	p4.resize(n4)
	var var4 = 0.0
	for i in range(n4):
		p4[i] = (lum[i * 4] + lum[i * 4 + 1] + lum[i * 4 + 2] + lum[i * 4 + 3]) * 0.25
		var4 += p4[i] * p4[i]
	var4 /= float(max(n4, 1))
	if var4 < 0.00000001:
		return [-1.0, 0.0]
	var coarse = -1
	var c_prev = _corr(p4, 2, var4)
	var c_cur = _corr(p4, 3, var4)
	for lag in range(3, n4 / 2):
		var c_next = _corr(p4, lag + 1, var4)
		if c_cur > 0.5 and c_cur >= c_prev and c_cur >= c_next:
			coarse = lag
			break
		c_prev = c_cur
		c_cur = c_next
	if coarse < 0:
		return [-1.0, 0.0]
	var period = _refine_peak(lum, coarse * 4 - 6, coarse * 4 + 6, variance)
	if period <= 0.0:
		return [-1.0, 0.0]
	var m = int(floor(float(n) * 0.5 / period))
	if m > 1:
		var c = int(round(period * m))
		var pk = _refine_peak(lum, c - m - 2, c + m + 2, variance)
		if pk > 0.0:
			period = pk / float(m)
	# Phase: the darkest row, averaged over every course.
	var best_phase = 0
	var best_val = INF
	for f in range(int(round(period))):
		var acc2 = 0.0
		var cnt = 0
		var y = float(f)
		while y < float(n) - 0.5:
			acc2 += lum[int(round(y))]
			cnt += 1
			y += period
		if cnt > 0 and acc2 / float(cnt) < best_val:
			best_val = acc2 / float(cnt)
			best_phase = f
	return [period, float(s + best_phase)]


func _corr(prof: PoolRealArray, lag: int, variance: float) -> float:
	var n = prof.size()
	if lag <= 0 or lag >= n:
		return -1.0
	var acc = 0.0
	for i in range(n - lag):
		acc += prof[i] * prof[i + lag]
	return acc / float(n - lag) / variance


func _refine_peak(prof: PoolRealArray, lo: int, hi: int, variance: float) -> float:
	lo = int(max(lo, 2))
	hi = int(min(hi, prof.size() - 2))
	if hi <= lo:
		return -1.0
	var best = -1
	var best_c = -INF
	for lag in range(lo, hi + 1):
		var c = _corr(prof, lag, variance)
		if c > best_c:
			best_c = c
			best = lag
	if best < 0:
		return -1.0
	var cm = _corr(prof, best - 1, variance)
	var cp = _corr(prof, best + 1, variance)
	var den = cm - 2.0 * best_c + cp
	var off = 0.0
	if abs(den) > 0.000001:
		off = clamp(0.5 * (cm - cp) / den, -0.5, 0.5)
	return float(best) + off


func _sort_by_first(a, b) -> bool:
	return a[0] < b[0]


# ── UI ────────────────────────────────────────────────────────────────────────
# Pattern Tool : ON/OFF + mode (applied to the next shapes drawn).
# Select Tool  : ON/OFF + mode + settings (applied to the selected shapes).
# Both sections are inserted right under the Layer control of their panel.

func _build_ui() -> void:
	if _g.Editor == null:
		return
	var toolset = _g.Editor.get("Toolset")
	if toolset == null:
		return
	var icon_roof = _load_icon("roof.png", HEADER_ICON_PX)
	var icon_reset = _load_icon("reset.png", RESET_ICON_PX)
	var tp = toolset.GetToolPanel("PatternShapeTool")
	if tp != null and tp.get("Align") != null:
		var anchor = null
		var pst = _g.Editor.Tools["PatternShapeTool"]
		if pst != null:
			anchor = pst.get("LayerMenu")
		if anchor != null and anchor.get_parent() is HBoxContainer:
			anchor = anchor.get_parent()
		if anchor == null:
			anchor = _find_layer_anchor(tp.Align, 0)
		_ui["tool"] = _make_section(tp.Align, anchor, UI_TOOL_NAME, "tool", false, icon_roof, icon_reset)
		var cfg = _full_cfg({})
		cfg["mode"] = int(_tool_cfg.get("mode", MODE_FILL))
		cfg["mirror"] = bool(_tool_cfg.get("mirror", false))
		cfg["round_ends"] = int(_tool_cfg.get("round_ends", 0))
		cfg["merge"] = bool(_tool_cfg.get("merge", false))
		cfg["seams"] = int(_tool_cfg.get("seams", SEAMS_SOFT))
		cfg["profile"] = int(_tool_cfg.get("profile", PROFILE_CONE))
		_set_ui_values("tool", cfg, bool(_tool_cfg.get("enabled", false)))
	var sp = toolset.GetToolPanel("SelectTool")
	if sp != null and sp.get("Align") != null:
		var anchor2 = _find_order_anchor(sp.Align, 0, sp)
		if anchor2 == null:
			anchor2 = _find_layer_anchor(sp.Align, 0)
		_ui["select"] = _make_section(sp.Align, anchor2, UI_SELECT_NAME, "select", true, icon_roof, icon_reset)
		_ui["select"]["root"].visible = false


func _load_icon(file_name: String, max_px: int) -> Texture:
	var img = Image.new()
	if img.load(_g.Root + "icons/" + file_name) != OK:
		print("[BetterRoofPatterns] icon not found: icons/" + file_name)
		return null
	img.convert(Image.FORMAT_RGBA8)
	# Colour bled into the transparent pixels: no dark fringe once shrunk.
	img.fix_alpha_edges()
	var big = max(img.get_width(), img.get_height())
	if big > max_px:
		# Halved step by step (each pixel averaged from its 4), then the
		# last step with Lanczos: sharp, without the aliasing of one big
		# cubic step.
		while big > max_px * 2:
			img.resize(max(1, img.get_width() / 2), max(1, img.get_height() / 2), Image.INTERPOLATE_BILINEAR)
			big = max(img.get_width(), img.get_height())
		var k = float(max_px) / float(big)
		img.resize(int(max(1, round(img.get_width() * k))), int(max(1, round(img.get_height() * k))), Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# Select Tool: the row holding the "Bring to Front" / "Send to Back" buttons
# (matched on text or tooltip). null if not found.
func _find_order_anchor(node: Node, depth: int, panel = null):
	# DD's own row first: its layer section (shown for patterns). Other mods
	# add buttons with the same text elsewhere (Minor Utils: "Bring to Front"
	# / "Send to Back" for walls, in the wall options).
	var sections = []
	for owner_node in [panel, node.get_parent()]:
		if owner_node != null and owner_node.get("layerSection") is Node:
			sections.append(owner_node.get("layerSection"))
	sections.append(node)
	for strict in [true, false]:
		for sec in sections:
			var found = []
			_collect_order_buttons(sec, depth, found, strict)
			if found.empty():
				continue
			var b = found[0]
			var parent = b.get_parent()
			if parent is HBoxContainer or parent is GridContainer:
				return parent
			return b
	return null


func _collect_order_buttons(node: Node, depth: int, out: Array, strict: bool) -> void:
	if depth > 6:
		return
	for child in node.get_children():
		if child is BaseButton and _is_order_button(child, strict):
			out.append(child)
		if child is Control and child.get_child_count() > 0:
			_collect_order_buttons(child, depth + 1, out, strict)


# DD's buttons: "pressed" connected to SelectTool.BringToFront / SendToBack
# (strict), or text "BRING_TO_FRONT" / "SEND_TO_BACK" (translation keys,
# shown translated).
func _is_order_button(b: BaseButton, strict: bool) -> bool:
	for con in b.get_signal_connection_list("pressed"):
		var m = str(con.get("method", ""))
		if m == "BringToFront" or m == "SendToBack":
			return true
	if strict:
		return false
	var txt = (str(b.get("text")) + " " + str(b.hint_tooltip)).to_lower().replace("_", " ")
	return txt.find("to front") >= 0 or txt.find("to back") >= 0


# Returns the control after which our section goes: the row holding a
# "Layer…" label (or the control right after that label). null = append.
func _find_layer_anchor(node: Node, depth: int):
	if depth > 4:
		return null
	for child in node.get_children():
		if child is Label and str(child.text).strip_edges().to_lower().begins_with("layer"):
			var parent = child.get_parent()
			if parent is HBoxContainer:
				return parent
			var idx = child.get_index()
			if idx + 1 < parent.get_child_count():
				return parent.get_child(idx + 1)
			return child
		if child is Container:
			var found = _find_layer_anchor(child, depth + 1)
			if found != null:
				return found
	return null


func _make_section(align: Node, anchor, node_name: String, section: String, full: bool, icon_roof: Texture, icon_reset: Texture) -> Dictionary:
	var old = align.get_node_or_null(node_name)
	if old == null and anchor != null and is_instance_valid(anchor) and anchor.get_parent() != null:
		old = anchor.get_parent().get_node_or_null(node_name)
	if old != null:
		old.get_parent().remove_child(old)
		old.queue_free()
	var root = VBoxContainer.new()
	root.name = node_name
	if anchor != null and is_instance_valid(anchor) and anchor.get_parent() != null:
		var parent = anchor.get_parent()
		parent.add_child(root)
		parent.move_child(root, anchor.get_index() + 1)
	else:
		align.add_child(root)
	root.add_child(HSeparator.new())

	var header = CheckButton.new()
	header.text = "Roof Builder"
	header.focus_mode = Control.FOCUS_NONE
	if icon_roof != null:
		header.icon = icon_roof
	if section == "tool":
		header.hint_tooltip = "When ON, the next pattern shapes you draw become roofs.\nTheir settings can then be tuned in the Select Tool."
	else:
		header.hint_tooltip = "Turns the selected pattern shapes into roofs (ON)\nor back into plain patterns (OFF)."
	header.connect("toggled", self, "_on_enabled_toggled", [section])
	root.add_child(header)
	var clip_row = null
	if full:
		# Copy / paste every roof setting (not the texture) between roofs.
		clip_row = HBoxContainer.new()
		var cb = Button.new()
		cb.text = "Copy Settings"
		cb.focus_mode = Control.FOCUS_NONE
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cb.hint_tooltip = "Copies the roof settings of the selected roof (all but the texture)."
		cb.connect("pressed", self, "_on_settings_copy")
		_style_mode_button(cb)
		clip_row.add_child(cb)
		var pb = Button.new()
		pb.text = "Paste Settings"
		pb.focus_mode = Control.FOCUS_NONE
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pb.hint_tooltip = "Gives the copied roof settings to the selected shapes (they\nbecome roofs if they were not). Their texture is kept."
		pb.disabled = _settings_clip == null
		pb.connect("pressed", self, "_on_settings_paste")
		_style_mode_button(pb)
		clip_row.add_child(pb)

	var opts = VBoxContainer.new()
	root.add_child(opts)
	var lib = CheckButton.new()
	lib.text = "Auto Roof Library"
	lib.focus_mode = Control.FOCUS_NONE
	lib.hint_tooltip = "While Roof Builder is on, the pattern list only shows roof\ntextures: the patterns that are roofs, then the roof textures\nof DD's Roof Tool. Kept for every map."
	lib.pressed = _lib_on
	lib.connect("toggled", self, "_on_lib_toggled")
	opts.add_child(lib)
	var mode_row = HBoxContainer.new()
	opts.add_child(mode_row)
	var group = ButtonGroup.new()
	var c = {"root": root, "header": header, "opts": opts, "full": full, "modes": {}, "lib": lib, "clip": clip_row}
	c["modes"][MODE_FILL] = _make_mode_button(mode_row, group, "Gap Free",
		"The texture's bottom edge (eave) is drawn once, on the lower\nedge of the shape, and only the repeatable part is tiled above\nit, so large roofs no longer show holes.",
		MODE_FILL, section)
	c["modes"][MODE_CENTER] = _make_mode_button(mode_row, group, "Centered",
		"The outline becomes the eave and the centre the roof top.\nBest on circles, ellipses and regular polygons.",
		MODE_CENTER, section)
	c["modes"][MODE_HIP] = _make_mode_button(mode_row, group, "Hip",
		"Every edge is an eave and the tile rows follow the nearest edge:\na rectangle gets a ridge along its length (a square stays\na pyramid). Works with any shape, including L-shaped houses.",
		MODE_HIP, section)

	c["mirror"] = _make_toggle(opts, "Two Slopes",
		"Draws an eave on both sides of the shape with a ridge in the\nmiddle (gable roof). The far slope is the near one turned 180°.\nThe texture rotation sets the ridge direction.",
		section, "mirror")
	c["round_ends"] = _make_option(opts, "Round Ends", ["Off", "Start", "End", "Both"],
		"Rounds one end of the ridge (Start / End, along the texture's\ndirection) or both, inside the drawn shape: half a cone as\nwide as the roof, flatter on short roofs so it is never cut.",
		section, "round_ends")
	c["seams"] = _make_option(opts, "Seams", ["None", "Line", "Soft", "Ridge Caps"],
		"Ridge and hip lines. None: plain cut. Line: ink line and a\nsmall shadow. Soft: the two sides blended over a few pixels.\nRidge Caps: a row of cap tiles made from the roof texture\n(Hip roofs, Gap Free with Two Slopes).",
		section, "seams")
	c["profile"] = _make_option(opts, "Profile", ["Cone", "Dome", "Low Dome", "Spire", "Onion"],
		"Shape of the slope: straight (cone), round (dome, low dome),\nsteep at the eave and pointed (spire), or a round shoulder\nwith a pointed top (onion dome). Rows of tiles get closer\ntogether where the roof is steep.",
		section, "profile")
	# Profile above Seams.
	opts.move_child(c["profile"]["row"], c["seams"]["row"].get_index())
	if not full:
		c["merge"] = _make_toggle(opts, "Merge With Roof Below",
			"The next roofs drawn join the roofs below them: where a roof\nbelow rises higher, it shows through, so the roofs meet on\ntheir real intersection line.",
			section, "merge")
	if full:
		c["side_ink"] = _make_toggle(opts, "Side Lines",
			"Draws a dark outline on every side where the texture is plainly\ncut, whatever the drawn shape: eaves when the texture has no\ncut-out edge of its own, and always the sides that are not an\neave (gable ends, the sides a moved roof top is close to).",
			section, "side_ink")
		c["cap_style"] = _make_option(opts, "Cap Style", ["Auto", "Turned Tiles", "Texture Band", "Path", "Roof Pieces"],
			"Turned Tiles: one tile column of the texture turned along the\nline (half-round tiles). Texture Band: one course of the texture\nlaid along the line (slates, bricks, thatch...). Roof Pieces: the\nridge and hip strips of a Roof Tool texture. Path: textures of\nthe Path Tool, picked below. Auto picks from the texture (Roof\nPieces when it has them).",
			section, "cap_style")
		# Path before Roof Pieces in the menu (item ids: the saved values).
		var cso0: OptionButton = c["cap_style"]["option"]
		cso0.set_item_id(3, CAP_PATH)
		cso0.set_item_id(4, 3)
		var cap_reset = _make_reset(icon_reset, "Reset all the Ridge Caps settings to their defaults")
		cap_reset.connect("pressed", self, "_on_caps_reset", [section])
		c["cap_style"]["row"].add_child(cap_reset)
		c["cap_path_hip"] = _make_path_pick(opts, "Hip Path", "Path Tool texture of the hip caps (Same as Ridge: the ridge's).", section, "cap_path_hip")
		c["cap_path_ridge"] = _make_path_pick(opts, "Ridge Path", "Path Tool texture of the ridge caps (Same as Hip: the hip's).", section, "cap_path_ridge")
		# Width: one slider, on the hips, the ridges or both (Both: they move
		# together, keeping their ratio).
		c["cap_width_on"] = _make_option(opts, "Width", ["Hip", "Ridge", "Both"],
			"Which caps the slider below sizes (Both: hips and ridges move\ntogether, keeping their ratio).", section, "cap_width_on")
		c["cap_wsl"] = _make_slider(opts, "", 30.0, 300.0, "%",
			"Width of the caps chosen above.", section, "cap_wsl", icon_reset)
		c["cap_wsl"]["row"].get_child(0).visible = false
		c["cap_wvals"] = [100.0, 100.0]
		c["cap_bright"] = _make_slider(opts, "Cap Brightness", -100.0, 100.0, "%",
			"Brightness of the ridge caps (changes their gamma: darker\nor lighter than the roof).",
			section, "cap_bright", icon_reset)
		c["cap_hue"] = _make_slider(opts, "Cap Hue", -180.0, 180.0, "°",
			"Turns the colour of the ridge caps around the colour wheel.",
			section, "cap_hue", icon_reset)
		c["cap_sat"] = _make_slider(opts, "Cap Saturation", -100.0, 100.0, "%",
			"Colour strength of the ridge caps: -100% grey, +100% twice\nas strong.",
			section, "cap_sat", icon_reset)
		c["cap_outline"] = _make_option(opts, "Cap Outline", ["None", "Line", "Blurred"],
			"Edge of the ridge caps: plain, a black ink line, or blurred\n(the cap fades out toward its sides).",
			section, "cap_outline")
		c["cap_corners"] = _make_option(opts, "Cap Corners Style", ["Square", "Round", "Flat"],
			"End of the hips at the corners of the shape: cut like the\ncorner (a point), rounded (half circle) or cut flat across.",
			section, "cap_corners")
		c["cap_tip"] = _make_slider(opts, "Cap Corners Length", -300.0, 200.0, "%",
			"How far the end of the hips goes past the corner of the shape\n(in half cap widths; below 0%: short of the corner).",
			section, "cap_tip", icon_reset)
		c["ridge_ends"] = _make_option(opts, "Ridge Ends", ["Mitred Faded", "Round"],
			"Where the caps meet: mitred joint, cross-faded over Ridge Fade\n(0%: hard cut), or the ridge laid over the hips, ending in a\nhalf circle (like Round Ends).",
			section, "ridge_ends")
		c["cap_fade"] = _make_slider(opts, "Ridge Fade", 0.0, 100.0, "%",
			"Width of the cross-fade where the caps meet (0%: hard cut).",
			section, "cap_fade", icon_reset)
		c["cap_recolor"] = _make_toggle(opts, "Cap Recolor",
			"Changes the brightness, hue and saturation of the ridge caps.",
			section, "cap_recolor")
		c["cap_recolor_on"] = _make_option(opts, "Recolor", ["Hip", "Ridge", "Both"],
			"Which caps Cap Recolor changes.", section, "cap_recolor_on")
		c["corners_cog"] = _make_cog(section, "Cap Corners settings: length.")
		c["cap_corners"]["row"].add_child(c["corners_cog"])
		c["ridge_cog"] = _make_cog(section, "Ridge Ends settings: fade.")
		c["ridge_ends"]["row"].add_child(c["ridge_cog"])
		c["cap_sep"] = HSeparator.new()
		opts.add_child(c["cap_sep"])
		# Ridge Caps settings: under the Seams menu, shown with its cog.
		c["seams_cog"] = _make_cog(section, "Ridge Caps settings: style, width, brightness and outline.")
		c["seams"]["row"].add_child(c["seams_cog"])
		c["cap_box"] = _make_box(opts, c["seams"]["row"].get_index() + 1,
			[c["cap_style"]["row"], c["cap_path_hip"]["row"], c["cap_path_ridge"]["row"], c["cap_width_on"]["row"], c["cap_wsl"]["row"], c["cap_outline"]["row"], c["cap_corners"]["row"], c["cap_tip"]["row"], c["ridge_ends"]["row"], c["cap_fade"]["row"], c["cap_recolor"], c["cap_recolor_on"]["row"], c["cap_bright"]["row"], c["cap_hue"]["row"], c["cap_sat"]["row"], c["cap_sep"]])
		c["taper"] = _make_toggle(opts, "Taper Toward Top",
			"Each course of tiles gets its own tile count, fewer and fewer\ntoward the top, like a real conical roof: the tiles keep about\nthe same width and the count changes on the row edges, under\nthe overlap of the course above.",
			section, "taper")
		c["curve"] = _make_slider(opts, "Curve", 0.0, 100.0, "%",
			"How steep the slope gets at the eave (Dome, Low Dome, Spire, Onion).\nHigher: rows of tiles packed tighter near the eave.",
			section, "curve", icon_reset)
		# Curve right under Profile.
		opts.move_child(c["curve"]["row"], c["profile"]["row"].get_index() + 1)
		c["apex_on"] = _make_toggle(opts, "Custom Top Position",
			"Moves the roof top away from the centre of the shape.",
			section, "apex_on")
		c["apex_box"] = _make_apex_box(opts, c, section, icon_reset)
		# Label, cog, then the switch: the cog sits just left of ON/OFF.
		var mtip = "Joins this roof to the roof it overlaps the most among those\ndrawn below it: where that roof rises higher, it shows through,\nso the two roofs meet on their real intersection line.\nTip: put the roof with the most cut-out eave (round tiles,\nscales) on top, so its own edge is drawn over the other one."
		var mrow = HBoxContainer.new()
		opts.add_child(mrow)
		var mlbl = Label.new()
		mlbl.text = "Merge With Roof Below"
		mlbl.hint_tooltip = mtip
		mlbl.mouse_filter = Control.MOUSE_FILTER_PASS
		mlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mrow.add_child(mlbl)
		var cog = _make_cog(section, "Merge settings: Merge Height, junction line and valley shadow.")
		mrow.add_child(cog)
		c["merge_cog"] = cog
		c["merge"] = _make_toggle(mrow, "", mtip, section, "merge")
		var mbox = VBoxContainer.new()
		opts.add_child(mbox)
		mbox.visible = false
		c["merge_box"] = mbox
		c["merge_sep"] = HSeparator.new()
		opts.add_child(c["merge_sep"])
		c["merge_height"] = _make_slider(mbox, "Merge Height", -1000.0, 1000.0, " px",
			"Raises (+) or lowers (-) this roof against the roofs below it:\nhigher, it covers more of them; lower, they show through more.",
			section, "merge_height", icon_reset)
		c["valley_line"] = _make_slider(mbox, "Junction Line Width", 0.0, 400.0, "%",
			"Width of the ink line where the roofs meet (100% = default,\n0% = no line).",
			section, "valley_line", icon_reset)
		c["valley_opacity"] = _make_slider(mbox, "Valley Shadow Opacity", 0.0, 100.0, "%",
			"Darkness of the shadow on both roofs along the line where\nthey meet.",
			section, "valley_opacity", icon_reset)
		c["valley_width"] = _make_slider(mbox, "Valley Shadow Width", 0.0, 300.0, "%",
			"Width of the valley shadow (100% = default, set from the\nheight of the tile rows).",
			section, "valley_width", icon_reset)
		c["global_light"] = _make_toggle(opts, "Global Lighting",
			"One light for every roof of the map: Shading Strength and\nLight Direction then change all roofs at once.\nSaved with the map.",
			section, "global_light")
		c["shade_on"] = _make_toggle(opts, "Shading",
			"Lights one side of the roof and darkens the other,\nusing the Shading Strength and Light Direction below.",
			section, "shade_on")
		c["scale"] = _make_slider(opts, "Tile Width", 10.0, 400.0, "%",
			"Width of the tiles (the rows keep their height, the shape keeps\nits size). On Centered roofs the seam this can leave where the\noutline loops is blended by Softer Seams.",
			section, "scale", icon_reset)
		c["ridge_offset"] = _make_slider(opts, "Ridge Offset", -50.0, 50.0, "%",
			"Shifts the far slope sideways (in % of the texture width) so\nthe tiles of both slopes do not line up perfectly at the ridge.",
			section, "ridge_offset", icon_reset)
		c["repeat"] = _make_slider(opts, "Repeat Point", -512.0, 512.0, " px",
			"Moves where the texture repeats along the slope (the height of\nthe repeated band). Try it when a seam or a strong band shows\nwhere the texture starts over.",
			section, "repeat", icon_reset)
		c["edge"] = _make_slider(opts, "Edge Offset", -128.0, 128.0, " px",
			"Moves the eave inward (+) or outward (-).\nThe empty rows under the eave are already removed automatically.",
			section, "edge", icon_reset)
		c["u_offset"] = _make_slider(opts, "Texture Offset", -100.0, 100.0, "%",
			"Slides the texture sideways (in % of the texture width),\nwithout moving the shape.",
			section, "u_offset", icon_reset)
		c["pitch"] = _make_slider(opts, "Pitch", 0.0, 70.0, "°",
			"Roof steepness: steeper roofs show more tile rows\nbetween the edge and the top.",
			section, "pitch", icon_reset)
		# Link: Tile Width and Pitch move together (the tiles keep their
		# shape: steeper rows are seen shorter, the tiles get as narrow).
		var icon_link = _load_icon("link.png", RESET_ICON_PX)
		c["links"] = []
		for f in ["scale", "pitch"]:
			var lb = Button.new()
			lb.toggle_mode = true
			lb.flat = true
			lb.focus_mode = Control.FOCUS_NONE
			lb.hint_tooltip = "Links Tile Width and Pitch: they move together so the tiles keep\ntheir shape (a steeper roof shows shorter rows and narrower tiles)."
			if icon_link != null:
				lb.icon = icon_link
			else:
				lb.text = "Link"
			lb.connect("toggled", self, "_on_link_toggled", [section])
			c[f]["row"].get_child(1).add_child(lb)
			c["links"].append(lb)
		c["shade_sep"] = HSeparator.new()
		opts.add_child(c["shade_sep"])
		opts.move_child(c["shade_sep"], c["pitch"]["row"].get_index() + 1)
		opts.move_child(c["shade_on"], c["shade_sep"].get_index() + 1)
		opts.move_child(c["global_light"], c["shade_on"].get_index() + 1)
		c["shade"] = _make_slider(opts, "Shading Strength", 0.0, 100.0, "%",
			"Strength of the light/shadow effect on the roof sides.",
			section, "shade", icon_reset)
		c["light"] = _make_slider(opts, "Light Direction", 0.0, 359.0, "°",
			"Where the light comes from (0° = top, clockwise).",
			section, "light", icon_reset)
		# Texture Settings: one row with a cog showing them all.
		var trow = HBoxContainer.new()
		opts.add_child(trow)
		opts.move_child(trow, c["scale"]["row"].get_index())
		var tlbl = Label.new()
		tlbl.text = "Texture Settings"
		tlbl.hint_tooltip = "Tile Width, Ridge Offset, Repeat Point, Edge Offset, Texture\nOffset and Pitch."
		tlbl.mouse_filter = Control.MOUSE_FILTER_PASS
		tlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		trow.add_child(tlbl)
		c["tex_cog"] = _make_cog(section, "Show the texture settings.")
		trow.add_child(c["tex_cog"])
		c["tex_box"] = _make_box(opts, trow.get_index() + 1,
			[c["scale"]["row"], c["ridge_offset"]["row"], c["repeat"]["row"], c["edge"]["row"], c["u_offset"]["row"], c["pitch"]["row"]])
	if clip_row != null:
		# At the bottom of the section, under a divider (the panel already
		# has one below the section).
		root.add_child(HSeparator.new())
		root.add_child(clip_row)
	return c


# Settings cog: toggles a hidden group of settings (see _update_visibility).
func _make_cog(section: String, tip: String) -> Button:
	var cog = Button.new()
	cog.toggle_mode = true
	cog.flat = true
	cog.focus_mode = Control.FOCUS_NONE
	cog.hint_tooltip = tip
	cog.icon = _load_icon("cog.png", RESET_ICON_PX)
	if cog.icon == null:
		cog.text = "..."
	cog.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cog.connect("toggled", self, "_on_merge_cog", [section])
	return cog


# Moves controls of opts into a new box at index (hidden until its cog is on).
func _make_box(opts: Node, index: int, items: Array) -> VBoxContainer:
	var box = VBoxContainer.new()
	opts.add_child(box)
	opts.move_child(box, index)
	for it in items:
		it.get_parent().remove_child(it)
		box.add_child(it)
	box.visible = false
	return box


func _make_mode_button(parent: Node, group: ButtonGroup, text: String, tip: String, mode: int, section: String) -> Button:
	var b = Button.new()
	b.text = text
	b.toggle_mode = true
	b.group = group
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.hint_tooltip = tip
	b.connect("pressed", self, "_on_mode_pressed", [mode, section])
	parent.add_child(b)
	_style_mode_button(b)
	return b


# 1 px grey outline with 3 px rounded corners, keeping the theme's colours
# when the theme uses flat styleboxes.
func _style_mode_button(b: Button) -> void:
	# Every state gets its own flat box with the SAME margins and no expand
	# margin / shadow / theme border: DD's theme draws the selected button
	# bigger (and its hover-selected state too), which pushed the row past
	# the panel edges.
	var states = {
		"normal": Color(0.0, 0.0, 0.0, 0.18),
		"hover": Color(1.0, 1.0, 1.0, 0.07),
		"pressed": Color(0.26, 0.42, 0.60, 0.55),
		"hover_pressed": Color(0.30, 0.47, 0.66, 0.65),
		"disabled": Color(0.0, 0.0, 0.0, 0.10),
	}
	for state in states.keys():
		var sb = StyleBoxFlat.new()
		sb.bg_color = states[state]
		sb.border_color = Color(0.5, 0.5, 0.5, 1.0)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		sb.anti_aliasing = true
		sb.content_margin_left = 4
		sb.content_margin_right = 4
		sb.content_margin_top = 3
		sb.content_margin_bottom = 3
		b.add_stylebox_override(state, sb)
	b.add_stylebox_override("focus", StyleBoxEmpty.new())
	b.clip_text = true
	b.rect_min_size = Vector2(0, 0)


func _make_toggle(parent: Node, text: String, tip: String, section: String, field: String) -> CheckButton:
	var t = CheckButton.new()
	t.text = text
	t.focus_mode = Control.FOCUS_NONE
	t.hint_tooltip = tip
	t.connect("toggled", self, "_on_toggle_changed", [section, field])
	parent.add_child(t)
	return t


func _make_option(parent: Node, text: String, items: Array, tip: String, section: String, field: String) -> Dictionary:
	var row = HBoxContainer.new()
	parent.add_child(row)
	var lbl = Label.new()
	lbl.text = text
	lbl.hint_tooltip = tip
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(lbl)
	var ob = OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	ob.hint_tooltip = tip
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in range(items.size()):
		ob.add_item(items[i], i)
	ob.connect("item_selected", self, "_on_option_selected", [section, field])
	row.add_child(ob)
	return {"row": row, "option": ob}


# Cog of Merge With Roof Below: shows / hides the merge settings.
func _on_merge_cog(_pressed: bool, section: String) -> void:
	_update_visibility(section)


func _on_option_selected(index: int, section: String, field: String) -> void:
	if _updating_ui:
		return
	if field == "cap_style":
		# (its items are not in the order of their values)
		var cc = _ui.get(section)
		if cc != null and cc.has("cap_style"):
			index = cc["cap_style"]["option"].get_item_id(index)
	if section == "tool":
		_tool_cfg[field] = index
		_update_visibility(section)
		return
	_apply_fields(section, {field: index})
	_update_visibility(section)
	if field == "cap_width_on":
		_wsl_show(section)
	# Path picked without a texture yet: the picker opens.
	var c = _ui.get(section)
	if field == "cap_style" and index == CAP_PATH and c != null and c.has("cap_path_ridge") and c["cap_path_ridge"]["path"] == "" and c["cap_path_hip"]["path"] == "":
		_open_path_pop(section, "cap_path_ridge")


const CAP_KEYS = ["cap_style", "cap_path_ridge", "cap_path_hip", "cap_width", "cap_width_hip", "cap_width_on",
	"cap_outline", "cap_corners", "cap_tip", "ridge_ends", "cap_fade", "cap_recolor", "cap_recolor_on",
	"cap_bright", "cap_hue", "cap_sat"]

# Reset button beside Cap Style: every Ridge Caps setting back to default.
func _on_caps_reset(section: String) -> void:
	var c = _ui.get(section)
	if c == null or section != "select":
		return
	var fields = {}
	for k in CAP_KEYS:
		fields[k] = DEFAULT_CFG[k]
	_apply_fields(section, fields)
	var store = _get_store()
	if store != null and not _sel_shapes.empty():
		var key = _key_of(_sel_shapes[0])
		if key != "" and store.has(key):
			_set_ui_values("select", store[key], true)
	_update_visibility(section)


func _make_reset(icon_reset: Texture, tip: String) -> Button:
	var reset = Button.new()
	reset.focus_mode = Control.FOCUS_NONE
	reset.hint_tooltip = tip
	if icon_reset != null:
		reset.icon = icon_reset
	else:
		reset.text = "R"
	return reset


func _make_spin(mn: float, mx: float, unit: String, tip: String) -> SpinBox:
	var sb = SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = 1.0
	sb.suffix = unit.strip_edges()
	sb.hint_tooltip = tip
	sb.rect_min_size.x = 76
	sb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Typing in the field must not trigger DD's shortcuts.
	var le = sb.get_line_edit()
	le.connect("focus_entered", self, "_on_text_focus", [true])
	le.connect("focus_exited", self, "_on_text_focus", [false])
	le.connect("text_entered", self, "_on_text_entered", [le])
	return sb


func _make_slider(parent: Node, text: String, mn: float, mx: float, unit: String, tip: String, section: String, field: String, icon_reset: Texture) -> Dictionary:
	var row = VBoxContainer.new()
	parent.add_child(row)
	var lbl = Label.new()
	lbl.text = text
	lbl.hint_tooltip = tip
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(lbl)
	var line = HBoxContainer.new()
	row.add_child(line)
	var sl = HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = 1.0
	sl.focus_mode = Control.FOCUS_NONE
	sl.hint_tooltip = tip
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(sl)
	var sb = _make_spin(mn, mx, unit, tip)
	line.add_child(sb)
	var reset = _make_reset(icon_reset, "Reset to default")
	reset.connect("pressed", self, "_on_reset_pressed", [section, field])
	line.add_child(reset)
	sl.connect("value_changed", self, "_on_value_changed", [section, field, "slider"])
	sb.connect("value_changed", self, "_on_value_changed", [section, field, "spin"])
	return {"row": row, "slider": sl, "spin": sb}


# Top position: dial (handle = top point inside the shape's box) + X / Y spins.
func _make_apex_box(parent: Node, c: Dictionary, section: String, icon_reset: Texture) -> Control:
	var box = VBoxContainer.new()
	parent.add_child(box)
	var row = HBoxContainer.new()
	box.add_child(row)
	var lx = Label.new()
	lx.text = "X"
	row.add_child(lx)
	var sx = _make_spin(-100.0, 100.0, "%", "Horizontal position of the top (0% = centre).")
	sx.connect("value_changed", self, "_on_apex_spin", [section])
	row.add_child(sx)
	var ly = Label.new()
	ly.text = "Y"
	row.add_child(ly)
	var sy = _make_spin(-100.0, 100.0, "%", "Vertical position of the top (0% = centre).")
	sy.connect("value_changed", self, "_on_apex_spin", [section])
	row.add_child(sy)
	var lock = Button.new()
	lock.toggle_mode = true
	lock.focus_mode = Control.FOCUS_NONE
	lock.hint_tooltip = "Locked: the top keeps its place on the map when the shape is rotated.\nUnlocked: the top turns with the shape."
	c["icon_lock"] = _load_icon("lock.png", RESET_ICON_PX)
	c["icon_unlock"] = _load_icon("unlock.png", RESET_ICON_PX)
	lock.icon = c["icon_unlock"]
	if lock.icon == null:
		lock.text = "L"
	lock.connect("toggled", self, "_on_apex_lock", [section])
	row.add_child(lock)
	c["apex_lock"] = lock
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var reset = _make_reset(icon_reset, "Reset the top to the centre")
	reset.connect("pressed", self, "_on_apex_reset", [section])
	row.add_child(reset)
	var cc = CenterContainer.new()
	box.add_child(cc)
	var mc = MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		mc.add_constant_override(m, 6)
	cc.add_child(mc)
	var dial = _create_dial(section)
	mc.add_child(dial)
	c["apex_x"] = sx
	c["apex_y"] = sy
	c["dial"] = dial
	c["dial_dot"] = dial.get_node("Handle")
	return box


func _make_circle_texture(size: int, color: Color, ring: bool) -> ImageTexture:
	var img = Image.new()
	img.create(size, size, false, Image.FORMAT_RGBA8)
	img.lock()
	var ctr = Vector2(size / 2.0, size / 2.0)
	var radius = size / 2.0
	for y in range(size):
		for x in range(size):
			var d = Vector2(x + 0.5, y + 0.5).distance_to(ctr)
			var inside = abs(d - radius + 0.5) < 1.0 if ring else d <= radius
			img.set_pixel(x, y, color if inside else Color(0, 0, 0, 0))
	img.unlock()
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	return tex


func _create_dial(section: String) -> Control:
	var size = DIAL_SIZE
	var full = DIAL_SIZE + DIAL_PAD * 2
	var ctr = full / 2.0
	var dial = Control.new()
	dial.name = "TopDial"
	dial.rect_min_size = Vector2(full, full)
	dial.hint_tooltip = "Drag to move the roof top inside the shape.\nThe dots around the dial lock the top on a 45° direction."
	var bg = TextureRect.new()
	bg.texture = _make_circle_texture(size, Color(0.12, 0.12, 0.12, 1.0), false)
	bg.rect_position = Vector2(DIAL_PAD, DIAL_PAD)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(bg)
	for frac in [0.5, 1.0]:
		var rs = int(size * frac)
		var ring = TextureRect.new()
		ring.texture = _make_circle_texture(rs, Color(0.25, 0.25, 0.25, 1.0), true)
		ring.rect_position = Vector2(ctr - rs / 2.0, ctr - rs / 2.0)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dial.add_child(ring)
	# Dotted diagonals, plain cross.
	for diag in [45.0, 135.0, 225.0, 315.0]:
		var dr = deg2rad(diag)
		for d in range(4, int(size / 2.0 - 2.0), 3):
			var dot_px = ColorRect.new()
			dot_px.color = Color(0.22, 0.22, 0.22, 0.7)
			dot_px.rect_size = Vector2(1, 1)
			dot_px.rect_position = Vector2(ctr + cos(dr) * d, ctr + sin(dr) * d)
			dot_px.mouse_filter = Control.MOUSE_FILTER_IGNORE
			dial.add_child(dot_px)
	var h_line = ColorRect.new()
	h_line.color = Color(0.25, 0.25, 0.25, 0.6)
	h_line.rect_position = Vector2(DIAL_PAD, ctr - 0.5)
	h_line.rect_size = Vector2(size, 1)
	h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(h_line)
	var v_line = ColorRect.new()
	v_line.color = Color(0.25, 0.25, 0.25, 0.6)
	v_line.rect_position = Vector2(ctr - 0.5, DIAL_PAD)
	v_line.rect_size = Vector2(1, size)
	v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(v_line)
	# Snap points every 45° (0° = right, clockwise like the screen).
	var snaps = []
	var tex_off = _make_circle_texture(10, Color(0.3, 0.3, 0.3, 0.85), false)
	var tex_on = _make_circle_texture(10, Color(0.353, 0.698, 1.0, 1.0), false)
	var names = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]
	for i in range(8):
		var a = deg2rad(45.0 * i)
		var dir = Vector2(cos(a), sin(a))
		var b = TextureButton.new()
		b.texture_normal = tex_off
		b.texture_pressed = tex_on
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.rect_size = Vector2(10, 10)
		b.rect_position = Vector2(ctr, ctr) + dir * (size / 2.0 + 6.0) - Vector2(5, 5)
		b.hint_tooltip = "Lock the top toward " + names[i]
		b.connect("toggled", self, "_on_snap_toggled", [i, section])
		dial.add_child(b)
		snaps.append(b)
	var handle = ColorRect.new()
	handle.name = "Handle"
	handle.color = Color(0.95, 0.6, 0.1, 1.0)
	handle.rect_size = Vector2(10, 10)
	handle.rect_position = Vector2(ctr - 5, ctr - 5)
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dial.add_child(handle)
	dial.set_meta("dragging", false)
	dial.set_meta("snap", -1)
	dial.set_meta("snaps", snaps)
	dial.connect("gui_input", self, "_on_dial_input", [dial, section])
	return dial


func _set_dial(c: Dictionary, ax: float, ay: float) -> void:
	if not c.has("dial"):
		return
	var ctr = DIAL_SIZE / 2.0 + DIAL_PAD
	var radius = DIAL_SIZE / 2.0
	c["dial_dot"].rect_position = Vector2(ctr + ax * radius - 5.0, ctr + ay * radius - 5.0)


func _snap_dir(i: int) -> Vector2:
	var a = deg2rad(45.0 * i)
	return Vector2(cos(a), sin(a))


func _on_snap_toggled(pressed: bool, i: int, section: String) -> void:
	var c = _ui.get(section)
	if c == null or not c.has("dial"):
		return
	var dial = c["dial"]
	if not pressed:
		if int(dial.get_meta("snap")) == i:
			dial.set_meta("snap", -1)
		return
	var snaps = dial.get_meta("snaps")
	for k in range(snaps.size()):
		if k != i and snaps[k].pressed:
			snaps[k].pressed = false
	dial.set_meta("snap", i)
	if _updating_ui:
		return
	# Keep the current distance from the centre, move onto the direction.
	var cur = Vector2(float(c["apex_x"].value), float(c["apex_y"].value)) / 100.0
	var mag = cur.length()
	if mag < 0.05:
		mag = 0.5
	var p = _snap_dir(i) * min(mag, 1.0)
	_commit_apex(section, p.x, p.y)


func _clear_snaps(c: Dictionary) -> void:
	if not c.has("dial"):
		return
	var dial = c["dial"]
	dial.set_meta("snap", -1)
	for b in dial.get_meta("snaps"):
		if b.pressed:
			b.pressed = false


func _set_ctl(ctl: Dictionary, v: float) -> void:
	ctl["slider"].value = v
	ctl["spin"].value = v


func _set_ui_values(section: String, cfg, enabled: bool) -> void:
	var c = _ui.get(section)
	if c == null or not is_instance_valid(c["root"]):
		return
	var full = _full_cfg(cfg)
	_updating_ui = true
	c["header"].pressed = enabled
	for m in c["modes"].keys():
		c["modes"][m].pressed = full["mode"] == m
	c["mirror"].pressed = full["mirror"]
	c["round_ends"]["option"].select(full["round_ends"])
	c["merge"].pressed = full["merge"]
	c["seams"]["option"].select(full["seams"])
	c["profile"]["option"].select(full["profile"])
	if c["full"]:
		_set_ctl(c["curve"], full["curve"])
		_set_ctl(c["ridge_offset"], full["ridge_offset"])
		_set_ctl(c["scale"], full["scale"])
		_set_ctl(c["edge"], full["edge"])
		_set_ctl(c["u_offset"], full["u_offset"])
		_set_ctl(c["merge_height"], full["merge_height"])
		for vk in ["valley_line", "valley_opacity", "valley_width"]:
			_set_ctl(c[vk], full[vk])
		_set_ctl(c["pitch"], full["pitch"])
		for lb in c["links"]:
			lb.pressed = full["size_link"]
		_link_take(section)
		var gl = _global_light()
		c["global_light"].pressed = gl["on"]
		_set_ctl(c["shade"], (gl["shade"] if gl["on"] else full["shade"]) * 100.0)
		_set_ctl(c["light"], gl["light"] if gl["on"] else full["light"])
		c["taper"].pressed = full["taper"]
		_set_ctl(c["repeat"], full["repeat"])
		c["apex_on"].pressed = full["apex_on"]
		c["shade_on"].pressed = full["shade_on"]
		c["side_ink"].pressed = full["side_ink"]
		c["cap_outline"]["option"].select(full["cap_outline"])
		c["cap_wvals"] = [full["cap_width_hip"], full["cap_width"]]
		c["cap_width_on"]["option"].select(full["cap_width_on"])
		_wsl_show(section)
		_set_ctl(c["cap_bright"], full["cap_bright"])
		_set_ctl(c["cap_hue"], full["cap_hue"])
		_set_ctl(c["cap_sat"], full["cap_sat"])
		c["cap_style"]["option"].select(c["cap_style"]["option"].get_item_index(full["cap_style"]))
		_set_path_pick(c["cap_path_ridge"], full["cap_path_ridge"], false)
		_set_path_pick(c["cap_path_hip"], full["cap_path_hip"], true)
		c["cap_corners"]["option"].select(full["cap_corners"])
		_set_ctl(c["cap_tip"], full["cap_tip"])
		c["ridge_ends"]["option"].select(full["ridge_ends"])
		c["cap_recolor"].pressed = full["cap_recolor"]
		c["cap_recolor_on"]["option"].select(full["cap_recolor_on"])
		_set_ctl(c["cap_fade"], full["cap_fade"])
		c["apex_x"].value = round(full["apex_x"] * 100.0)
		c["apex_y"].value = round(full["apex_y"] * 100.0)
		_set_dial(c, full["apex_x"], full["apex_y"])
		c["apex_lock"].pressed = full["apex_lock"]
		_set_lock_icon(c)
	_updating_ui = false
	_update_visibility(section)


func _ui_mode(section: String) -> int:
	var c = _ui.get(section)
	if c != null:
		for m in c["modes"].keys():
			if c["modes"][m].pressed:
				return m
	return MODE_FILL


func _read_ui_cfg(section: String) -> Dictionary:
	var c = _ui.get(section)
	var cfg = _full_cfg({})
	if c == null:
		return cfg
	cfg["mode"] = _ui_mode(section)
	cfg["mirror"] = c["mirror"].pressed
	cfg["round_ends"] = c["round_ends"]["option"].selected
	cfg["seams"] = c["seams"]["option"].selected
	cfg["profile"] = c["profile"]["option"].selected
	if c["full"]:
		cfg["curve"] = float(c["curve"]["spin"].value)
		cfg["ridge_offset"] = float(c["ridge_offset"]["spin"].value)
		cfg["scale"] = float(c["scale"]["spin"].value)
		cfg["edge"] = float(c["edge"]["spin"].value)
		cfg["u_offset"] = float(c["u_offset"]["spin"].value)
		cfg["merge_height"] = float(c["merge_height"]["spin"].value)
		for vk in ["valley_line", "valley_opacity", "valley_width"]:
			cfg[vk] = float(c[vk]["spin"].value)
		cfg["pitch"] = float(c["pitch"]["spin"].value)
		cfg["size_link"] = c["links"][0].pressed
		cfg["shade"] = float(c["shade"]["spin"].value) / 100.0
		cfg["light"] = float(c["light"]["spin"].value)
		cfg["taper"] = c["taper"].pressed
		cfg["repeat"] = float(c["repeat"]["spin"].value)
		cfg["apex_on"] = c["apex_on"].pressed
		cfg["shade_on"] = c["shade_on"].pressed
		cfg["merge"] = c["merge"].pressed
		cfg["side_ink"] = c["side_ink"].pressed
		cfg["cap_outline"] = c["cap_outline"]["option"].selected
		cfg["cap_width"] = float(c["cap_wvals"][1])
		cfg["cap_width_hip"] = float(c["cap_wvals"][0])
		cfg["cap_width_on"] = c["cap_width_on"]["option"].selected
		cfg["cap_bright"] = float(c["cap_bright"]["spin"].value)
		cfg["cap_hue"] = float(c["cap_hue"]["spin"].value)
		cfg["cap_sat"] = float(c["cap_sat"]["spin"].value)
		cfg["cap_style"] = c["cap_style"]["option"].get_selected_id()
		cfg["cap_path_ridge"] = c["cap_path_ridge"]["path"]
		cfg["cap_path_hip"] = c["cap_path_hip"]["path"]
		cfg["cap_corners"] = c["cap_corners"]["option"].selected
		cfg["cap_tip"] = float(c["cap_tip"]["spin"].value)
		cfg["ridge_ends"] = c["ridge_ends"]["option"].selected
		cfg["cap_recolor"] = c["cap_recolor"].pressed
		cfg["cap_recolor_on"] = c["cap_recolor_on"]["option"].selected
		cfg["cap_fade"] = float(c["cap_fade"]["spin"].value)
		cfg["apex_x"] = float(c["apex_x"].value) / 100.0
		cfg["apex_y"] = float(c["apex_y"].value) / 100.0
		cfg["apex_lock"] = c["apex_lock"].pressed
	return cfg


func _update_visibility(section: String) -> void:
	var c = _ui.get(section)
	if c == null or not is_instance_valid(c["root"]):
		return
	c["opts"].visible = c["header"].pressed
	if c.get("clip") != null:
		c["clip"].get_child(0).disabled = not c["header"].pressed
	var mode = _ui_mode(section)
	c["mirror"].visible = mode == MODE_FILL
	c["round_ends"]["row"].visible = mode == MODE_FILL and c["mirror"].pressed
	# Seams: wherever the roof has ridge / hip lines; Ridge Caps only on Hip
	# and Gap Free with Two Slopes.
	var caps_ok = mode == MODE_HIP or (mode == MODE_FILL and c["mirror"].pressed)
	c["seams"]["row"].visible = mode != MODE_FILL or c["mirror"].pressed
	c["seams"]["option"].set_item_disabled(SEAMS_CAPS, not caps_ok)
	if c.has("cap_style") and section == "select":
		# Roof Pieces only for textures that have them (all the selection).
		var pieces_ok = not _sel_shapes.empty()
		for sh in _sel_shapes:
			if _is_pattern_shape(sh) and not (sh.material is ShaderMaterial and _has_pieces(sh.material.get_shader_param("albedo"))):
				pieces_ok = false
				break
		var cso = c["cap_style"]["option"]
		cso.set_item_disabled(cso.get_item_index(3), not pieces_ok)
		if not pieces_ok and cso.get_selected_id() == 3:
			cso.select(0)
			if not _updating_ui:
				_apply_fields(section, {"cap_style": 0})
	c["profile"]["row"].visible = mode == MODE_CENTER
	if c.has("curve"):
		c["curve"]["row"].visible = mode == MODE_CENTER and c["profile"]["option"].selected != PROFILE_CONE
	var caps_on = caps_ok and c["seams"]["option"].selected == SEAMS_CAPS
	if not c["full"]:
		return
	var shaded = mode != MODE_FILL or c["mirror"].pressed
	c["ridge_offset"]["row"].visible = mode == MODE_FILL and c["mirror"].pressed
	c["taper"].visible = mode == MODE_CENTER
	c["pitch"]["row"].visible = true
	c["u_offset"]["row"].visible = mode == MODE_FILL
	# Greyed while Merge is OFF, settings hidden.
	c["merge_cog"].disabled = not c["merge"].pressed
	c["merge_cog"].modulate = Color(1, 1, 1, 1) if c["merge"].pressed else Color(1, 1, 1, 0.35)
	c["merge_box"].visible = c["merge"].pressed and c["merge_cog"].pressed
	c["side_ink"].visible = true
	# Seams cog: greyed except for Ridge Caps.
	c["seams_cog"].disabled = not caps_on
	c["seams_cog"].modulate = Color(1, 1, 1, 1) if caps_on else Color(1, 1, 1, 0.35)
	c["cap_box"].visible = caps_on and c["seams_cog"].pressed
	var mitred = c["ridge_ends"]["option"].selected == 0
	c["ridge_cog"].disabled = not mitred
	c["ridge_cog"].modulate = Color(1, 1, 1, 1) if mitred else Color(1, 1, 1, 0.35)
	c["cap_fade"]["row"].visible = mitred and c["ridge_cog"].pressed
	c["cap_tip"]["row"].visible = c["corners_cog"].pressed
	var path_on = c["cap_style"]["option"].get_selected_id() == CAP_PATH
	# Gap Free (Two Slopes): a ridge, no hips.
	var hips = mode != MODE_FILL
	c["cap_path_ridge"]["row"].visible = path_on
	c["cap_path_hip"]["row"].visible = path_on and hips
	c["cap_width_on"]["row"].visible = hips
	for k in ["cap_bright", "cap_hue", "cap_sat"]:
		c[k]["row"].visible = c["cap_recolor"].pressed
	# (Gap Free: a ridge only)
	c["cap_recolor_on"]["row"].visible = c["cap_recolor"].pressed and mode != MODE_FILL
	c["tex_box"].visible = c["tex_cog"].pressed
	c["shade_on"].visible = shaded
	c["shade_sep"].visible = shaded
	c["global_light"].visible = shaded and c["shade_on"].pressed
	c["merge"].visible = true
	c["shade"]["row"].visible = shaded and c["shade_on"].pressed
	c["light"]["row"].visible = shaded and c["shade_on"].pressed
	c["apex_on"].visible = mode == MODE_CENTER
	c["apex_box"].visible = mode == MODE_CENTER and c["apex_on"].pressed


# ── Cap Style Path: Path Tool textures ──

# Path Tool textures seen in its list (path -> texture): kept, so a search in
# the Path Tool does not hide any from the picker.
var _paths_seen = {}
var _path_pop = null
var _path_pop_list = null
var _path_pop_search = null
var _path_pop_target = []
var _path_pop_same = null


func _path_items() -> Array:
	var grid = _grid_menu("PathTool", false)
	if grid != null:
		for i in range(grid.get_item_count()):
			var m = grid.get_item_metadata(i)
			var ic = grid.get_item_icon(i)
			if m is String and m != "" and ic is Texture:
				_paths_seen[m] = ic
	var out = _paths_seen.keys()
	out.sort_custom(self, "_path_name_less")
	return out


func _path_name_less(a, b) -> bool:
	return _path_name(a).nocasecmp_to(_path_name(b)) < 0


func _path_name(path: String) -> String:
	return path.get_file().get_basename().capitalize()


# The texture of a Path Tool asset (DD's own when it has it: tiled, as paths
# need).
func _path_tex(path: String):
	if path == "" or path == PATH_SAME_HIP:
		return null
	if not _paths_seen.has(path):
		_path_items()
	var t = _paths_seen.get(path)
	if t is Texture and (t.flags & Texture.FLAG_REPEAT) != 0 and t.resource_path == path:
		return t
	return _load_asset_tex(path, true)


func _make_path_pick(parent: Node, text: String, tip: String, section: String, field: String) -> Dictionary:
	var row = HBoxContainer.new()
	parent.add_child(row)
	var lbl = Label.new()
	lbl.text = text
	lbl.hint_tooltip = tip
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(lbl)
	var b = Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.hint_tooltip = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	b.align = Button.ALIGN_LEFT
	b.connect("pressed", self, "_open_path_pop", [section, field])
	# A framed box: clearly something to click.
	for st in [["normal", 0.06, 0.28], ["hover", 0.14, 0.5], ["pressed", 0.2, 0.6], ["focus", 0.06, 0.28], ["disabled", 0.03, 0.15]]:
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, st[1])
		sb.border_color = Color(1, 1, 1, st[2])
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_top = 3
		sb.content_margin_bottom = 3
		b.add_stylebox_override(st[0], sb)
	row.add_child(b)
	return {"row": row, "button": b, "path": ""}


func _set_path_pick(pick: Dictionary, path: String, hip: bool) -> void:
	pick["path"] = path
	var b: Button = pick["button"]
	if path == "" or path == PATH_SAME_HIP:
		b.text = "Same as Ridge" if hip else ("Same as Hip" if path == PATH_SAME_HIP else "Choose...")
		b.icon = null
	else:
		b.text = _path_name(path)
		var t = _paths_seen.get(path)
		if t == null:
			t = _path_tex(path)
		b.icon = _path_thumb(t)
	b.hint_tooltip = path if path != "" else b.text


# Small preview of a path texture for the button (its middle, 72 x 18).
var _thumb_cache = {}

func _path_thumb(t):
	if not (t is Texture) or t.get_height() <= 0:
		return null
	var id = t.get_instance_id()
	if _thumb_cache.has(id):
		return _thumb_cache[id]
	var out = null
	var img = t.get_data()
	if img != null and not img.is_empty():
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		var h = img.get_height()
		var w = min(img.get_width(), h * 4)
		img = img.get_rect(Rect2(0, 0, w, h))
		img.resize(int(max(18.0 * w / h, 1.0)), 18, Image.INTERPOLATE_LANCZOS)
		out = ImageTexture.new()
		out.create_from_image(img, Texture.FLAG_FILTER)
	_thumb_cache[id] = out
	return out


func _open_path_pop(section: String, field: String) -> void:
	var c = _ui.get(section)
	if c == null:
		return
	if _path_pop == null or not is_instance_valid(_path_pop):
		_path_pop = WindowDialog.new()
		_path_pop.window_title = "Choose a Path"
		_path_pop.resizable = true
		var vb = VBoxContainer.new()
		vb.anchor_right = 1.0
		vb.anchor_bottom = 1.0
		vb.margin_left = 8
		vb.margin_top = 8
		vb.margin_right = -8
		vb.margin_bottom = -8
		_path_pop.add_child(vb)
		_path_pop_search = LineEdit.new()
		_path_pop_search.placeholder_text = "Search..."
		_path_pop_search.clear_button_enabled = true
		_path_pop_search.connect("text_changed", self, "_fill_path_pop")
		_path_pop_search.connect("focus_entered", self, "_on_text_focus", [true])
		_path_pop_search.connect("focus_exited", self, "_on_text_focus", [false])
		vb.add_child(_path_pop_search)
		# Same as Ridge / Same as Hip: out of the list, always in view.
		_path_pop_same = Button.new()
		_path_pop_same.focus_mode = Control.FOCUS_NONE
		_path_pop_same.connect("pressed", self, "_on_path_pop_same")
		vb.add_child(_path_pop_same)
		_path_pop_list = ItemList.new()
		_path_pop_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_path_pop_list.max_columns = 1
		_path_pop_list.fixed_icon_size = Vector2(256, 40)
		_path_pop_list.icon_mode = ItemList.ICON_MODE_LEFT
		_path_pop_list.connect("item_selected", self, "_on_path_pop_pick")
		vb.add_child(_path_pop_list)
		_path_pop.connect("popup_hide", self, "_on_text_focus", [false])
		# Under the Roof Builder section: DD's theme.
		c["root"].add_child(_path_pop)
	_path_pop_target = [section, field]
	# (the search is kept from one opening to the next)
	_fill_path_pop(_path_pop_search.text)
	_path_pop.popup_centered(Vector2(460, 560))
	_path_pop_search.grab_focus()


func _fill_path_pop(text: String) -> void:
	_path_pop_list.clear()
	var hip = _path_pop_target.size() > 1 and _path_pop_target[1] == "cap_path_hip"
	var terms = []
	for t in text.to_lower().split(" ", false):
		terms.append(t)
	# Always on top: Same as Ridge (Hip Path), Same as Hip (Ridge Path, once
	# the Hip Path is set, on roofs with hips).
	var c = _ui.get(_path_pop_target[0]) if not _path_pop_target.empty() else null
	if hip:
		_path_pop_same.text = "Same as Ridge"
		_path_pop_same.visible = true
	else:
		_path_pop_same.text = "Same as Hip"
		_path_pop_same.visible = c != null and c["cap_path_hip"]["path"] != "" and _ui_mode(_path_pop_target[0]) != MODE_FILL
	for path in _path_items():
		var name = _path_name(path)
		var key = path.to_lower()
		var ok = true
		for t in terms:
			if key.find(t) < 0:
				ok = false
				break
		if not ok:
			continue
		_path_pop_list.add_item(name, _paths_seen.get(path))
		var i = _path_pop_list.get_item_count() - 1
		_path_pop_list.set_item_metadata(i, path)
		_path_pop_list.set_item_tooltip(i, path)


func _on_path_pop_same() -> void:
	_path_pop_apply("" if _path_pop_target[1] == "cap_path_hip" else PATH_SAME_HIP)


func _on_path_pop_pick(index: int) -> void:
	_path_pop_apply(str(_path_pop_list.get_item_metadata(index)))


func _path_pop_apply(path: String) -> void:
	var section = _path_pop_target[0]
	var field = _path_pop_target[1]
	_path_pop.hide()
	var c = _ui.get(section)
	if c == null:
		return
	_set_path_pick(c[field], path, field == "cap_path_hip")
	_apply_fields(section, {field: path})


func _on_text_focus(on: bool) -> void:
	if _g != null and _g.Editor != null:
		_g.Editor.set("SearchHasFocus", on)


func _on_text_entered(_text, le) -> void:
	if is_instance_valid(le):
		le.release_focus()


func _on_enabled_toggled(pressed: bool, section: String) -> void:
	_update_visibility(section)
	if _updating_ui:
		return
	if section == "tool":
		_tool_cfg["enabled"] = pressed
		return
	var store = _get_store()
	if store == null:
		return
	_roof_cache = null
	for shape in _sel_shapes:
		if not _is_pattern_shape(shape):
			continue
		var key = _key_of(shape)
		if key == "":
			continue
		if pressed:
			var cfg = _full_cfg(store[key]) if store.has(key) else _read_ui_cfg("select")
			store[key] = cfg
			_sync_shape(shape, key, cfg)
		else:
			if store.has(key):
				store.erase(key)
			_restore_shape(shape, key)


func _on_mode_pressed(mode: int, section: String) -> void:
	_update_visibility(section)
	if _updating_ui:
		return
	if section == "tool":
		_tool_cfg["mode"] = mode
		return
	_apply_fields(section, {"mode": mode})


func _on_toggle_changed(pressed: bool, section: String, field: String) -> void:
	_update_visibility(section)
	if _updating_ui:
		return
	if section == "tool":
		_tool_cfg[field] = pressed
		return
	if field == "global_light":
		_on_global_light(pressed)
		return
	_apply_fields(section, {field: pressed})


# Turning Global Lighting on starts from the light shown (no jump); turning it
# off gives each roof its own light back.
func _on_global_light(pressed: bool) -> void:
	var c = _ui.get("select")
	if c == null:
		return
	if pressed:
		_set_global_light({"on": true, "shade": float(c["shade"]["spin"].value) / 100.0,
			"light": float(c["light"]["spin"].value)})
		return
	_set_global_light({"on": false})
	var store = _get_store()
	if store != null and not _sel_shapes.empty():
		var key = _key_of(_sel_shapes[0])
		if key != "" and store.has(key):
			_set_ui_values("select", store[key], true)


func _on_value_changed(value: float, section: String, field: String, source: String) -> void:
	if _updating_ui:
		return
	var c = _ui.get(section)
	if c == null or not c.has(field):
		return
	_updating_ui = true
	if source == "slider":
		c[field]["spin"].value = value
	else:
		c[field]["slider"].value = value
	_updating_ui = false
	var v = float(value)
	if section == "tool":
		_tool_cfg[field] = v
		return
	if field == "shade":
		v = v / 100.0
	if section == "select" and (field == "shade" or field == "light") and _global_light()["on"]:
		_set_global_light({field: v})
		return
	_apply_fields(section, _linked(section, field, v))


# Tile Width and Pitch linked: width = k * cos(pitch), k taken when linked.
func _linked(section: String, field: String, v: float) -> Dictionary:
	var out = {field: v}
	var c = _ui.get(section)
	if field == "cap_wsl":
		# Width slider: Hip, Ridge or Both (ratio kept); Gap Free: ridge.
		out = {}
		var on = _wsl_on(section)
		var vals = c["cap_wvals"] if c != null and c.has("cap_wvals") else [v, v]
		if on == 0:
			vals[0] = v
		elif on == 1:
			vals[1] = v
		else:
			var k = vals[0] / max(vals[1], 1.0)
			vals[1] = v
			vals[0] = clamp(v * k, 30.0, 300.0)
		# (only the widths the slider sizes)
		if on != 1:
			out["cap_width_hip"] = vals[0]
		if on != 0:
			out["cap_width"] = vals[1]
		return out
	if c == null or not c.has("links") or not c["links"][0].pressed or not (field == "scale" or field == "pitch"):
		return out
	_updating_ui = true
	if field == "scale":
		var p = rad2deg(acos(clamp(v / max(_link_k, 0.001), 0.0, 1.0)))
		p = clamp(p, 0.0, 70.0)
		out["pitch"] = p
		_set_ctl(c["pitch"], p)
	else:
		var w = clamp(_link_k * cos(deg2rad(v)), 10.0, 400.0)
		out["scale"] = w
		_set_ctl(c["scale"], w)
	_updating_ui = false
	return out


func _link_take(section: String) -> void:
	var c = _ui.get(section)
	if c == null or not c.has("scale"):
		return
	_link_k = float(c["scale"]["spin"].value) / max(cos(deg2rad(float(c["pitch"]["spin"].value))), 0.05)


# Which caps the Width slider sizes (Gap Free: the ridge).
func _wsl_on(section: String) -> int:
	var c = _ui.get(section)
	if c == null or not c.has("cap_width_on") or _ui_mode(section) == MODE_FILL:
		return 1
	return c["cap_width_on"]["option"].selected


# Width slider: shows the hips' width (Hip) or the ridges' (Ridge, Both).
func _wsl_show(section: String) -> void:
	var c = _ui.get(section)
	if c == null or not c.has("cap_wsl"):
		return
	var was = _updating_ui
	_updating_ui = true
	_set_ctl(c["cap_wsl"], c["cap_wvals"][0] if _wsl_on(section) == 0 else c["cap_wvals"][1])
	_updating_ui = was


func _on_link_toggled(pressed: bool, section: String) -> void:
	var c = _ui.get(section)
	if c == null:
		return
	if not _updating_ui:
		_updating_ui = true
		for lb in c["links"]:
			lb.pressed = pressed
		_updating_ui = false
		_link_take(section)
		_apply_fields(section, {"size_link": pressed})


func _on_reset_pressed(section: String, field: String) -> void:
	var c = _ui.get(section)
	if c == null or not c.has(field):
		return
	var v = float(DEFAULT_CFG.get(field, 100.0))
	_updating_ui = true
	_set_ctl(c[field], v * 100.0 if field == "shade" else v)
	_updating_ui = false
	if section == "tool":
		_tool_cfg[field] = v
		return
	if section == "select" and (field == "shade" or field == "light") and _global_light()["on"]:
		_set_global_light({field: v})
		return
	_apply_fields(section, _linked(section, field, v))


func _on_apex_spin(_value, section: String) -> void:
	if _updating_ui:
		return
	var c = _ui.get(section)
	_clear_snaps(c)
	var ax = float(c["apex_x"].value) / 100.0
	var ay = float(c["apex_y"].value) / 100.0
	_set_dial(c, ax, ay)
	_apply_fields(section, {"apex_x": ax, "apex_y": ay})


func _set_lock_icon(c: Dictionary) -> void:
	var ic = c["icon_lock"] if c["apex_lock"].pressed else c["icon_unlock"]
	if ic != null:
		c["apex_lock"].icon = ic


func _on_apex_lock(pressed: bool, section: String) -> void:
	var c = _ui.get(section)
	if c == null:
		return
	_set_lock_icon(c)
	if _updating_ui:
		return
	_apply_fields(section, {"apex_lock": pressed})


func _on_apex_reset(section: String) -> void:
	_commit_apex(section, 0.0, 0.0)


func _on_dial_input(event: InputEvent, dial: Control, section: String) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		dial.set_meta("dragging", event.pressed)
		if event.pressed:
			_dial_from_mouse(event.position, section)
	elif event is InputEventMouseMotion and dial.get_meta("dragging"):
		_dial_from_mouse(event.position, section)


func _dial_from_mouse(pos: Vector2, section: String) -> void:
	var c = _ui.get(section)
	if c == null or not c.has("dial"):
		return
	var radius = DIAL_SIZE / 2.0
	var ctr = radius + DIAL_PAD
	var d = (pos - Vector2(ctr, ctr)) / radius
	var snap = int(c["dial"].get_meta("snap"))
	if snap >= 0:
		# Locked on a 45° direction: only the distance follows the mouse.
		var dir = _snap_dir(snap)
		d = dir * clamp(d.dot(dir), 0.0, 1.0)
	elif d.length() > 1.0:
		d = d.normalized()
	_commit_apex(section, d.x, d.y)


func _commit_apex(section: String, ax: float, ay: float) -> void:
	var c = _ui.get(section)
	if c == null or not c.has("dial"):
		return
	ax = clamp(round(ax * 100.0) / 100.0, -1.0, 1.0)
	ay = clamp(round(ay * 100.0) / 100.0, -1.0, 1.0)
	_updating_ui = true
	c["apex_x"].value = ax * 100.0
	c["apex_y"].value = ay * 100.0
	_updating_ui = false
	_set_dial(c, ax, ay)
	_apply_fields(section, {"apex_x": ax, "apex_y": ay})


# Select Tool only: changes settings on every selected roof shape.
func _apply_fields(section: String, fields: Dictionary) -> void:
	if section != "select":
		return
	var c = _ui.get(section)
	if c == null or not c["header"].pressed:
		return
	var store = _get_store()
	if store == null:
		return
	_roof_cache = null
	for shape in _sel_shapes:
		if not _is_pattern_shape(shape):
			continue
		var key = _key_of(shape)
		if key == "":
			continue
		var cfg = _full_cfg(store[key]) if store.has(key) else _read_ui_cfg("select")
		for f in fields.keys():
			cfg[f] = fields[f]
		cfg = _full_cfg(cfg)
		store[key] = cfg
		_sync_shape(shape, key, cfg)


# ── Select Tool section ───────────────────────────────────────────────────────

func _update_selection(store: Dictionary) -> void:
	var c = _ui.get("select")
	if c == null or not is_instance_valid(c["root"]):
		return
	if _active_tool() != "SelectTool":
		if c["root"].visible:
			c["root"].visible = false
		_sel_sig = ""
		_sel_shapes = []
		return
	if _select_tool == null or not is_instance_valid(_select_tool):
		var tools = _g.Editor.get("Tools")
		if tools == null:
			return
		_select_tool = tools.get("SelectTool")
		if _select_tool == null:
			return
	var sel = _select_tool.get("Selected")
	var shapes = []
	var sig = ""
	if sel != null:
		for nd in sel:
			if nd == null or not is_instance_valid(nd):
				continue
			if _is_pattern_shape(nd):
				shapes.append(nd)
				sig += str(nd.get_instance_id()) + ","
	var show = shapes.size() > 0
	if c["root"].visible != show:
		c["root"].visible = show
	# Texture changed on the selection (same shapes): Cap Style's Roof
	# Pieces follows it.
	var tsig = ""
	for sh in shapes:
		var m = sh.material
		var t = m.get_shader_param("albedo") if m is ShaderMaterial else null
		tsig += str(t.get_instance_id() if t != null else 0) + ","
	if tsig != _sel_tex_sig:
		_sel_tex_sig = tsig
		if sig == _sel_sig and c["header"].pressed:
			_sel_shapes = shapes
			_update_visibility("select")
	if sig == _sel_sig:
		return
	_sel_sig = sig
	_sel_shapes = shapes
	if shapes.empty():
		return
	# Remember the selected roofs: a copy (or cut) is always made from the
	# current selection.
	_copy_refs = []
	for sh in shapes:
		var k = _key_of(sh)
		if k != "" and store.has(k):
			_copy_refs.append({"key": k, "sig": _shape_sig(sh), "tex": _tex_path(sh), "cfg": _full_cfg(store[k])})
	var key = _key_of(shapes[0])
	if key != "" and store.has(key):
		_set_ui_values("select", store[key], true)
	else:
		var cfg = _full_cfg({})
		cfg["mode"] = int(_tool_cfg.get("mode", MODE_FILL))
		cfg["mirror"] = bool(_tool_cfg.get("mirror", false))
		cfg["round_ends"] = int(_tool_cfg.get("round_ends", 0))
		cfg["merge"] = bool(_tool_cfg.get("merge", false))
		cfg["seams"] = int(_tool_cfg.get("seams", SEAMS_SOFT))
		cfg["profile"] = int(_tool_cfg.get("profile", PROFILE_CONE))
		_set_ui_values("select", cfg, false)


# ── Tool settings persistence ─────────────────────────────────────────────────

# Pattern Tool settings back to their defaults (every map opened).
func _reset_tool_cfg() -> void:
	_tool_cfg = TOOL_DEFAULTS.duplicate()
	var cfg = _full_cfg({})
	cfg["mode"] = int(_tool_cfg["mode"])
	_set_ui_values("tool", cfg, false)


# ── Roof Tool textures (pattern lists and roof pieces) ──────────────────────
#
# Asset packs can give their roofs to DD's Roof Tool instead of (or as well as)
# the Pattern Tool: textures/roofs/<name>/tiles.* with edge / ridge / hip
# strips beside it. "Auto Roof Library" adds those tiles textures to
# the pattern lists (minus the ones also given as patterns: same file), and a
# roof whose texture is one of them gets the ridge and hip strips as its
# Ridge Caps.

const ROOF_IMG_EXTS = ["png", "webp", "jpg", "jpeg"]

var _lib_built = false
var _lib_by_md5 = {}          # tiles file md5 -> tiles path (every Roof Tool texture)
var _lib_lens = {}            # their file sizes
var _lib_by_name = {}         # roof folder name (see _name_key) -> tiles path
var _pieces_cache = {}        # texture path -> {ridge, hip, edge} (textures or null)


var _asset_script = null


# Asset list of a category through DD's Script API (null outside DD).
func _asset_list(category: String):
	if _asset_script == null:
		_asset_script = GDScript.new()
		_asset_script.source_code = "static func get_list(c):\n\treturn Script.GetAssetList(c)\n"
		if _asset_script.reload() != OK:
			_asset_script = false
	if not (_asset_script is GDScript):
		return null
	return _asset_script.get_list(category)


func _file_exts_in(dir_path: String) -> Dictionary:
	# file name (without .import) -> full path, for one folder.
	var out = {}
	var d = Directory.new()
	if d.open(dir_path) != OK:
		return out
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if not d.current_is_dir():
			var name = f.trim_suffix(".import")
			out[name] = dir_path.plus_file(name)
		f = d.get_next()
	d.list_dir_end()
	return out


func _sub_dirs(dir_path: String) -> Array:
	var out = []
	var d = Directory.new()
	if d.open(dir_path) != OK:
		return out
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if d.current_is_dir():
			out.append(dir_path.plus_file(f))
		f = d.get_next()
	d.list_dir_end()
	return out


# tiles.* path of a roof folder (or the path itself when it is the tiles file).
func _tiles_path(p: String) -> String:
	if p.get_extension().to_lower() in ROOF_IMG_EXTS:
		return p
	var files = _file_exts_in(p)
	for e in ROOF_IMG_EXTS:
		if files.has("tiles." + e):
			return files["tiles." + e]
	return ""


func _roof_tiles_paths() -> Array:
	var out = []
	# The Roof Tool's own list first (only the packs in use).
	var rg = _grid_menu("RoofTool", false)
	if rg != null and rg.get_item_count() > 0:
		for i in range(rg.get_item_count()):
			var m = rg.get_item_metadata(i)
			if m is String and m != "":
				var t0 = _tiles_path(m)
				if t0 != "" and not t0 in out:
					out.append(t0)
		return out
	var lst = _asset_list("Roofs")
	if lst != null:
		for p in lst:
			var t = _tiles_path(str(p))
			if t != "" and not t in out:
				out.append(t)
		return out
	# Outside DD (or an older DD): look through the folders.
	var roots = ["res://textures/roofs"]
	for pk in _sub_dirs("res://packs"):
		roots.append(pk.plus_file("textures/roofs"))
	for r in roots:
		for rd in _sub_dirs(r):
			var t = _tiles_path(rd)
			if t != "":
				out.append(t)
	return out


var _len_cache = {}


func _file_len(path: String) -> int:
	if _len_cache.has(path):
		return _len_cache[path]
	var n = -1
	var f = File.new()
	if f.open(path, File.READ) == OK:
		n = f.get_len()
		f.close()
	_len_cache[path] = n
	return n


# Roof Tool textures by file content (md5 -> tiles path), to find the roof
# pieces of a texture also given as a pattern.
func _lib_build() -> void:
	if _lib_built:
		return
	var tiles = _roof_tiles_paths()
	if tiles.empty():
		return
	_lib_built = true
	_lib_by_md5 = {}
	_lib_lens = {}
	_lib_by_name = {}
	var f = File.new()
	for t in tiles:
		_lib_by_name[_name_key(t.get_base_dir().get_file())] = t
		var n = _file_len(t)
		if n > 0:
			var m = f.get_md5(t)
			if m != "":
				_lib_by_md5[m] = t
				_lib_lens[n] = true


# A texture from an asset path, shared with DD when it already loaded it (the
# path is what maps save).
func _load_asset_tex(path: String, repeat: bool = true):
	if path == "":
		return null
	if ResourceLoader.has_cached(path):
		var c = ResourceLoader.load(path)
		if c is Texture:
			return c
	if path.begins_with("res://textures/") and ResourceLoader.exists(path):
		var r = ResourceLoader.load(path, "Texture")
		if r is Texture:
			return r
	var img = Image.new()
	if img.load(path) != OK:
		if ResourceLoader.exists(path):
			return ResourceLoader.load(path, "Texture")
		return null
	var tex = ImageTexture.new()
	var flags = Texture.FLAG_MIPMAPS | Texture.FLAG_FILTER
	if repeat:
		flags |= Texture.FLAG_REPEAT
	tex.create_from_image(img, flags)
	tex.take_over_path(path)
	return tex


# Ridge / hip / edge strips of a roof texture: from its Roof Tool folder, or
# found through the file when the same texture is also given as a pattern.
func _roof_pieces(tex: Texture) -> Dictionary:
	if tex == null or tex.resource_path == "":
		return {}
	var path = tex.resource_path
	if _pieces_cache.has(path):
		return _pieces_cache[path]
	var out = {}
	var tiles = ""
	if path.get_file().get_basename() == "tiles" and path.get_base_dir().get_base_dir().get_file() == "roofs":
		tiles = path
	else:
		_lib_build()
		if not _lib_built:
			# The Roof Tool's list is not there yet: try again later.
			return out
		if _file_len(path) > 0:
			tiles = _lib_by_md5.get(File.new().get_md5(path), "")
		if tiles == "":
			# DD's own assets are imported (no file to compare): by name.
			tiles = _lib_by_name.get(_name_key(path.get_file().get_basename()), "")
	_pieces_cache[path] = out
	if tiles == "":
		return out
	var files = _file_exts_in(tiles.get_base_dir())
	for piece in ["ridge", "hip", "edge"]:
		# As DD finds them: beside the tiles, same extension first.
		var exts = [tiles.get_extension()] + ROOF_IMG_EXTS
		for e in exts:
			var cand = tiles.get_base_dir().plus_file(piece + "." + e)
			if files.has(piece + "." + e) or ResourceLoader.exists(cand) or File.new().file_exists(cand):
				var pt = _load_asset_tex(cand, true)
				if pt != null and pt.get_height() > 0:
					out[piece] = pt
					break
	return out


# Name of a texture reduced to letters and digits, lower case.
func _name_key(n: String) -> String:
	var out = ""
	for ch in n.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


var _vis_cache = {}


# Rows of a strip texture (0..1) where it is mostly opaque.
func _strip_vis(tex: Texture) -> Vector2:
	var id = tex.get_instance_id()
	if _vis_cache.has(id):
		return _vis_cache[id]
	var out = Vector2(0, 1)
	var img = tex.get_data()
	if img != null and not img.is_empty():
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var w = img.get_width()
		var h = img.get_height()
		var px = img.get_data()
		var step = max(1, w / 64)
		var lo = -1
		var hi = -1
		for y in range(h):
			var sa = 0
			var n = 0
			for x in range(0, w, step):
				sa += px[(y * w + x) * 4 + 3]
				n += 1
			if float(sa) / (255.0 * n) > 0.5:
				if lo < 0:
					lo = y
				hi = y
		if lo >= 0:
			out = Vector2(float(lo) / h, float(hi + 1) / h)
	_vis_cache[id] = out
	return out


# Thickness of the dark line along the sides of a Roof Tool strip (share of
# its height): rows darker than half the strip's middle, from each edge of its
# visible part in.
var _ink_cache = {}

func _strip_ink(tex: Texture) -> float:
	var id = tex.get_instance_id()
	if _ink_cache.has(id):
		return _ink_cache[id]
	var out = 0.0
	var vis = _strip_vis(tex)
	var img = tex.get_data()
	if img != null and not img.is_empty():
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var w = img.get_width()
		var h = img.get_height()
		var px = img.get_data()
		var step = max(1, w / 64)
		var lo = int(vis.x * h)
		var hi = int(vis.y * h) - 1
		var lum = []
		for y in range(lo, hi + 1):
			var sl = 0.0
			var n = 0
			for x in range(0, w, step):
				var i = (y * w + x) * 4
				if px[i + 3] > 127:
					sl += 0.3 * px[i] + 0.59 * px[i + 1] + 0.11 * px[i + 2]
					n += 1
			lum.append(sl / n if n > 0 else 0.0)
		if lum.size() >= 6:
			var mid = lum.duplicate()
			mid.sort()
			var ref = float(mid[mid.size() / 2])
			var t = 0
			while t < lum.size() / 3 and lum[t] < ref * 0.5:
				t += 1
			var b = 0
			while b < lum.size() / 3 and lum[lum.size() - 1 - b] < ref * 0.5:
				b += 1
			out = (t + b) * 0.5 / float(h)
	_ink_cache[id] = out
	return out


# ── Roof Tool textures in the pattern lists ──
#
# The pattern lists (Pattern Tool and Select Tool) get the Roof Tool's own
# list items appended (same thumbnails, names and paths), minus the files
# already given as patterns. DD's list does not know these items: clicks on
# them are taken before it (gui_input comes first) and applied here.

const LIB_SETTINGS = "user://better_roof_patterns_settings.json"

var _lib_on = false
var _lib_dirty = false        # items to take out of the lists (turned off)
var _lib_loaded = false
var _lib_grids = {}           # pattern list -> "tool" / "select"


func _lib_load_settings() -> void:
	if _lib_loaded:
		return
	_lib_loaded = true
	var f = File.new()
	if f.file_exists(LIB_SETTINGS) and f.open(LIB_SETTINGS, File.READ) == OK:
		var res = JSON.parse(f.get_as_text())
		f.close()
		if res.error == OK and res.result is Dictionary:
			_lib_on = bool(res.result.get("roof_tool_library", false))


func _lib_save_settings() -> void:
	var f = File.new()
	if f.open(LIB_SETTINGS, File.WRITE) == OK:
		f.store_string(JSON.print({"roof_tool_library": _lib_on}))
		f.close()


func _on_lib_toggled(pressed: bool) -> void:
	if pressed == _lib_on:
		return
	_lib_on = pressed
	_lib_dirty = true
	_lib_logged = false
	_lib_save_settings()
	for sec in ["tool", "select"]:
		var c = _ui.get(sec)
		if c != null and c.has("lib") and is_instance_valid(c["lib"]) and c["lib"].pressed != pressed:
			c["lib"].pressed = pressed
	_lib_sync()


const LIB_MARK = "\n(Roof Tool)"


# The texture lists (GridMenu) of a tool panel; patterns: only those listing
# pattern textures.
const LIB_CONTROLS = {"PatternShapeTool": "Texture", "SelectTool": "PatternTexture", "RoofTool": "Texture", "PathTool": "Texture"}


func _grid_menus(tool_name: String, patterns: bool) -> Array:
	var out = []
	if _g == null or _g.Editor == null or _g.Editor.get("Toolset") == null:
		return out
	# The list registered by DD (found even when another mod moved it out of
	# the tool panel).
	var tools = _g.Editor.get("Tools")
	var tl = tools.get(tool_name) if tools is Dictionary else null
	var controls = tl.get("Controls") if tl != null else null
	if controls is Dictionary:
		var ctl = controls.get(LIB_CONTROLS.get(tool_name, ""))
		if ctl is ItemList and is_instance_valid(ctl):
			out.append(ctl)
			return out
	var panel = _g.Editor.Toolset.GetToolPanel(tool_name)
	if panel == null:
		return out
	var stack = [panel]
	while not stack.empty():
		var n = stack.pop_back()
		if n is ItemList:
			# DD's texture lists keep each item's file path as metadata
			# (patterns come after the simple tiles: look through all).
			var key = "/patterns/" if patterns else "/roofs/"
			for i in range(n.get_item_count()):
				var m = n.get_item_metadata(i)
				if m is String and m.find(key) >= 0:
					out.append(n)
					break
		for ch in n.get_children():
			stack.push_back(ch)
	return out


func _grid_menu(tool_name: String, patterns: bool):
	var l = _grid_menus(tool_name, patterns)
	return l[0] if not l.empty() else null


# Roof Tool list items not already given as patterns: [{path, icon, tip}].
func _roof_items(pattern_paths: Array) -> Array:
	var out = []
	_lib_stats = [0, 0]
	var roof_grid = _grid_menu("RoofTool", false)
	if roof_grid == null:
		return out
	var f = File.new()
	var by_len = {}
	for p in pattern_paths:
		var n = _file_len(p)
		if n > 0:
			if not by_len.has(n):
				by_len[n] = []
			by_len[n].append(p)
	var seen = {}
	var pat_names = {}
	for p in pattern_paths:
		if _file_len(p) <= 0:
			pat_names[_name_key(p.get_file().get_basename())] = true
	_lib_stats = [roof_grid.get_item_count(), 0]
	for i in range(roof_grid.get_item_count()):
		var path = roof_grid.get_item_metadata(i)
		if not (path is String) or path == "" or pattern_paths.has(path):
			continue
		var n2 = _file_len(path)
		var m = f.get_md5(path) if n2 > 0 else path
		if seen.has(m):
			continue
		seen[m] = true
		var dup = false
		if by_len.has(n2):
			for p2 in by_len[n2]:
				if f.get_md5(p2) == m:
					dup = true
					break
		if not dup and n2 <= 0 and pat_names.has(_name_key(path.get_base_dir().get_file())):
			# DD's own (imported) assets: same name given as a pattern.
			dup = true
		if dup:
			_lib_stats[1] += 1
		else:
			out.append({"path": path, "icon": roof_grid.get_item_icon(i), "tip": roof_grid.get_item_tooltip(i)})
	return out


class LibInput:
	extends Node
	var mod = null
	func _input(event):
		if mod != null:
			mod._lib_input(event)


var _lib_listener = null
var _lib_logged = false
var _link_k = 100.0
var _sel_tex_sig = ""
var _lib_prev_color = null    # Pattern Tool colour while a Roof Tool texture is picked
var _lib_stats = [0, 0]       # Roof Tool textures, already given as patterns


# Auto Roof Library: while Roof Builder is on, the pattern lists only show
# roof textures: the patterns that are also Roof Tool textures (same file)
# or kept in a folder whose name has "roof" in it, then the Roof Tool
# textures given only to the Roof Tool. The full list comes back (in DD's order, so its own bookkeeping still matches) when
# Roof Builder is off. DD rebuilding a list (filters, assets) is noticed and
# filtered again. Roof Tool items are told apart by the end of their tooltip.
var _lib_state = {}           # pattern list -> {snap: [items], shown: [paths]}
var _roof_pat = {}            # pattern path -> counts as a roof


var _lib_icons = {}


# The Roof Tool's thumbnail, wrapped: DD's thumbnails carry a "thumbnail"
# meta, and on enabling the Pattern Tool DD looks every thumbnail of the list
# up among the patterns (IsTextureCustomColor): a Roof Tool one is not found
# there and the null path throws, which broke the tool panel switching. A
# new AtlasTexture shows the same picture with no meta and no path.
func _lib_icon(icon):
	if icon == null:
		return null
	var id = icon.get_instance_id()
	if _lib_icons.has(id) and is_instance_valid(_lib_icons[id]):
		return _lib_icons[id]
	var w = AtlasTexture.new()
	w.atlas = icon
	w.region = Rect2(Vector2.ZERO, icon.get_size())
	_lib_icons[id] = w
	return w


func _item_data(grid, i: int) -> Dictionary:
	var mod = grid.get_item_icon_modulate(i)
	# The tag icon cannot be read back: DD gives it to the colourable
	# patterns, the ones it tints red.
	var tag = null
	if mod.r > 0.9 and mod.g < 0.1 and mod.b < 0.1 and grid.has_icon("Colorable", "Icons"):
		tag = grid.get_icon("Colorable", "Icons")
	return {"icon": grid.get_item_icon(i), "meta": grid.get_item_metadata(i), "tip": grid.get_item_tooltip(i),
		"text": grid.get_item_text(i), "tag": tag, "mod": mod}


func _add_item(grid, d: Dictionary) -> void:
	var idx = grid.get_item_count()
	grid.add_icon_item(d["icon"])
	grid.set_item_metadata(idx, d["meta"])
	grid.set_item_tooltip(idx, d["tip"])
	if d.get("text", "") != "":
		grid.set_item_text(idx, d["text"])
	if d.get("tag") != null:
		grid.set_item_tag_icon(idx, d["tag"])
	if d.has("mod"):
		grid.set_item_icon_modulate(idx, d["mod"])


func _grid_paths(grid) -> Array:
	var out = []
	for i in range(grid.get_item_count()):
		out.append(grid.get_item_metadata(i))
	return out


# A pattern that is also a Roof Tool texture (same file).
func _is_roof_pattern(path) -> bool:
	if not (path is String) or path == "":
		return false
	if _roof_pat.has(path):
		return _roof_pat[path]
	_lib_build()
	# Patterns kept in a folder named after roofs (".../patterns/roofs/...",
	# ".../Roof Tiles/..."): roofs as well.
	var dir = path.get_base_dir()
	var pi = dir.find("/patterns/")
	if pi >= 0 and dir.substr(pi + 10).to_lower().find("roof") >= 0:
		_roof_pat[path] = true
		return true
	var res = false
	var n = _file_len(path)
	if n > 0:
		if _lib_lens.has(n):
			res = _lib_by_md5.has(File.new().get_md5(path))
	elif _lib_by_name.has(_name_key(path.get_file().get_basename())):
		# DD's own (imported) assets: by name.
		res = true
	_roof_pat[path] = res
	return res


func _lib_sync() -> void:
	var grids = {}
	for g in _grid_menus("PatternShapeTool", true):
		grids[g] = "tool"
	for g in _grid_menus("SelectTool", true):
		if not grids.has(g):
			grids[g] = "select"
	_lib_grids = grids
	for grid in grids.keys():
		# Second way in: when another mod takes the clicks first and hands
		# them on (as Unofficial Patch does in the Select Tool), the list's
		# item_selected listeners still hear it.
		if not grid.is_connected("item_selected", self, "_on_lib_item_selected"):
			grid.connect("item_selected", self, "_on_lib_item_selected", [grid])
		var want = _lib_on and _lib_section_on(grids[grid])
		var st = _lib_state.get(grid)
		var filtered = st != null and _grid_paths(grid) == st["shown"]
		if want:
			if filtered:
				continue
			# DD's list as it is now (without any of our items), then only
			# its roofs and the Roof Tool's own.
			var snap = []
			var pats = []
			for i in range(grid.get_item_count()):
				if grid.get_item_tooltip(i).ends_with(LIB_MARK):
					continue
				snap.append(_item_data(grid, i))
				var m = grid.get_item_metadata(i)
				if m is String and m != "":
					pats.append(m)
			var items = []
			for d in snap:
				if _is_roof_pattern(d["meta"]):
					items.append(d)
			var extra = _roof_items(pats)
			for it in extra:
				items.append({"icon": _lib_icon(it["icon"]), "meta": it["path"], "tip": it["tip"] + LIB_MARK})
			if not _lib_logged:
				_lib_logged = true
				print("[BetterRoofPatterns] Auto Roof Library: %d roof patterns, %d Roof Tool textures added" % [items.size() - extra.size(), extra.size()])
			grid.clear()
			for d in items:
				_add_item(grid, d)
			_lib_state[grid] = {"snap": snap, "shown": _grid_paths(grid)}
		else:
			if filtered:
				grid.clear()
				for d in st["snap"]:
					_add_item(grid, d)
			else:
				for i in range(grid.get_item_count() - 1, -1, -1):
					if grid.get_item_tooltip(i).ends_with(LIB_MARK):
						grid.remove_item(i)
			_lib_state.erase(grid)
	# Clicks on the Roof Tool items are taken before DD's list (and before
	# other mods' listeners: kept last in the tree, so it hears first).
	if _lib_on and not grids.empty() and _g.Editor is Node and _g.Editor.is_inside_tree():
		var root = _g.Editor.get_tree().root
		if _lib_listener == null or not is_instance_valid(_lib_listener):
			_lib_listener = LibInput.new()
			_lib_listener.name = "BetterRoofPatternsLibInput"
			_lib_listener.mod = self
			root.call_deferred("add_child", _lib_listener)
		elif _lib_listener.is_inside_tree() and _lib_listener.get_index() != root.get_child_count() - 1:
			root.move_child(_lib_listener, root.get_child_count() - 1)


func _lib_section_on(sec: String) -> bool:
	if sec == "tool":
		return bool(_tool_cfg.get("enabled", false))
	var c = _ui.get("select")
	return c != null and is_instance_valid(c["header"]) and c["header"].pressed and c["root"].visible


# DD's own texture for a Roof Tool item (the one its Roof Tool uses: known
# to DD's library, info bar, colour checks...). Taken by having the Roof
# Tool's list pick it, then giving the Roof Tool its texture back.
func _dd_roof_tex(path: String):
	var rg = _grid_menu("RoofTool", false)
	var tools = _g.Editor.get("Tools")
	var rt = tools.get("RoofTool") if tools is Dictionary else null
	if rg != null and rt != null and rg.has_method("OnItemSelected"):
		for i in range(rg.get_item_count()):
			if rg.get_item_metadata(i) == path:
				var prev = rt.get("Texture")
				rg.call("OnItemSelected", i)
				var tex = rt.get("Texture")
				if prev != tex:
					rt.set("Texture", prev)
				if tex is Texture:
					return tex
				break
	return _load_asset_tex(path, true)


func _lib_input(event) -> void:
	if not _lib_on or not (event is InputEventMouseButton) or event.button_index != BUTTON_LEFT or not event.pressed:
		return
	for grid in _lib_grids.keys():
		if not is_instance_valid(grid) or not grid.is_visible_in_tree():
			continue
		var lp = grid.get_local_mouse_position()
		if not Rect2(Vector2.ZERO, grid.rect_size).has_point(lp):
			continue
		var idx = grid.get_item_at_position(lp, true)
		if idx < 0 or not grid.get_item_tooltip(idx).ends_with(LIB_MARK):
			# A pattern of DD's: the Pattern Tool gets its colour back.
			if idx >= 0 and _lib_grids[grid] == "tool" and _lib_prev_color != null:
				var pst0 = _g.Editor.Tools.get("PatternShapeTool")
				if pst0 != null:
					pst0.set("Color", _lib_prev_color)
				_lib_prev_color = null
			return
		# One of ours: DD's list would not find it among its patterns.
		grid.get_tree().set_input_as_handled()
		grid.select(idx)
		_lib_apply(grid.get_item_metadata(idx), _lib_grids[grid])
		return


func _on_lib_item_selected(idx: int, grid) -> void:
	if not is_instance_valid(grid) or idx < 0 or idx >= grid.get_item_count():
		return
	if grid.get_item_tooltip(idx).ends_with(LIB_MARK) and _lib_grids.has(grid):
		_lib_apply(grid.get_item_metadata(idx), _lib_grids[grid])


func _lib_apply(path, sec: String) -> void:
	if not (path is String) or path == "":
		return
	var tex = _dd_roof_tex(path)
	if tex == null:
		return
	if sec == "tool":
		var pst = _g.Editor.Tools.get("PatternShapeTool") if _g.Editor.get("Tools") != null else null
		if pst != null:
			pst.set("Texture", tex)
			# Roof Tool textures are not colourable: drawn untinted (the
			# colour comes back with the next pattern of DD's).
			var col = pst.get("Color")
			if col is Color:
				if _lib_prev_color == null:
					_lib_prev_color = col
				pst.set("Color", Color(1, 1, 1, col.a))
		return
	var sel = _sel_shapes
	var tools = _g.Editor.get("Tools")
	var stool = tools.get("SelectTool") if tools != null else null
	if stool != null and stool.get("Selected") != null:
		sel = stool.get("Selected")
	for shape in sel:
		if not _is_pattern_shape(shape):
			continue
		var mat = shape.material
		var rot = shape.get("_Rotation")
		if rot == null and mat is ShaderMaterial:
			rot = mat.get_shader_param("rotation")
		# Not colourable: untinted.
		shape.call("SetOptions", tex, Color(1, 1, 1, shape.color.a), float(rot) if rot != null else 0.0)


# ── Copy / paste roof settings (Select Tool) ──

var _settings_clip = null


func _on_settings_copy() -> void:
	var store = _get_store()
	if store == null:
		return
	for shape in _sel_shapes:
		var key = _key_of(shape)
		if key != "" and store.has(key):
			_settings_clip = _full_cfg(store[key]).duplicate(true)
			var c = _ui.get("select")
			if c != null and c.get("clip") != null:
				c["clip"].get_child(1).disabled = false
			return


func _on_settings_paste() -> void:
	if _settings_clip == null:
		return
	var store = _get_store()
	if store == null:
		return
	_roof_cache = null
	for shape in _sel_shapes:
		if not _is_pattern_shape(shape):
			continue
		var key = _key_of(shape)
		if key == "":
			continue
		var cfg = _full_cfg(_settings_clip.duplicate(true))
		store[key] = cfg
		_sync_shape(shape, key, cfg)
	_set_ui_values("select", _settings_clip, true)
	_update_visibility("select")


func _has_pieces(tex) -> bool:
	if not (tex is Texture):
		return false
	var p = _roof_pieces(tex)
	return p.has("ridge") and p.has("hip")
