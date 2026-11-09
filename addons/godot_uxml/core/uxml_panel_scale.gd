class_name UxmlPanelScale
extends RefCounted
## Unity's panel scaling (PanelSettings), the layer the runtimes share.
##
## Two things live here, so that every runtime (the GDScript path, the
## native core, runtime v2) gives the same numbers:
##
## 1. The scale: `resolve()` is Unity 6000.3's `PanelSettings.ResolveScale`
##    and `ApplyPanelSettings`, in Unity's single-precision steps, verified
##    against Unity on 1032 settings and screens
##    (bench/parity/probes/panel-scale.json, tests/test_panel_scale.gd).
## 2. The points/pixels contract: layout runs in panel points; the pixel
##    grid is at `pixels_per_point` (Yoga's PointScaleFactor, Unity's
##    scaledPixelsPerPoint); `pixel()` and `grid_box()` round on it.
##
## The native core has the same functions (native/src/panel_scale.rs,
## `UxmlNative.panel_scale`); bench/equiv_layout.gd compares the two.

## PanelScaleMode (the values of Unity's enum and of its YAML).
enum ScaleMode { CONSTANT_PIXEL_SIZE = 0, CONSTANT_PHYSICAL_SIZE = 1, SCALE_WITH_SCREEN_SIZE = 2 }
## PanelScreenMatchMode.
enum MatchMode { MATCH_WIDTH_OR_HEIGHT = 0, SHRINK = 1, EXPAND = 2 }

static var _f32 := PackedFloat32Array([0.0])


## `v` rounded to single precision (a C# float).
static func f32(v: float) -> float:
	_f32[0] = v
	return _f32[0]


## Unity's resolved scale for `settings` on a screen (the host, in pixels)
## of `screen` at `dpi` (0: unknown, Unity uses the fallback DPI).
## `settings` is a Dictionary with the keys of UxmlPanelSettings.to_dict()
## (missing keys take Unity's defaults). Returns:
##   resolved_scale   points per pixel (PanelSettings.m_ResolvedScale);
##                    0 for a scale of 0 or less;
##   pixels_per_point the panel's scaledPixelsPerPoint (1 / resolved_scale);
##   panel_size       the panel root in points: the screen times the
##                    resolved scale, on the pixel grid (Unity's root
##                    visualTree layout).
static func resolve(settings: Dictionary, screen: Vector2, dpi: float) -> Dictionary:
	var mode := int(settings.get("scale_mode", ScaleMode.CONSTANT_PHYSICAL_SIZE))
	var num := 1.0
	match mode:
		ScaleMode.CONSTANT_PHYSICAL_SIZE:
			var d := f32(float(settings.get("fallback_dpi", 96.0))) if dpi == 0.0 else f32(dpi)
			if d != 0.0:
				num = f32(float(settings.get("reference_dpi", 96.0))) / d
		ScaleMode.SCALE_WITH_SCREEN_SIZE:
			var res: Vector2i = settings.get("reference_resolution", Vector2i(1200, 800))
			if res.x * res.y != 0:
				var ax := f32(screen.x / float(res.x))
				var ay := f32(screen.y / float(res.y))
				var den := 0.0
				match int(settings.get("screen_match_mode", MatchMode.MATCH_WIDTH_OR_HEIGHT)):
					MatchMode.EXPAND:
						den = minf(ax, ay)
					MatchMode.SHRINK:
						den = maxf(ax, ay)
					_:
						# Mathf.Lerp(x, y, Clamp01(match)): one rounding at the
						# end (measured: rounding each step differs in 52 of
						# 648 rows).
						var t := f32(clampf(f32(float(settings.get("match", 0.0))), 0.0, 1.0))
						den = f32(ax + (ay - ax) * t)
				if den != 0.0:
					num = 1.0 / den
	var sc := f32(float(settings.get("scale", 1.0)))
	var rs := f32(num / sc) if sc > 0.0 else 0.0
	var ppp := f32(1.0 / rs) if rs != 0.0 else 0.0
	var panel := Vector2.ZERO
	if ppp > 0.0:
		panel = Vector2(f32(pixel(f32(screen.x * rs), ppp)), f32(pixel(f32(screen.y * rs), ppp)))
	return {"resolved_scale": rs, "pixels_per_point": ppp, "panel_size": panel}


## Settings in the keys of resolve() from Unity's C# names (a PanelSettings
## as tools/unity-dump writes it: "scaleMode": "ScaleWithScreenSize",
## "referenceResolution": [w, h], "screenMatchMode": "Expand", ...).
static func settings_from_unity(u: Dictionary) -> Dictionary:
	var modes := {"ConstantPixelSize": 0, "ConstantPhysicalSize": 1, "ScaleWithScreenSize": 2}
	var matches := {"MatchWidthOrHeight": 0, "Shrink": 1, "Expand": 2}
	var rr: Array = u.get("referenceResolution", [1200, 800])
	return {
		"scale_mode": int(modes.get(String(u.get("scaleMode", "ConstantPhysicalSize")), 1)),
		"scale": float(u.get("scale", 1.0)),
		"reference_resolution": Vector2i(int(rr[0]), int(rr[1])),
		"screen_match_mode": int(matches.get(String(u.get("screenMatchMode", "MatchWidthOrHeight")), 0)),
		"match": float(u.get("match", 0.0)),
		"reference_dpi": float(u.get("referenceDpi", 96.0)),
		"fallback_dpi": float(u.get("fallbackDpi", 96.0)),
	}


## Yoga's roundValueToPixelGrid at `ppp` pixels per point (no forced ceil
## or floor; halves up): the value in points of the nearest pixel edge.
## At ppp 1 this is the rounding of every layout before panel scaling.
static func pixel(v: float, ppp: float = 1.0) -> float:
	var s := v * ppp
	var f := fmod(s, 1.0)
	if f < 0.0:
		f += 1.0
	if absf(f) < 0.0001:
		s -= f
	elif absf(f - 1.0) < 0.0001:
		s = s - f + 1.0
	else:
		s = s - f + (1.0 if (f > 0.5 or absf(f - 0.5) < 0.0001) else 0.0)
	return s if ppp == 1.0 else s / ppp


## A leaf measure (text, images) up to the next pixel edge, as Unity rounds
## a TextElement's measure (CeilToPixelGrid) and every measure after it
## (RoundToPixelGrid). A value within a thousandth of a pixel of an edge is
## on it.
static func ceil_pixel(v: float, ppp: float) -> float:
	return ceilf(v * ppp - 0.001) / ppp


## A margin, padding or border width on the pixel grid, as Unity lays it
## out (measured, lay-fraction, at every scale): margins and padding round
## to the nearest pixel (halves up), a nonzero border is at least one pixel.
static func grid_box(v: float, border: bool, ppp: float = 1.0) -> float:
	if border:
		return 0.0 if v <= 0.0 else maxf(1.0 / ppp if ppp != 1.0 else 1.0, pixel(v, ppp))
	return pixel(v, ppp)
