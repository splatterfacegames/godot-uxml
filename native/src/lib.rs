//! Native core for godot-uxml. The GDScript implementation in
//! `addons/godot_uxml` stays the reference and the fallback: every native
//! entry point must produce exactly what its GDScript counterpart does.

use godot::prelude::*;

mod cascade;
mod layout;
mod parse;

struct UxmlNativeExtension;

#[gdextension]
unsafe impl ExtensionLibrary for UxmlNativeExtension {}

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
}
