//! Native core for godot-uxml. The GDScript implementation in
//! `addons/godot_uxml` stays the reference and the fallback: every native
//! entry point must produce exactly what its GDScript counterpart does.

use godot::prelude::*;

mod cascade;
mod layout;
pub mod panel_scale;
mod parse;
mod prof;
mod v2;
mod v2button;
pub mod v2model;
mod v2text;

struct UxmlNativeExtension;

#[gdextension]
unsafe impl ExtensionLibrary for UxmlNativeExtension {
    fn on_stage_deinit(stage: InitStage) {
        // The cascade's theme block cache holds Godot strings: drop it
        // while the engine is still up.
        if stage == InitStage::MainLoop || stage == InitStage::Scene {
            cascade::clear_cache();
            v2text::clear_cache();
        }
    }
}

/// Capability probe: GDScript checks `ClassDB.class_exists("UxmlNative")`.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct UxmlNative {
    base: Base<RefCounted>,
}

#[godot_api]
impl UxmlNative {
    #[func]
    fn version() -> GString {
        GString::from(env!("CARGO_PKG_VERSION"))
    }

    /// Native timers (bench/prof): on or off; prof_take() returns
    /// {slot: [ms, calls]} and clears them.
    #[func]
    fn prof_enable(on: bool) {
        prof::enable(on);
    }

    /// UxmlPanelScale.resolve in the native core: `settings` as
    /// UxmlPanelSettings.to_dict(), `screen` in pixels, `dpi` (0: unknown).
    /// Returns {resolved_scale, pixels_per_point, panel_size}.
    #[func]
    fn panel_scale(settings: VarDictionary, screen: Vector2, dpi: f64) -> VarDictionary {
        let mut s = panel_scale::Settings::default();
        let num = |k: &str, dflt: f64| -> f64 { settings.get(k).and_then(|v| v.try_to::<f64>().ok()).unwrap_or(dflt) };
        let int = |k: &str, dflt: i64| -> i64 { settings.get(k).and_then(|v| v.try_to::<i64>().ok()).unwrap_or(dflt) };
        s.scale_mode = int("scale_mode", s.scale_mode);
        s.scale = num("scale", s.scale);
        if let Some(r) = settings.get("reference_resolution").and_then(|v| v.try_to::<Vector2i>().ok()) {
            s.reference_resolution = (r.x as i64, r.y as i64);
        }
        s.screen_match_mode = int("screen_match_mode", s.screen_match_mode);
        s.match_ = num("match", s.match_);
        s.reference_dpi = num("reference_dpi", s.reference_dpi);
        s.fallback_dpi = num("fallback_dpi", s.fallback_dpi);
        let r = panel_scale::resolve(&s, (screen.x as f64, screen.y as f64), dpi);
        let mut d = VarDictionary::new();
        d.set("resolved_scale", r.resolved_scale);
        d.set("pixels_per_point", r.pixels_per_point);
        d.set("panel_size", Vector2::new(r.panel.0 as f32, r.panel.1 as f32));
        d
    }

    /// UxmlPanelScale.pixel and grid_box in the native core.
    #[func]
    fn panel_pixel(v: f64, ppp: f64) -> f64 {
        panel_scale::pixel(v, ppp)
    }

    #[func]
    fn panel_grid_box(v: f64, border: bool, ppp: f64) -> f64 {
        panel_scale::grid_box(v, border, ppp)
    }

    #[func]
    fn prof_take() -> VarDictionary {
        let mut d = VarDictionary::new();
        for (k, ns, n) in prof::take() {
            let mut a = VarArray::new();
            a.push(&(ns as f64 / 1e6).to_variant());
            a.push(&(n as i64).to_variant());
            d.set(k, &a.to_variant());
        }
        d
    }
}
