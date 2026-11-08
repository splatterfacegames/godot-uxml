//! Native core for godot-uxml. The GDScript implementation in
//! `addons/godot_uxml` stays the reference and the fallback: every native
//! entry point must produce exactly what its GDScript counterpart does.

use godot::prelude::*;

mod cascade;
mod layout;
mod parse;
mod prof;

struct UxmlNativeExtension;

#[gdextension]
unsafe impl ExtensionLibrary for UxmlNativeExtension {
    fn on_stage_deinit(stage: InitStage) {
        // The cascade's theme block cache holds Godot strings: drop it
        // while the engine is still up.
        if stage == InitStage::MainLoop || stage == InitStage::Scene {
            cascade::clear_cache();
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
