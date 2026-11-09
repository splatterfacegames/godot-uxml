//! Unity's panel scaling (PanelSettings), shared by every native runtime.
//!
//! Same functions as `addons/godot_uxml/core/uxml_panel_scale.gd`
//! (UxmlPanelScale); bench/equiv_layout.gd checks that both give the same
//! results on every row of bench/parity/probes/panel-scale.json.
//!
//! - `resolve`: Unity 6000.3's `PanelSettings.ResolveScale` and the root size
//!   of `ApplyPanelSettings`, in Unity's single-precision steps.
//! - `pixel`, `grid_box`: the points/pixels contract. Layout runs in panel
//!   points; the pixel grid is at `ppp` pixels per point (Yoga's
//!   PointScaleFactor, Unity's scaledPixelsPerPoint).

/// PanelScaleMode (Unity's enum values, also in its YAML).
pub const CONSTANT_PIXEL_SIZE: i64 = 0;
pub const CONSTANT_PHYSICAL_SIZE: i64 = 1;
pub const SCALE_WITH_SCREEN_SIZE: i64 = 2;
/// PanelScreenMatchMode.
pub const MATCH_WIDTH_OR_HEIGHT: i64 = 0;
pub const SHRINK: i64 = 1;
pub const EXPAND: i64 = 2;

/// PanelSettings fields (UxmlPanelSettings.to_dict()).
#[derive(Clone, Copy, Debug)]
pub struct Settings {
    pub scale_mode: i64,
    pub scale: f64,
    pub reference_resolution: (i64, i64),
    pub screen_match_mode: i64,
    pub match_: f64,
    pub reference_dpi: f64,
    pub fallback_dpi: f64,
}

impl Default for Settings {
    /// Unity's field defaults (a new PanelSettings).
    fn default() -> Self {
        Settings {
            scale_mode: CONSTANT_PHYSICAL_SIZE,
            scale: 1.0,
            reference_resolution: (1200, 800),
            screen_match_mode: MATCH_WIDTH_OR_HEIGHT,
            match_: 0.0,
            reference_dpi: 96.0,
            fallback_dpi: 96.0,
        }
    }
}

/// What a panel resolves on a screen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Resolved {
    /// Points per pixel (PanelSettings.m_ResolvedScale); 0 for scale <= 0.
    pub resolved_scale: f64,
    /// scaledPixelsPerPoint.
    pub pixels_per_point: f64,
    /// The panel root in points, on the pixel grid.
    pub panel: (f64, f64),
}

fn f32r(v: f64) -> f64 {
    v as f32 as f64
}

/// Unity's resolved scale for `s` on a `screen` (pixels) at `dpi` (0:
/// unknown, the fallback DPI).
pub fn resolve(s: &Settings, screen: (f64, f64), dpi: f64) -> Resolved {
    let mut num = 1.0f64;
    match s.scale_mode {
        CONSTANT_PHYSICAL_SIZE => {
            let d = if dpi == 0.0 { f32r(s.fallback_dpi) } else { f32r(dpi) };
            if d != 0.0 {
                num = f32r(s.reference_dpi) / d;
            }
        }
        SCALE_WITH_SCREEN_SIZE => {
            let (rx, ry) = s.reference_resolution;
            if rx * ry != 0 {
                let ax = f32r(screen.0 / rx as f64);
                let ay = f32r(screen.1 / ry as f64);
                let den = match s.screen_match_mode {
                    EXPAND => ax.min(ay),
                    SHRINK => ax.max(ay),
                    _ => {
                        // Mathf.Lerp(x, y, Clamp01(match)), rounded once.
                        let t = f32r(f32r(s.match_).clamp(0.0, 1.0));
                        f32r(ax + (ay - ax) * t)
                    }
                };
                if den != 0.0 {
                    num = 1.0 / den;
                }
            }
        }
        _ => {}
    }
    let sc = f32r(s.scale);
    let rs = if sc > 0.0 { f32r(num / sc) } else { 0.0 };
    let ppp = if rs != 0.0 { f32r(1.0 / rs) } else { 0.0 };
    let panel = if ppp > 0.0 {
        (f32r(pixel(f32r(screen.0 * rs), ppp)), f32r(pixel(f32r(screen.1 * rs), ppp)))
    } else {
        (0.0, 0.0)
    };
    Resolved { resolved_scale: rs, pixels_per_point: ppp, panel }
}

/// Yoga's roundValueToPixelGrid at `ppp` pixels per point (no forced ceil
/// or floor, halves up; C fmod semantics).
pub fn pixel(v: f64, ppp: f64) -> f64 {
    let mut s = v * ppp;
    let mut fr = s % 1.0;
    if fr < 0.0 {
        fr += 1.0;
    }
    if fr.abs() < 0.0001 {
        s -= fr;
    } else if (fr - 1.0).abs() < 0.0001 {
        s = s - fr + 1.0;
    } else {
        s = s - fr + if fr > 0.5 || (fr - 0.5).abs() < 0.0001 { 1.0 } else { 0.0 };
    }
    if ppp == 1.0 { s } else { s / ppp }
}

/// A leaf measure up to the next pixel edge (UxmlPanelScale.ceil_pixel;
/// Unity's CeilToPixelGrid of a text measure).
pub fn ceil_pixel(v: f64, ppp: f64) -> f64 {
    (v * ppp - 0.001).ceil() / ppp
}

/// A margin, padding or border width on the pixel grid (measured in Unity
/// at every scale): margins and padding round to the nearest pixel, halves
/// up; a nonzero border is at least one pixel wide.
pub fn grid_box(v: f64, border: bool, ppp: f64) -> f64 {
    if border {
        if v <= 0.0 {
            0.0
        } else {
            let one = if ppp == 1.0 { 1.0 } else { 1.0 / ppp };
            one.max(pixel(v, ppp))
        }
    } else {
        pixel(v, ppp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_with_screen_size() {
        let s = Settings {
            scale_mode: SCALE_WITH_SCREEN_SIZE,
            reference_resolution: (1920, 1080),
            match_: 0.5,
            ..Default::default()
        };
        let r = resolve(&s, (2560.0, 1440.0), 96.0);
        assert_eq!(r.resolved_scale, 0.75);
        assert_eq!(r.pixels_per_point, 1.3333333730697632);
        assert_eq!(r.panel, (1920.0, 1080.0));
    }

    #[test]
    fn grid() {
        assert_eq!(pixel(2.5, 1.0), 3.0);
        assert_eq!(grid_box(0.4, true, 1.0), 1.0);
        assert_eq!(grid_box(0.4, true, 2.0), 0.5);
        assert_eq!(pixel(0.4, 2.0), 0.5);
    }
}
