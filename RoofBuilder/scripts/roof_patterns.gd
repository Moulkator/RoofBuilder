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
const LUT_N = 512
const MAX_MERGE = 8
const SMOOTH_MIN_POINTS = 16
const MAX_EDGES = 1024
const ANALYSIS_COLUMNS = 128
const CONFIG_DIR = "user://BetterRoofPatterns"
const CONFIG_PATH = "user://BetterRoofPatterns/tool_settings.cfg"
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
	"soft_seams": true,
	"pitch": 0.0,
	"shade_on": true,
	"shade": 0.35,
	"light": 315.0,
	"apex_on": false,
	"apex_x": 0.0,
	"apex_y": 0.0,
	"apex_lock": false,
	"merge": false,
	"merge_height": 0.0,
	"side_ink": true,
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
uniform float merge_shadow = 0.55;
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
	float s_k = clamp(1.0 - t_mid / (pitch_scale * d_ref), 0.0, 1.0);
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
		}
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
	float t = (v_max - base.y) * size.y;
	if (mirror)
	{
		t = min(t, (base.y - v_min) * size.y);
	}
	return t;
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
	float s = clamp(c * 2.0, 0.0, 1.0);
	// Nothing deep under the drawn part itself (it would show through
	// translucent textures).
	return vec4(0.0, 0.0, 0.0, merge_shadow * pow(s, 1.5) * (1.0 - smoothstep(0.8, 0.97, c)));
}

float course_rand(float k)
{
	return fract(sin(k * 12.9898 + 4.1414) * 43758.5453);
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
			vec4 e = texelFetch(edges, ivec2(i, 0), 0);
			vec4 fl = texelFetch(edges, ivec2(i, 1), 0);
			vec4 nb = texelFetch(edges, ivec2(i, 2), 0);
			vec2 ab = e.zw - e.xy;
			float h = dot(v_local - e.xy, ab) / max(dot(ab, ab), 0.000001);
			// Past an inner (reflex) corner the edge plane keeps going, on the
			// far side of the valley (corner bisector) only: there it is the
			// higher of the two planes. Near its own extension line it would
			// drop to eave height inside the roof.
			bool inner = dot(v_local - e.xy, fl.xy) <= 0.0;
			bool ext = (h >= 0.0 && h <= 1.0)
				|| (inner && h < 0.0 && fl.z > 0.5 && dot(v_local - e.xy, nb.xy + normalize(ab)) > 0.0)
				|| (inner && h > 1.0 && fl.w > 0.5 && dot(v_local - e.zw, normalize(ab) + nb.zw) < 0.0);
			float dd = ext ? abs(dot(v_local - e.xy, fl.xy)) : length(v_local - e.xy - ab * clamp(h, 0.0, 1.0));
			// Around an inner corner the distance to the corner point is not
			// a roof face (round swirl, and a false seam next to the valley).
			if (!ext && ((h < 0.0 && fl.z > 0.5) || (h > 1.0 && fl.w > 0.5)))
			{
				dd = 100000000.0;
			}
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
		vec2 gx = dFdx(bp);
		vec2 gy = dFdy(bp);
		lod = 0.5 * log2(max(max(dot(gx, gx), dot(gy, gy)), 0.00000001));
		t = (v_max - base.y) * size.y;
		ux = base.x;
		face_n = normalize(vec2(-sin(rotation) / size.x, cos(rotation) / size.y));
		if (mirror)
		{
			// Far slope = near slope turned 180° (+ ridge offset).
			float tf = (base.y - v_min) * size.y;
			float uf = ridge_offset - base.x;
			vec2 nf2 = -face_n;
			if (tf < t)
			{
				float tt = t; t = tf; tf = tt;
				float uu = ux; ux = uf; uf = uu;
				vec2 nn2 = face_n; face_n = nf2; nf2 = nn2;
			}
			seam_d = tf - t;
			seam_g = 2.0 * size.y * length(vec2(-sin(rotation) / size.x, cos(rotation) / size.y));
			if (seam_soft > 0.0)
			{
				t2 = tf;
				ux2 = uf;
				face_n2 = nf2;
				w2 = 0.5 * clamp(1.0 - (tf - t) / seam_soft, 0.0, 1.0);
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
		float l1 = max(1.0 + shade * 0.6 * dot(face_n, light_dir), 0.0);
		float l2 = max(1.0 + shade * 0.6 * dot(face_n2, light_dir), 0.0);
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
	if (edge_count > 0 && side_ink)
	{
		vec2 odx = dFdx(v_local);
		vec2 ody = dFdy(v_local);
		float opx = max(max(length(odx), length(ody)), 0.000001);
		float o_ink = max(max(row_h, 1.0) * 0.04, opx * 1.5);
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
	if (seam_soft <= 0.0 && seam_d < 10000000.0 && (roof_mode == 3 || (roof_mode == 1 && mirror)))
	{
		float ds = seam_d / max(seam_g, 0.0001);
		float srh = max(row_h, 1.0);
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
			texel *= mix(1.0, 0.12, (1.0 - smoothstep(s_ink * 0.5, s_ink, ds)) * ink_a);
		}
	}
	float keep = 1.0;
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
		float ink_w = max(max(row_h, 1.0) * 0.06, px_w * 2.0);
		bool kept = true;
		float d_edge = 100000000.0;
		if (hb >= 0.0)
		{
			float sd = dh / max(gdh, 0.0001);
			kept = sd >= 0.0;
			d_edge = abs(sd);
			keep = clamp(sd / px_w + 0.5, 0.0, 1.0);
		}
		if (kept && d_edge < ink_w)
		{
			// Ink line on the cut edge, like the outlines of the tiles.
			texel *= mix(1.0, 0.12, (1.0 - smoothstep(ink_w * 0.5, ink_w, d_edge)) * ink_a);
		}
	}
	COLOR = vec4(texel, alpha * keep);
	}
}
"""

var _shader: Shader = null
var _tex_info := {}       # texture instance id -> analysis Dictionary
var _states := {}         # "node-id-N" -> {"mat", "sig", "lut"}
var _tool_cfg := {"enabled": false, "mode": MODE_FILL, "mirror": false}   # Pattern Tool: next shapes
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
	_load_tool_cfg()
	_build_ui()
	# Other mods find this instance here (weak: a mods reload frees it).
	Engine.set_meta(API_META, weakref(self))
	print("[BetterRoofPatterns] initialized")


func update(_delta) -> void:
	_api_frame = Engine.get_idle_frames()
	if _g == null or _g.World == null or not is_instance_valid(_g.World):
		_clear_captures()
		return
	if _g.World != _world_ref:
		_world_ref = _g.World
		_drop_all_states()
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
	for k in ["edge", "u_offset", "merge_height", "scale", "ridge_offset", "pitch", "shade", "light", "apex_x", "apex_y"]:
		out[k] = float(out[k])
	for k in ["mirror", "taper", "soft_seams", "apex_on", "shade_on", "merge", "side_ink", "apex_lock"]:
		out[k] = bool(out[k])
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
		return
	st["sig"] = sig
	_geo_rev += 1
	st["lsig"] = lsig
	update_material(mat, node.polygon, full, st)
	_update_skirt(node, mat, full, st)


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
		full["edge"], full["pitch"], full["mirror"], full["soft_seams"], full["merge_height"],
		mat.get_shader_param("rotation"), tex.get_instance_id() if tex != null else 0,
		m.get("sig", "") if m != null else ""])
	var sk = node.get_node_or_null(SKIRT_NAME)
	var bake = st.get("bake")
	var bake_ok = bake != null and is_instance_valid(bake["vp"]) and is_instance_valid(bake["poly"])
	if sk != null and bake_ok and st.get("bake_key") == bkey:
		return
	st["bake_key"] = bkey
	var rh = mat.get_shader_param("row_h")
	var w = min(max(float(rh) if rh != null else 64.0, 1.0) * 0.3, 40.0)
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
	mat.set_shader_param("band", info["band"])
	mat.set_shader_param("edge_shift", info["empty"] + float(cfg.get("edge", 0.0)))
	mat.set_shader_param("fade", info.get("fade", 0.0))
	mat.set_shader_param("body_end", info.get("body_end", info["h"]))
	mat.set_shader_param("eave_band", max(info["h"] - info["empty"] - float(cfg.get("edge", 0.0)) - info.get("body_end", info["h"]), 0.0))
	# Softer Seams: width (texels) of the blend across ridges / hip lines.
	var soft = max(16.0, info["h"] * 0.035) if bool(cfg.get("soft_seams", true)) else 0.0
	mat.set_shader_param("seam_soft", soft)
	mat.set_shader_param("tex_scale", _tex_scale(cfg))
	mat.set_shader_param("side_ink", bool(cfg.get("side_ink", true)))
	# The texture draws its own eave edge (transparent rows under the tiles).
	mat.set_shader_param("eave_cut", info.get("body_end", info["h"]) < info["h"] - 0.5)
	mat.set_shader_param("row_h", info.get("row_h", info["h"]))
	mat.set_shader_param("row_y0", info.get("row_y0", 0.0))
	mat.set_shader_param("tile_n", info.get("tile_n", 0.0))
	_set_light(mat, cfg, st)
	_set_merge(mat, cfg, st)
	mat.set_shader_param("merge_raise", float(cfg.get("merge_height", 0.0)))
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
		var pscale = 1.0 / cos(deg2rad(pitch)) if pmode != MODE_FILL else 1.0
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
	# Pitch only applies to Centered / Hip roofs.
	mat.set_shader_param("pitch_scale", 1.0 / cos(deg2rad(pitch)) if int(cfg.get("mode", MODE_FILL)) != MODE_FILL else 1.0)
	var strength = float(cfg.get("shade", 0.0))
	var angle = float(cfg.get("light", 315.0))
	var gl = _global_light()
	if gl["on"]:
		strength = gl["shade"]
		angle = gl["light"]
	var shade = clamp(strength, 0.0, 1.0) if bool(cfg.get("shade_on", true)) else 0.0
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
	# Pitch only applies to Centered / Hip roofs.
	mat.set_shader_param("pitch_scale", 1.0)


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
# Row 3: perpendicular distance from the top point to the edge line.
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
	var cum = []
	var acc = 0.0
	for i in range(n):
		dirs.append((poly[(i + 1) % n] - poly[i]).normalized())
		cum.append(acc)
		acc += poly[i].distance_to(poly[(i + 1) % n])
	var img = Image.new()
	img.create(n, 4, false, Image.FORMAT_RGBAF)
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
		var apex_d = max((a - apex).dot(outn), 0.001)
		img.set_pixel(i, 0, Color(a.x, a.y, b.x, b.y))
		img.set_pixel(i, 1, Color(outn.x, outn.y, reflex_a, reflex_b))
		img.set_pixel(i, 2, Color(d_prev.x, d_prev.y, d_next.x, d_next.y))
		img.set_pixel(i, 3, Color(apex_d, cum[i], 0.0, 0.0))
	img.unlock()
	var etex = st.get("edges")
	if etex == null:
		etex = ImageTexture.new()
		st["edges"] = etex
	etex.create_from_image(img, 0)
	mat.set_shader_param("edges", etex)
	mat.set_shader_param("edge_count", n)
	st["perimeter"] = acc


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
	var info = {"w": w, "h": h, "band_start": 0.0, "band": h, "empty": 0.0, "fade": 0.0, "row_h": h, "row_y0": 0.0, "tile_n": 0.0, "body_end": h, "vis_end": h}
	_tex_info[id] = info
	var t0 = OS.get_ticks_msec()
	var img = tex.get_data()
	if img == null or img.is_empty():
		return info
	if img.is_compressed():
		if img.decompress() != OK:
			return info
	img.convert(Image.FORMAT_RGBA8)
	info["tile_n"] = _detect_tiles_across(img)
	var ih = img.get_height()
	if ih < 16:
		return info
	var sc = h / float(ih)
	img.resize(ANALYSIS_COLUMNS, ih, Image.INTERPOLATE_BILINEAR)
	var alpha = PoolRealArray()
	alpha.resize(ih)
	var grid = PoolRealArray()
	grid.resize(ih * ANALYSIS_COLUMNS)
	img.lock()
	for y in range(ih):
		var sa = 0.0
		for x in range(ANALYSIS_COLUMNS):
			var c = img.get_pixel(x, y)
			sa += c.a
			grid[y * ANALYSIS_COLUMNS + x] = (c.r + c.g + c.b) * c.a / 3.0
		alpha[y] = sa / float(ANALYSIS_COLUMNS)
	img.unlock()
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
		return info
	var rows = _detect_rows(grid, body_start, body_end)
	if rows[0] > 0.0:
		info["row_h"] = rows[0] * sc
		info["row_y0"] = rows[1] * sc
	if body_start == 0 and body_end == ih:
		# Fully opaque texture: plain tiling, nothing to fix.
		return info
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
	return info


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
	img.lock()
	for y in range(ch):
		var line = PoolRealArray()
		line.resize(cw)
		var sa = 0.0
		var mean = 0.0
		for x in range(cw):
			var c = img.get_pixel(x, y)
			sa += c.a
			line[x] = (c.r + c.g + c.b) * c.a / 3.0
			mean += line[x]
		if sa / float(cw) < 0.99:
			continue
		mean /= float(cw)
		for x in range(cw):
			line[x] -= mean
		rows.append(line)
	img.unlock()
	if rows.empty():
		return 0.0
	var variance = 0.0
	for line in rows:
		for x in range(cw):
			variance += line[x] * line[x]
	variance /= float(rows.size() * cw)
	if variance < 0.00000001:
		return 0.0
	var scores = {}
	var best = -INF
	for n in range(2, 65):
		var lag = float(cw) / float(n)
		var li = int(floor(lag))
		var f = lag - float(li)
		var acc = 0.0
		for line in rows:
			for x in range(cw):
				var b = line[(x + li) % cw] * (1.0 - f) + line[(x + li + 1) % cw] * f
				acc += line[x] * b
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
		_set_ui_values("tool", cfg, bool(_tool_cfg.get("enabled", false)))
	var sp = toolset.GetToolPanel("SelectTool")
	if sp != null and sp.get("Align") != null:
		var anchor2 = _find_order_anchor(sp.Align, 0)
		if anchor2 == null:
			anchor2 = _find_layer_anchor(sp.Align, 0)
		_ui["select"] = _make_section(sp.Align, anchor2, UI_SELECT_NAME, "select", true, icon_roof, icon_reset)
		_ui["select"]["root"].visible = false


func _load_icon(file_name: String, max_px: int) -> Texture:
	var img = Image.new()
	if img.load(_g.Root + "icons/" + file_name) != OK:
		print("[BetterRoofPatterns] icon not found: icons/" + file_name)
		return null
	var big = max(img.get_width(), img.get_height())
	if big > max_px:
		var k = float(max_px) / float(big)
		img.resize(int(max(1, round(img.get_width() * k))), int(max(1, round(img.get_height() * k))), Image.INTERPOLATE_CUBIC)
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


# Select Tool: the row holding the "Bring to Front" / "Send to Back" buttons
# (matched on text or tooltip). null if not found.
func _find_order_anchor(node: Node, depth: int):
	var found = []
	_collect_order_buttons(node, depth, found)
	if found.empty():
		return null
	var b = found[found.size() - 1]
	var parent = b.get_parent()
	if parent is HBoxContainer or parent is GridContainer:
		return parent
	return b


func _collect_order_buttons(node: Node, depth: int, out: Array) -> void:
	if depth > 6:
		return
	for child in node.get_children():
		if child is BaseButton and _is_order_button(child):
			out.append(child)
		if child is Control and child.get_child_count() > 0:
			_collect_order_buttons(child, depth + 1, out)


# DD's buttons: text "BRING_TO_FRONT" / "SEND_TO_BACK" (translation keys,
# shown translated), "pressed" connected to SelectTool.BringToFront / SendToBack.
func _is_order_button(b: BaseButton) -> bool:
	for con in b.get_signal_connection_list("pressed"):
		var m = str(con.get("method", ""))
		if m == "BringToFront" or m == "SendToBack":
			return true
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

	var opts = VBoxContainer.new()
	root.add_child(opts)
	var mode_row = HBoxContainer.new()
	opts.add_child(mode_row)
	var group = ButtonGroup.new()
	var c = {"root": root, "header": header, "opts": opts, "full": full, "modes": {}}
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
	if full:
		c["soft_seams"] = _make_toggle(opts, "Softer Seams",
			"Blends the two sides of every ridge and hip line over a few\npixels instead of a hard cut. On Centered roofs it also hides\nthe seam left by a Tile Width that does not fit a whole number\nof tiles around the roof.",
			section, "soft_seams")
		c["side_ink"] = _make_toggle(opts, "Side Lines",
			"Draws a dark outline on every side where the texture is plainly\ncut, whatever the drawn shape: eaves when the texture has no\ncut-out edge of its own, and always the sides that are not an\neave (gable ends, the sides a moved roof top is close to).",
			section, "side_ink")
		c["taper"] = _make_toggle(opts, "Taper Toward Top",
			"Each course of tiles gets its own tile count, fewer and fewer\ntoward the top, like a real conical roof: the tiles keep about\nthe same width and the count changes on the row edges, under\nthe overlap of the course above.",
			section, "taper")
		c["apex_on"] = _make_toggle(opts, "Custom Top Position",
			"Moves the roof top away from the centre of the shape.",
			section, "apex_on")
		c["apex_box"] = _make_apex_box(opts, c, section, icon_reset)
		c["merge"] = _make_toggle(opts, "Merge With Roof Below",
			"Joins this roof to the roof it overlaps the most among those\ndrawn below it: where that roof rises higher, it shows through,\nso the two roofs meet on their real intersection line.\nTip: put the roof with the most cut-out eave (round tiles,\nscales) on top, so its own edge is drawn over the other one.",
			section, "merge")
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
		c["edge"] = _make_slider(opts, "Edge Offset", -128.0, 128.0, " px",
			"Moves the eave inward (+) or outward (-).\nThe empty rows under the eave are already removed automatically.",
			section, "edge", icon_reset)
		c["u_offset"] = _make_slider(opts, "Texture Offset", -100.0, 100.0, "%",
			"Slides the texture sideways (in % of the texture width),\nwithout moving the shape.",
			section, "u_offset", icon_reset)
		c["merge_height"] = _make_slider(opts, "Merge Height", -300.0, 300.0, " px",
			"Raises (+) or lowers (-) this roof against the roofs below it:\nhigher, it covers more of them; lower, they show through more.",
			section, "merge_height", icon_reset)
		c["pitch"] = _make_slider(opts, "Pitch", 0.0, 70.0, "°",
			"Roof steepness: steeper roofs show more tile rows\nbetween the edge and the top.",
			section, "pitch", icon_reset)
		opts.move_child(c["shade_on"], c["pitch"]["row"].get_index() + 1)
		opts.move_child(c["global_light"], c["shade_on"].get_index() + 1)
		c["shade"] = _make_slider(opts, "Shading Strength", 0.0, 100.0, "%",
			"Strength of the light/shadow effect on the roof sides.",
			section, "shade", icon_reset)
		c["light"] = _make_slider(opts, "Light Direction", 0.0, 359.0, "°",
			"Where the light comes from (0° = top, clockwise).",
			section, "light", icon_reset)
	return c


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
	if c["full"]:
		_set_ctl(c["ridge_offset"], full["ridge_offset"])
		_set_ctl(c["scale"], full["scale"])
		_set_ctl(c["edge"], full["edge"])
		_set_ctl(c["u_offset"], full["u_offset"])
		_set_ctl(c["merge_height"], full["merge_height"])
		_set_ctl(c["pitch"], full["pitch"])
		var gl = _global_light()
		c["global_light"].pressed = gl["on"]
		_set_ctl(c["shade"], (gl["shade"] if gl["on"] else full["shade"]) * 100.0)
		_set_ctl(c["light"], gl["light"] if gl["on"] else full["light"])
		c["taper"].pressed = full["taper"]
		c["soft_seams"].pressed = full["soft_seams"]
		c["apex_on"].pressed = full["apex_on"]
		c["shade_on"].pressed = full["shade_on"]
		c["merge"].pressed = full["merge"]
		c["side_ink"].pressed = full["side_ink"]
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
	if c["full"]:
		cfg["ridge_offset"] = float(c["ridge_offset"]["spin"].value)
		cfg["scale"] = float(c["scale"]["spin"].value)
		cfg["edge"] = float(c["edge"]["spin"].value)
		cfg["u_offset"] = float(c["u_offset"]["spin"].value)
		cfg["merge_height"] = float(c["merge_height"]["spin"].value)
		cfg["pitch"] = float(c["pitch"]["spin"].value)
		cfg["shade"] = float(c["shade"]["spin"].value) / 100.0
		cfg["light"] = float(c["light"]["spin"].value)
		cfg["taper"] = c["taper"].pressed
		cfg["soft_seams"] = c["soft_seams"].pressed
		cfg["apex_on"] = c["apex_on"].pressed
		cfg["shade_on"] = c["shade_on"].pressed
		cfg["merge"] = c["merge"].pressed
		cfg["side_ink"] = c["side_ink"].pressed
		cfg["apex_x"] = float(c["apex_x"].value) / 100.0
		cfg["apex_y"] = float(c["apex_y"].value) / 100.0
		cfg["apex_lock"] = c["apex_lock"].pressed
	return cfg


func _update_visibility(section: String) -> void:
	var c = _ui.get(section)
	if c == null or not is_instance_valid(c["root"]):
		return
	c["opts"].visible = c["header"].pressed
	var mode = _ui_mode(section)
	c["mirror"].visible = mode == MODE_FILL
	if not c["full"]:
		return
	var shaded = mode != MODE_FILL or c["mirror"].pressed
	c["ridge_offset"]["row"].visible = mode == MODE_FILL and c["mirror"].pressed
	c["soft_seams"].visible = mode != MODE_FILL or c["mirror"].pressed
	c["taper"].visible = mode == MODE_CENTER
	c["pitch"]["row"].visible = mode != MODE_FILL
	c["u_offset"]["row"].visible = mode == MODE_FILL
	c["merge_height"]["row"].visible = c["merge"].pressed
	c["side_ink"].visible = true
	c["shade_on"].visible = shaded
	c["global_light"].visible = shaded and c["shade_on"].pressed
	c["merge"].visible = true
	c["shade"]["row"].visible = shaded and c["shade_on"].pressed
	c["light"]["row"].visible = shaded and c["shade_on"].pressed
	c["apex_on"].visible = mode == MODE_CENTER
	c["apex_box"].visible = mode == MODE_CENTER and c["apex_on"].pressed


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
		_save_tool_cfg()
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
		_save_tool_cfg()
		return
	_apply_fields(section, {"mode": mode})


func _on_toggle_changed(pressed: bool, section: String, field: String) -> void:
	_update_visibility(section)
	if _updating_ui:
		return
	if section == "tool":
		_tool_cfg[field] = pressed
		_save_tool_cfg()
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
	if field == "shade":
		v = v / 100.0
	if section == "select" and (field == "shade" or field == "light") and _global_light()["on"]:
		_set_global_light({field: v})
		return
	_apply_fields(section, {field: v})


func _on_reset_pressed(section: String, field: String) -> void:
	var c = _ui.get(section)
	if c == null or not c.has(field):
		return
	var v = float(DEFAULT_CFG[field])
	_updating_ui = true
	_set_ctl(c[field], v * 100.0 if field == "shade" else v)
	_updating_ui = false
	if section == "select" and (field == "shade" or field == "light") and _global_light()["on"]:
		_set_global_light({field: v})
		return
	_apply_fields(section, {field: v})


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
		_set_ui_values("select", cfg, false)


# ── Tool settings persistence ─────────────────────────────────────────────────

func _load_tool_cfg() -> void:
	var cf = ConfigFile.new()
	if cf.load(CONFIG_PATH) != OK:
		return
	_tool_cfg["enabled"] = bool(cf.get_value("tool", "enabled", false))
	_tool_cfg["mode"] = _valid_mode(int(cf.get_value("tool", "mode", MODE_FILL)))
	_tool_cfg["mirror"] = bool(cf.get_value("tool", "mirror", false))


func _save_tool_cfg() -> void:
	var dir = Directory.new()
	if not dir.dir_exists(CONFIG_DIR):
		dir.make_dir_recursive(CONFIG_DIR)
	var cf = ConfigFile.new()
	cf.set_value("tool", "enabled", bool(_tool_cfg.get("enabled", false)))
	cf.set_value("tool", "mode", int(_tool_cfg.get("mode", MODE_FILL)))
	cf.set_value("tool", "mirror", bool(_tool_cfg.get("mirror", false)))
	cf.save(CONFIG_PATH)
