//! Runtime v2 (docs/design.md, "Runtime v2"): a document drawn by the core.
//!
//! The element table is the native cascade's (preorder index, parent,
//! subtree end); per element this keeps a visual record, the layout result
//! and a retained canvas item. Boxes, images, clipping, opacity and text
//! are recorded into RenderingServer canvas items under one host Control:
//! no Control per element. The cascade runs in table mode (its output is
//! the computed items, not Dictionaries); the layout is the native flex
//! pass with the leaves measured here (`LeafSource`); text is a port of
//! Godot's Label shaped once per element (`v2text`).
//!
//! Phase 1 covers static documents: VisualElement, TemplateContainer,
//! Label (plain text) and Image, the box model, borders, radii,
//! backgrounds, slices, clipping, opacity and text. `build` returns why a
//! document is not covered, and the document then loads on runtime v1.
//! Values are parsed with the GDScript implementation's own functions
//! (memoized per value), so the two runtimes read every value the same way.
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use godot::classes::{
    Control, Font, IRefCounted, Material, Object, RenderingServer, StyleBox, Texture2D,
};
use godot::prelude::*;

use crate::cascade::{Cascade, UxmlNativeCascade};
use crate::layout::{self, LeafSource, Len};
use crate::v2button::ButtonText;
use crate::v2text::{TextBlock, TextStyle, AUTOWRAP_OFF, AUTOWRAP_WORD_SMART, DEFAULT_TRIM};

/// Element kinds of the table.
const K_NONE: u8 = 0;
const K_BOX: u8 = 1;
const K_LABEL: u8 = 2;
const K_IMAGE: u8 = 3;
/// A Button: its box, and its text drawn as Godot's Button draws it.
const K_BUTTON: u8 = 4;
/// A text editor (the editor part of a TextField): a LineEdit or TextEdit
/// Control of the GDScript side draws it; the core measures it through
/// that Control and draws nothing.
const K_EDIT: u8 = 5;

/// Flags of the kinds handed to `build` by the GDScript side.
const F_KIND: u8 = 0x0f;
/// The element's attributes were checked by the GDScript side (controls
/// and their parts).
const F_ATTRS_OK: u8 = 0x80;
/// Plain text (a TextElement part): no rich text check.
const F_PLAIN: u8 = 0x40;
/// A part of a control: its name is internal (not in the name index).
const F_PART: u8 = 0x20;
/// A part that Unity does not pick (a Toggle's checkmark, a text part).
const F_UNPICKED: u8 = 0x10;

/// The properties the visual records read (P_*), by name.
const VIS_PROPS: [&str; 45] = [
    "background-color",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "opacity", "visibility", "display", "overflow", "-unity-overflow-clip-box",
    "color", "font-size", "-unity-font", "-unity-font-definition", "-unity-font-style",
    "-unity-text-align", "white-space", "-unity-text-outline-width", "-unity-text-outline-color",
    "letter-spacing", "word-spacing", "background-image", "text-overflow",
    "-unity-text-overflow-position", "--unity-image", "--unity-image-size", "--unity-image-tint-color",
    "-unity-slice-left", "-unity-slice-right", "-unity-slice-top", "-unity-slice-bottom",
    "-unity-background-image-tint-color", "translate",
];
const P_BG: usize = 0;
const P_BW: usize = 1;
const P_BC: usize = 5;
const P_BR: usize = 9;
const P_PAD: usize = 13;
const P_OPACITY: usize = 17;
const P_VISIBILITY: usize = 18;
const P_DISPLAY: usize = 19;
const P_OVERFLOW: usize = 20;
const P_CLIPBOX: usize = 21;
const P_COLOR: usize = 22;
const P_FONTSIZE: usize = 23;
const P_FONT: usize = 24;
const P_FONTDEF: usize = 25;
const P_FONTSTYLE: usize = 26;
const P_ALIGN: usize = 27;
const P_WS: usize = 28;
const P_OUTW: usize = 29;
const P_OUTC: usize = 30;
const P_LSP: usize = 31;
const P_WSP: usize = 32;
const P_BGIMG: usize = 33;
const P_TOVER: usize = 34;
const P_TOVERPOS: usize = 35;
const P_UIMG: usize = 36;
const P_TRANSLATE: usize = 44;
const NVP: usize = 45;

/// Properties that only the layout reads, or that phase 1 draws without a
/// record of its own (the background placement goes through the GDScript
/// background functions with the element's style).
const QUIET_PROPS: [&str; 7] = [
    "-unity-slice-scale", "-unity-slice-type", "background-position-x", "background-position-y",
    "background-repeat", "background-size", "-unity-background-scale-mode",
];

#[derive(Clone, Default)]
struct Vis {
    gone: bool,
    hidden: bool,
    opacity: f32,
    clip: bool,
    /// The clip of the children (UxmlClip): inset (l, t, r, b) and radii.
    clip_inset: [f32; 4],
    clip_radii: Option<PackedFloat64Array>,
    clip_content_box: bool,
    /// What the element's control draws first: its box (UxmlBox.box_style,
    /// a Label's normal stylebox), then the background image
    /// (box_texture_style or box_texture).
    box_sb: Option<Gd<StyleBox>>,
    img_sb: Option<Gd<StyleBox>>,
    img_tex: Option<Gd<Texture2D>>,
    /// Whether the box record draws (a Label's text is inset by the
    /// resolved border and padding only then: its stylebox carries them).
    boxed: bool,
    text: Option<TextStyle>,
    image: Option<(Gd<Texture2D>, i32, Color)>,
    picking_ignore: bool,
    /// `translate` (px, and the ratio of the element's own size).
    translate: Option<(Vector2, Vector2)>,
    /// A Button's clip_text (overflow: hidden on a Button,
    /// UxmlStyleApplier._apply_elision).
    bclip: bool,
    /// The text colour comes from USS (else a Button's theme colour of its
    /// draw mode).
    color_set: bool,
    /// text-overflow: ellipsis on a Label that clips and does not wrap: the
    /// -unity-text-overflow-position ("start", "middle", "end").
    elide: Option<GString>,
}

/// The leaves for the layout: kinds, box paddings, text blocks, natural
/// sizes.
struct Leaves {
    kind: Vec<u8>,
    hpad: Vec<f64>,
    natural: Vec<Vector2>,
    texts: RefCell<Vec<Option<TextBlock>>>,
    /// The texts of the Buttons.
    btexts: RefCell<Vec<Option<ButtonText>>>,
    /// The editor Controls (K_EDIT), measured as runtime v1 measures them.
    ctls: Vec<Option<Gd<Control>>>,
}

impl LeafSource for Leaves {
    fn kind(&self, i: usize) -> u8 {
        match self.kind[i] {
            K_LABEL | K_BUTTON => 1,
            K_IMAGE | K_EDIT => 2,
            _ => 0,
        }
    }
    fn wraps(&self, i: usize) -> bool {
        self.texts.borrow()[i].as_ref().is_some_and(|t| t.st.autowrap != AUTOWRAP_OFF)
    }
    fn empty(&self, i: usize) -> bool {
        if self.kind[i] == K_BUTTON {
            return self.btexts.borrow()[i].as_ref().is_none_or(|t| t.text.is_empty());
        }
        self.texts.borrow()[i].as_ref().is_none_or(|t| t.text.is_empty())
    }
    fn hpad(&self, i: usize) -> f64 {
        self.hpad[i]
    }
    fn text_min(&self, i: usize, width: f64) -> Vector2 {
        if self.kind[i] == K_BUTTON {
            // Button's minimum size less its stylebox; a clipped Button is
            // measured with its full text (UxmlDocument._measure_leaf).
            return self.btexts.borrow()[i].as_ref().map(|b| b.measure()).unwrap_or(Vector2::ZERO);
        }
        let mut t = self.texts.borrow_mut();
        let Some(b) = t[i].as_mut() else { return Vector2::ZERO };
        let hp = self.hpad[i];
        // Label shapes at `size.x - style_min.x` (an int).
        let w = ((width + hp) as f32 - hp as f32) as i32;
        b.min_size(w)
    }
    fn max_content(&self, i: usize) -> f64 {
        let mut t = self.texts.borrow_mut();
        t[i].as_mut().map(|b| b.max_content()).unwrap_or(0.0)
    }
    fn natural(&self, i: usize) -> Vector2 {
        if self.kind[i] == K_EDIT {
            // UxmlDocument._measure_leaf of the editor: its combined
            // minimum size less the `uxml_margins` of its stylebox.
            let Some(c) = self.ctls[i].as_ref() else { return Vector2::ZERO };
            let mut ms = c.get_combined_minimum_size();
            if let Some(m) = layout::read_margins(c, &StringName::from("normal"), &StringName::from("uxml_margins")) {
                ms.x = layout::f(f64::max(0.0, layout::d(ms.x) - m[0] - m[2]));
                ms.y = layout::f(f64::max(0.0, layout::d(ms.y) - m[1] - m[3]));
            }
            return ms;
        }
        self.natural[i]
    }
}

/// Default theme items of a Label (read once through the host).
#[derive(Clone)]
struct LabelTheme {
    font_color: Color,
    line_spacing: i32,
    paragraph_spacing: i32,
    outline_size: i32,
    outline_color: Color,
    shadow_color: Color,
    shadow_ofs: Vector2,
    shadow_outline_size: i32,
    normal_margins: [f32; 4],
}

/// Default theme items of a Button (read once through the host).
#[derive(Clone)]
struct ButtonTheme {
    font_color: Color,
    font_disabled_color: Color,
    font_focus_color: Color,
    line_spacing: i32,
    outline_size: i32,
    outline_color: Color,
}

struct St {
    casc: Gd<UxmlNativeCascade>,
    helper: Gd<Object>,
    host: Gd<Control>,
    n: usize,
    kind: Vec<u8>,
    texts_src: Vec<GString>,
    vis: Vec<Vis>,
    leaves: Rc<Leaves>,
    vp: Vec<i16>,
    allowed: Vec<bool>,
    rects: Vec<Option<Rect2>>,
    /// The size of each element at its last layout (kept under display:
    /// none, as a Control of runtime v1 keeps its size).
    last_size: Vec<Vector2>,
    insets: Vec<Option<(Vector2, Vector2)>>,
    items: Vec<Rid>,
    clips: Vec<Rid>,
    color_memo: HashMap<String, Option<Color>>,
    opacity_memo: HashMap<String, Option<f32>>,
    font_memo: HashMap<String, (Gd<Font>, i32)>,
    box_memo: HashMap<Vec<u64>, Option<Gd<StyleBox>>>,
    /// Visual records by the values they read (see make_vis); the values
    /// are kept so their addresses stay theirs.
    vis_memo: HashMap<Vec<usize>, (Vec<Rc<Variant>>, Vis, f64)>,
    theme: LabelTheme,
    btheme: ButtonTheme,
    locale: GString,
    /// Elements whose interaction Control has the focus (a focused Button
    /// draws its focus stylebox, the same box, over its box).
    focused: Vec<bool>,
    /// The disabled flags of the last restyle (effective_flags).
    disabled: Vec<bool>,
    /// A leaf measure changed since the last layout (a text shaped again,
    /// an image, a box padding, an editor): the layout must run.
    measure_dirty: bool,
    /// A record's display, visibility, opacity, clip or translate changed
    /// since the last take (the interaction Controls follow them).
    vis_changed: bool,
    /// The placement each interaction Control was last given (place_states).
    placed: Vec<Option<(Rect2, Rect2, bool, f32)>>,
    /// The last elision of each eliding Label: (text, width, position, font
    /// size) and the text shown; whether it is elided now.
    elide_memo: Vec<Option<((GString, f32, GString, i32), GString)>>,
    elided: Vec<bool>,
    unity_metrics: bool,
    recs: layout::RecCache,
    warned: VarDictionary,
    warnings: VarArray,
    host_size: Vector2,
    /// bench/pixels_render.gd: draw no text (the box-only render).
    text_hidden: bool,
    /// Elements whose record or text changed since their last draw, and
    /// the rect and insets each was last drawn at: draw() records again
    /// only those, and the elements the layout moved or resized.
    dirty: Vec<bool>,
    drawn: Vec<Option<(Rect2, Option<(Vector2, Vector2)>)>>,
    /// `name` attribute -> the first element (preorder) with it.
    by_name: HashMap<GString, i32>,
    /// The elements whose name an earlier element has (diagnosed).
    dup_names: Vec<i32>,
}

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct UxmlRuntimeV2 {
    base: Base<RefCounted>,
    st: Option<St>,
}

#[godot_api]
impl IRefCounted for UxmlRuntimeV2 {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, st: None }
    }
}

impl Drop for UxmlRuntimeV2 {
    fn drop(&mut self) {
        self.free_items();
    }
}

fn s(v: &Variant) -> String {
    v.try_to::<GString>().map(|g| g.to_string()).unwrap_or_default()
}

fn rs() -> Gd<RenderingServer> {
    RenderingServer::singleton()
}

#[godot_api]
impl UxmlRuntimeV2 {
    /// Builds the element table of a document whose cascade ran in table
    /// mode. `helper` is the GDScript side (UxmlRuntimeV2Glue): the value
    /// parsers and resources of runtime v1. Returns "" when the document is
    /// covered, else why not (the document then loads on runtime v1).
    #[func]
    fn build(&mut self, casc: Gd<UxmlNativeCascade>, host: Gd<Control>, helper: Gd<Object>, unity_metrics: bool, kinds_in: PackedByteArray) -> GString {
        let _p = crate::prof::scope("v2.build");
        self.free_items();
        self.st = None;
        let cb = casc.bind();
        let Some(c) = cb.inner.as_ref() else { return "no native cascade".into() };
        let n = c.len();
        // Property ids: the visual records' and the allowed set.
        let pc = c.prop_count();
        let mut vp = vec![-1i16; pc];
        for (k, name) in VIS_PROPS.iter().enumerate() {
            if let Some(id) = c.prop_id(name) {
                vp[id as usize] = k as i16;
            }
        }
        let mut allowed = vec![false; pc];
        for pid in 0..pc {
            let name = c.prop_name(pid as u32).to_string();
            allowed[pid] = vp[pid] >= 0
                || name.starts_with("--")
                || layout::LAYOUT_PROPS.contains(&name.as_str())
                || QUIET_PROPS.contains(&name.as_str());
        }
        let mut kind = vec![K_NONE; n];
        let mut texts = vec![GString::new(); n];
        let mut names: Vec<Option<GString>> = vec![None; n];
        let kn = "name".to_variant();
        let kv = "value".to_variant();
        let mut picking = vec![false; n];
        let kin = kinds_in.as_slice();
        for i in 0..n {
            let local = c.local_name(i);
            let given = kin.get(i).copied().unwrap_or(0);
            kind[i] = if given & F_KIND != 0 {
                given & F_KIND
            } else {
                match local {
                    "UXML" if i == 0 => K_BOX,
                    "UXML" | "Style" => K_NONE,
                    "VisualElement" | "TemplateContainer" => K_BOX,
                    "Label" => K_LABEL,
                    "Image" => K_IMAGE,
                    other => return GString::from(format!("element <{}> (index {}) is not drawn by runtime v2 yet", other, i).as_str()),
                }
            };
            let attrs_ok = given & F_ATTRS_OK != 0;
            let plain = given & F_PLAIN != 0;
            let part = given & F_PART != 0;
            if given & F_UNPICKED != 0 {
                picking[i] = true;
            }
            if kind[i] == K_NONE {
                continue;
            }
            for it in c.items(i).iter() {
                if !allowed[it.pid as usize] {
                    return GString::from(format!("property {} (element {}) is not drawn by runtime v2 yet", c.prop_name(it.pid), i).as_str());
                }
            }
            // The <UXML> root's attributes are namespaces and editor settings.
            let attrs = if i == 0 { VarArray::new() } else { c.attributes(i) };
            let (mut seen_text, mut rich_on, mut escapes) = (false, true, false);
            let texty = kind[i] == K_LABEL || kind[i] == K_BUTTON;
            for a in attrs.iter_shared() {
                let Ok(d) = a.try_to::<VarDictionary>() else { continue };
                let an = s(&d.get(&kn).unwrap_or_default());
                let avv = d.get(&kv).unwrap_or_default();
                if attrs_ok {
                    // Checked by the GDScript side; only what the core reads.
                    match an.as_str() {
                        "name" if names[i].is_none() && !part => names[i] = Some(avv.try_to::<GString>().unwrap_or_default()),
                        "text" if texty && !seen_text => {
                            texts[i] = avv.try_to::<GString>().unwrap_or_default();
                            seen_text = true;
                        }
                        "enable-rich-text" if texty => rich_on = s(&avv).trim() != "false",
                        "parse-escape-sequences" if texty => escapes = s(&avv).trim() == "true",
                        "picking-mode" => {
                            let av = s(&avv);
                            let v = av.trim();
                            if v == "Ignore" {
                                picking[i] = true;
                            } else if v != "Position" {
                                return "picking-mode with an invalid value".into();
                            }
                        }
                        _ => {}
                    }
                    continue;
                }
                match an.as_str() {
                    "class" | "style" | "usage-hints" | "view-data-key" | "content-container" | "template"
                    | "src" | "image" | "enabled" => {}
                    "name" => {
                        if names[i].is_none() {
                            names[i] = Some(avv.try_to::<GString>().unwrap_or_default());
                        }
                    }
                    "text" if kind[i] == K_LABEL => {
                        if !seen_text {
                            texts[i] = avv.try_to::<GString>().unwrap_or_default();
                            seen_text = true;
                        }
                    }
                    "enable-rich-text" if kind[i] == K_LABEL => rich_on = s(&avv).trim() != "false",
                    "parse-escape-sequences" if kind[i] == K_LABEL => escapes = s(&avv).trim() == "true",
                    "display-tooltip-when-elided" if kind[i] == K_LABEL => {}
                    "picking-mode" => {
                        let av = s(&avv);
                        let v = av.trim();
                        if v == "Ignore" {
                            picking[i] = true;
                        } else if v != "Position" {
                            return "picking-mode with an invalid value".into();
                        }
                    }
                    // The GDScript side makes the interaction Control and the tooltip.
                    "focusable" | "tooltip" => {}
                    other => return GString::from(format!("attribute {} (element {}) is not handled by runtime v2 yet", other, i).as_str()),
                }
            }
            if kind[i] == K_BUTTON || (kind[i] == K_LABEL && plain) {
                // A Button's and a TextElement's text are plain.
                if escapes && texts[i].to_string().contains('\\') {
                    return "escape sequences".into();
                }
            } else if kind[i] == K_LABEL {
                // Rich text and escape sequences stay on runtime v1.
                let t = texts[i].to_string();
                if rich_on && t.contains('<') {
                    return "rich text".into();
                }
                if escapes && t.contains('\\') {
                    return "escape sequences".into();
                }
            }
        }
        drop(cb);
        let theme = {
            let mut h = helper.clone();
            let d = h.call("v2_label_theme", &[]).try_to::<VarDictionary>().unwrap_or_default();
            let col = |k: &str| d.get(k).and_then(|v| v.try_to::<Color>().ok()).unwrap_or(Color::from_rgba(0.0, 0.0, 0.0, 0.0));
            let int = |k: &str| d.get(k).and_then(|v| v.try_to::<i64>().ok()).unwrap_or(0) as i32;
            let m = d.get("normal_margins").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).unwrap_or_default();
            let ms = m.as_slice();
            LabelTheme {
                font_color: col("font_color"),
                line_spacing: int("line_spacing"),
                paragraph_spacing: int("paragraph_spacing"),
                outline_size: int("outline_size"),
                outline_color: col("font_outline_color"),
                shadow_color: col("font_shadow_color"),
                shadow_ofs: Vector2::new(int("shadow_offset_x") as f32, int("shadow_offset_y") as f32),
                shadow_outline_size: int("shadow_outline_size"),
                normal_margins: if ms.len() == 4 { [ms[0], ms[1], ms[2], ms[3]] } else { [0.0; 4] },
            }
        };
        let (btheme, locale) = {
            let mut h = helper.clone();
            let d = h.call("v2_button_theme", &[]).try_to::<VarDictionary>().unwrap_or_default();
            let col = |k: &str| d.get(k).and_then(|v| v.try_to::<Color>().ok()).unwrap_or(Color::from_rgba(0.0, 0.0, 0.0, 0.0));
            let int = |k: &str| d.get(k).and_then(|v| v.try_to::<i64>().ok()).unwrap_or(0) as i32;
            (
                ButtonTheme {
                    font_color: col("font_color"),
                    font_disabled_color: col("font_disabled_color"),
                    font_focus_color: col("font_focus_color"),
                    line_spacing: int("line_spacing"),
                    outline_size: int("outline_size"),
                    outline_color: col("font_outline_color"),
                },
                d.get("locale").and_then(|v| v.try_to::<GString>().ok()).unwrap_or_default(),
            )
        };
        let mut st = St {
            casc,
            helper,
            host,
            n,
            kind: kind.clone(),
            texts_src: texts,
            vis: vec![Vis::default(); n],
            leaves: Rc::new(Leaves {
                kind,
                hpad: vec![0.0; n],
                natural: vec![Vector2::ZERO; n],
                texts: RefCell::new((0..n).map(|_| None).collect()),
                btexts: RefCell::new((0..n).map(|_| None).collect()),
                ctls: vec![None; n],
            }),
            vp,
            allowed,
            rects: vec![None; n],
            last_size: vec![Vector2::ZERO; n],
            insets: vec![None; n],
            items: vec![],
            clips: vec![],
            color_memo: HashMap::new(),
            opacity_memo: HashMap::new(),
            font_memo: HashMap::new(),
            box_memo: HashMap::new(),
            vis_memo: HashMap::new(),
            theme,
            btheme,
            locale,
            focused: vec![false; n],
            disabled: vec![false; n],
            measure_dirty: true,
            vis_changed: true,
            placed: vec![None; n],
            elide_memo: vec![None; n],
            elided: vec![false; n],
            unity_metrics,
            recs: layout::RecCache::default(),
            warned: VarDictionary::new(),
            warnings: VarArray::new(),
            host_size: Vector2::ZERO,
            text_hidden: false,
            by_name: HashMap::new(),
            dup_names: vec![],
            dirty: vec![true; n],
            drawn: vec![None; n],
        };
        for i in 0..n {
            st.vis[i].picking_ignore = picking[i];
            if let Some(nm) = names[i].take() {
                if st.by_name.contains_key(&nm) {
                    st.dup_names.push(i as i32);
                } else {
                    st.by_name.insert(nm, i as i32);
                }
            }
        }
        if let Err(why) = st.restyle_all() {
            return GString::from(why.as_str());
        }
        self.st = Some(st);
        GString::new()
    }

    /// Restyles the elements of `changed` (preorder indices) after a
    /// cascade update; "" or why the document cannot stay on runtime v2.
    #[func]
    fn restyle(&mut self, changed: PackedInt32Array) -> GString {
        let Some(st) = self.st.as_mut() else { return "not built".into() };
        // Text props and picking stay; the records are made again.
        let all: Vec<usize> = changed.as_slice().iter().filter(|&&i| i >= 0).map(|&i| i as usize).collect();
        match st.restyle_some(&all) {
            Ok(()) => GString::new(),
            Err(w) => GString::from(w.as_str()),
        }
    }

    /// Lays the document out at `host` (the host Control's size).
    #[func]
    fn layout(&mut self, host: Vector2) -> bool {
        let Some(st) = self.st.as_mut() else { return false };
        st.layout(host)
    }

    /// Lays out only when something the layout reads changed since the last
    /// layout (a layout record, a leaf measure, the host size), or `force`.
    /// Returns whether a rect changed.
    #[func]
    fn layout_if_needed(&mut self, host: Vector2, force: bool) -> bool {
        let Some(st) = self.st.as_mut() else { return false };
        if !force && !st.measure_dirty && host == st.host_size && !st.records_changed() {
            return false;
        }
        st.layout(host)
    }

    /// For each of `idx`: [position, size, visible rect position, visible
    /// rect size] in `rects` and [shown, opacity] in `states` (the
    /// interaction Controls' placement in one call).
    /// Only the entries whose placement changed since the last call are
    /// returned; `which` holds their positions in `idx`.
    #[func]
    fn place_states(&mut self, idx: PackedInt32Array) -> VarArray {
        let mut out = VarArray::new();
        let Some(st) = self.st.as_mut() else { return out };
        let mut rects = PackedVector2Array::new();
        let mut shown = PackedByteArray::new();
        let mut op = PackedFloat32Array::new();
        let mut which = PackedInt32Array::new();
        let mut placed = std::mem::take(&mut st.placed);
        let cb = st.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        for (kk, &i) in idx.as_slice().iter().enumerate() {
            let i = i as usize;
            let r = st.host_rect(i);
            let mut sh = i < st.n && st.rects[i].is_some();
            let mut o = 1.0f32;
            let mut vis = r;
            if i < st.n {
                let mut k = i as i32;
                while k >= 0 {
                    let ku = k as usize;
                    let v = &st.vis[ku];
                    if v.gone || v.hidden {
                        sh = false;
                    }
                    o *= v.opacity;
                    if ku != i && k > 0 && v.clip {
                        let ar = st.host_rect(ku);
                        let ins = st.clip_inset_of(ku);
                        let cr = Rect2::new(
                            ar.position + Vector2::new(ins[0], ins[1]),
                            Vector2::new((ar.size.x - ins[0] - ins[2]).max(0.0), (ar.size.y - ins[1] - ins[3]).max(0.0)),
                        );
                        vis = vis.intersect(cr).unwrap_or(Rect2::new(vis.position, Vector2::ZERO));
                    }
                    k = c.parent_of(ku);
                }
            }
            let now = Some((r, vis, sh, o));
            if i < placed.len() && placed[i] == now {
                continue;
            }
            if i < placed.len() {
                placed[i] = now;
            }
            which.push(kk as i32);
            rects.push(r.position);
            rects.push(r.size);
            rects.push(vis.position);
            rects.push(vis.size);
            shown.push(if sh { 1 } else { 0 });
            op.push(o);
        }
        drop(cb);
        st.placed = placed;
        out.push(&rects.to_variant());
        out.push(&shown.to_variant());
        out.push(&op.to_variant());
        out.push(&which.to_variant());
        out
    }

    /// Records every element's canvas item again.
    #[func]
    fn draw(&mut self) {
        if let Some(st) = self.st.as_mut() {
            st.draw_all();
        }
    }

    /// Frees the canvas items.
    #[func]
    fn free_items(&mut self) {
        if let Some(st) = self.st.as_mut() {
            st.free_items();
        }
    }

    #[func]
    fn set_text(&mut self, i: i64, text: GString) -> bool {
        let Some(st) = self.st.as_mut() else { return false };
        let i = i as usize;
        if i >= st.n || (st.kind[i] != K_LABEL && st.kind[i] != K_BUTTON) {
            return false;
        }
        st.texts_src[i] = text;
        st.make_text(i);
        st.dirty[i] = true;
        true
    }

    /// Element i's interaction Control has the focus (a Button then draws
    /// its focus box).
    #[func]
    fn set_focused(&mut self, i: i64, on: bool) {
        let Some(st) = self.st.as_mut() else { return };
        let i = i as usize;
        if i < st.n && st.focused[i] != on {
            st.focused[i] = on;
            st.dirty[i] = true;
        }
    }

    /// The editor Control of element i (K_EDIT): the layout measures it.
    #[func]
    fn set_edit_control(&mut self, i: i64, ctl: Option<Gd<Control>>) {
        let Some(st) = self.st.as_mut() else { return };
        let i = i as usize;
        if i < st.n {
            st.leaves_mut().ctls[i] = ctl;
            st.measure_dirty = true;
        }
    }

    /// Element i's visibility as drawn: shown (it and its ancestors), and
    /// the product of their opacities (an editor Control follows them).
    #[func]
    fn draw_state(&self, i: i64) -> VarArray {
        let mut a = VarArray::new();
        let Some(st) = self.st.as_ref() else { return a };
        let i = i as usize;
        let mut shown = st.rects.get(i).is_some_and(|r| r.is_some());
        let mut op = 1.0f32;
        if i < st.n {
            let cb = st.casc.bind();
            let c = cb.inner.as_ref().unwrap();
            let mut k = i as i32;
            while k >= 0 {
                let v = &st.vis[k as usize];
                if v.gone || v.hidden {
                    shown = false;
                }
                op *= v.opacity;
                k = c.parent_of(k as usize);
            }
        }
        a.push(&shown.to_variant());
        a.push(&op.to_variant());
        a
    }

    /// The size element i is drawn at: its layout size, or a Button's size
    /// floored at its minimum (bench/equiv_v2.gd traces).
    #[func]
    fn drawn_size(&self, i: i64) -> Vector2 {
        let Some(st) = self.st.as_ref() else { return Vector2::ZERO };
        let i = i as usize;
        let Some(r) = st.rects.get(i).copied().flatten() else { return Vector2::ZERO };
        if st.kind[i] == K_BUTTON {
            let (s0, e0) = st.insets[i].unwrap_or((Vector2::ZERO, Vector2::ZERO));
            if let Some(b) = st.leaves.btexts.borrow().get(i).and_then(|b| b.as_ref()) {
                return b.fit(r.size, [s0.x, s0.y, e0.x, e0.y], st.vis[i].bclip).1;
            }
        }
        r.size
    }

    /// The size of element i at its last layout (zero before one).
    #[func]
    fn last_size(&self, i: i64) -> Vector2 {
        self.st.as_ref().and_then(|s| s.last_size.get(i as usize).copied()).unwrap_or(Vector2::ZERO)
    }

    /// Whether a record's display, visibility, opacity, clip or translate
    /// changed since the last call.
    #[func]
    fn take_vis_changed(&mut self) -> bool {
        let Some(st) = self.st.as_mut() else { return false };
        std::mem::replace(&mut st.vis_changed, false)
    }

    /// Whether Label i shows its text elided (its last draw).
    #[func]
    fn is_elided(&self, i: i64) -> bool {
        self.st.as_ref().and_then(|s| s.elided.get(i as usize).copied()).unwrap_or(false)
    }

    /// The first element (preorder) named `name`, -1 for none.
    #[func]
    fn find_name(&self, name: GString) -> i64 {
        self.st.as_ref().and_then(|s| s.by_name.get(&name).copied()).unwrap_or(-1) as i64
    }

    /// The elements whose name an earlier element has.
    #[func]
    fn duplicate_names(&self) -> PackedInt32Array {
        self.st.as_ref().map(|s| PackedInt32Array::from(s.dup_names.as_slice())).unwrap_or_default()
    }

    /// Draws no text (bench/pixels_render.gd's render without text).
    #[func]
    fn set_text_hidden(&mut self, on: bool) {
        if let Some(st) = self.st.as_mut() {
            st.text_hidden = on;
            st.dirty.fill(true);
        }
    }

    #[func]
    fn get_text(&self, i: i64) -> GString {
        self.st.as_ref().and_then(|s| s.texts_src.get(i as usize).cloned()).unwrap_or_default()
    }

    /// The border box of element i relative to its parent (as the layout
    /// placed it; zero size for an element that is not laid out).
    #[func]
    fn local_rect(&self, i: i64) -> Rect2 {
        self.st.as_ref().and_then(|s| s.rects.get(i as usize).copied().flatten()).unwrap_or(Rect2::new(Vector2::ZERO, Vector2::ZERO))
    }

    /// The part of element i's border box (host coordinates) inside the
    /// clips of its clipping ancestors (empty when clipped away).
    #[func]
    fn visible_rect(&self, i: i64) -> Rect2 {
        let Some(st) = self.st.as_ref() else { return Rect2::new(Vector2::ZERO, Vector2::ZERO) };
        let i = i as usize;
        let mut r = st.host_rect(i);
        let cb = st.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        let mut a = c.parent_of(i);
        while a > 0 {
            let au = a as usize;
            if st.vis[au].clip {
                let ar = st.host_rect(au);
                let ins = st.clip_inset_of(au);
                let cr = Rect2::new(
                    ar.position + Vector2::new(ins[0], ins[1]),
                    Vector2::new((ar.size.x - ins[0] - ins[2]).max(0.0), (ar.size.y - ins[1] - ins[3]).max(0.0)),
                );
                r = match r.intersect(cr) {
                    Some(x) => x,
                    None => return Rect2::new(r.position, Vector2::ZERO),
                };
            }
            a = c.parent_of(au);
        }
        r
    }

    /// The border box of element i in the host's coordinates.
    #[func]
    fn host_rect(&self, i: i64) -> Rect2 {
        let Some(st) = self.st.as_ref() else { return Rect2::new(Vector2::ZERO, Vector2::ZERO) };
        st.host_rect(i as usize)
    }

    /// [start insets, end insets] of element i (border + padding, resolved).
    #[func]
    fn insets_of(&self, i: i64) -> VarArray {
        let mut a = VarArray::new();
        if let Some((s0, e0)) = self.st.as_ref().and_then(|s| s.insets.get(i as usize).copied().flatten()) {
            a.push(&s0.to_variant());
            a.push(&e0.to_variant());
        }
        a
    }

    /// Whether element i is shown (laid out, not display: none, not
    /// hidden, its ancestors shown).
    #[func]
    fn is_shown(&self, i: i64) -> bool {
        self.st.as_ref().is_some_and(|s| s.shown(i as usize))
    }

    /// The kind of element i: 0 not drawn, 1 box, 2 label, 3 image.
    #[func]
    fn kind_of(&self, i: i64) -> i64 {
        self.st.as_ref().and_then(|s| s.kind.get(i as usize).copied()).unwrap_or(0) as i64
    }

    /// The canvas item of element i (the children's parent item is its
    /// clip item when it clips them with an inset or radii).
    #[func]
    fn item_of(&self, i: i64) -> Rid {
        self.st.as_ref().and_then(|s| s.items.get(i as usize).copied()).unwrap_or(Rid::Invalid)
    }

    /// The topmost element under `point` (host coordinates), -1 for none.
    /// `respect_picking`: elements with picking-mode Ignore are skipped
    /// (their children still pick).
    #[func]
    fn pick(&self, point: Vector2, respect_picking: bool) -> i64 {
        let Some(st) = self.st.as_ref() else { return -1 };
        st.pick(point, respect_picking)
    }

    /// The layout warnings of the passes since the build.
    #[func]
    fn warnings(&self) -> VarArray {
        self.st.as_ref().map(|s| s.warnings.clone()).unwrap_or_default()
    }

    /// Debug: the visual record of element i.
    #[func]
    fn record_of(&self, i: i64) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(st) = self.st.as_ref() else { return d };
        let Some(v) = st.vis.get(i as usize) else { return d };
        d.set("gone", v.gone);
        d.set("hidden", v.hidden);
        d.set("opacity", v.opacity);
        d.set("clip", v.clip);
        d.set("clip_inset", &PackedFloat32Array::from(&v.clip_inset[..]).to_variant());
        d.set("clip_item", st.clips.get(i as usize).is_some_and(|c| c.is_valid()));
        d.set("boxed", v.boxed);
        d.set("box", &v.box_sb.clone().map(|b| b.to_variant()).unwrap_or_default());
        if let Some(t) = &v.text {
            d.set("font", &t.font.to_variant());
            d.set("font_size", t.size);
            d.set("color", t.color);
            d.set("autowrap", t.autowrap);
            d.set("halign", t.halign);
            d.set("valign", t.valign);
        }
        d
    }
}

impl St {
    fn cascade(&self) -> GdRef<'_, UxmlNativeCascade> {
        self.casc.bind()
    }

    fn color(&mut self, v: &Variant) -> Result<Color, String> {
        let k = s(v);
        if let Some(c) = self.color_memo.get(&k) {
            return c.ok_or_else(|| format!("color {}", k));
        }
        let r = self.helper.call("v2_color", &[v.clone()]);
        let c = r.try_to::<Color>().ok();
        self.color_memo.insert(k.clone(), c);
        c.ok_or_else(|| format!("color {}", k))
    }

    fn opacity(&mut self, v: &Variant) -> Result<f32, String> {
        let k = s(v);
        if let Some(c) = self.opacity_memo.get(&k) {
            return c.ok_or_else(|| format!("opacity {}", k));
        }
        let r = self.helper.call("v2_opacity", &[v.clone()]);
        let c = r.try_to::<f64>().ok().map(|x| x as f32);
        self.opacity_memo.insert(k.clone(), c);
        c.ok_or_else(|| format!("opacity {}", k))
    }

    fn restyle_all(&mut self) -> Result<(), String> {
        let all: Vec<usize> = (0..self.n).collect();
        self.restyle_some(&all)
    }

    /// Property ids registered after the build (a declaration seen first
    /// in an inline style set later) get their entries.
    fn ensure_props(&mut self) {
        let cb = self.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        let pc = c.prop_count();
        let mut add: Vec<(i16, bool)> = vec![];
        for pid in self.vp.len()..pc {
            let name = c.prop_name(pid as u32).to_string();
            let k = VIS_PROPS.iter().position(|p| *p == name).map(|k| k as i16).unwrap_or(-1);
            let ok = k >= 0 || name.starts_with("--") || layout::LAYOUT_PROPS.contains(&name.as_str()) || QUIET_PROPS.contains(&name.as_str());
            add.push((k, ok));
        }
        drop(cb);
        for (k, ok) in add {
            self.vp.push(k);
            self.allowed.push(ok);
        }
    }

    fn restyle_some(&mut self, which: &[usize]) -> Result<(), String> {
        let _p = crate::prof::scope("v2.restyle");
        self.ensure_props();
        let (dis, gone) = {
            let mut cb = self.casc.bind_mut();
            let c = cb.inner.as_mut().unwrap();
            let f = c.effective_flags();
            (f.1, f.2)
        };
        let gone = gone.as_slice().to_vec();
        // A Button without a USS colour draws the theme colour of its draw
        // mode: its disabled flag matters.
        for (i, &d) in dis.as_slice().iter().enumerate() {
            if i < self.n && self.disabled[i] != (d == 1) {
                self.disabled[i] = d == 1;
                if self.kind[i] == K_BUTTON {
                    self.dirty[i] = true;
                }
            }
        }
        for &i in which {
            if i >= self.n || self.kind[i] == K_NONE {
                continue;
            }
            self.make_vis(i, gone[i] == 1)?;
        }
        // Elements whose own record did not change can still flip their
        // display flag (an ancestor's display).
        for i in 0..self.n {
            if self.vis[i].gone != (gone[i] == 1) {
                self.vis[i].gone = gone[i] == 1;
                self.dirty[i] = true;
                self.vis_changed = true;
            }
        }
        Ok(())
    }

    /// The visual record of element i from its computed items.
    fn make_vis(&mut self, i: usize, gone: bool) -> Result<(), String> {
        let mut vals: [Option<Variant>; NVP] = std::array::from_fn(|_| None);
        let mut lay_ok = true;
        // The record is a function of the values the record reads (the
        // cascade shares a declaration's value between the elements it
        // reaches): elements with the same values share it. Images and
        // background images read the element too.
        let mut key: Vec<usize> = vec![self.kind[i] as usize];
        let mut keep: Vec<Rc<Variant>> = vec![];
        {
            let cb = self.cascade();
            let c = cb.inner.as_ref().unwrap();
            for it in c.items(i).iter() {
                let pid = it.pid as usize;
                if !self.allowed[pid] {
                    lay_ok = false;
                    break;
                }
                let k = self.vp[pid];
                if k >= 0 {
                    vals[k as usize] = Some((*it.value).clone());
                    key.push(k as usize);
                    key.push(Rc::as_ptr(&it.value) as usize);
                    keep.push(it.value.clone());
                }
            }
        }
        if !lay_ok {
            return Err(format!("element {}: a property runtime v2 does not draw", i));
        }
        // url() values resolve against the file of their declaration, which
        // the shared value of an inline style does not tell.
        let memo_ok = self.kind[i] != K_IMAGE
            && vals[P_BGIMG].is_none()
            && ![P_FONT, P_FONTDEF].iter().any(|&k| vals[k].as_ref().is_some_and(|x| s(x).contains("url(")));
        if memo_ok {
            if let Some((_, rec, hp)) = self.vis_memo.get(&key) {
                let mut v = rec.clone();
                v.picking_ignore = self.vis[i].picking_ignore;
                v.gone = gone;
                let hp = *hp;
                if Self::placement_differs(&self.vis[i], &v) {
                    self.vis_changed = true;
                }
                if self.leaves.hpad[i] != hp {
                    self.leaves_mut().hpad[i] = hp;
                    self.measure_dirty = true;
                }
                self.vis[i] = v;
                self.dirty[i] = true;
                if self.kind[i] == K_LABEL || self.kind[i] == K_BUTTON {
                    self.make_text(i);
                }
                return Ok(());
            }
        }
        let str_of = |k: usize| vals[k].as_ref().map(s).unwrap_or_default();
        let mut v = Vis { picking_ignore: self.vis[i].picking_ignore, opacity: 1.0, gone, ..Default::default() };
        // display / visibility (UxmlStyleApplier.apply_flags).
        let display = str_of(P_DISPLAY);
        let visibility = str_of(P_VISIBILITY);
        v.hidden = visibility == "hidden" || visibility == "collapse";
        if !visibility.is_empty() && visibility != "visible" && !v.hidden {
            return Err("visibility value".into());
        }
        if !display.is_empty() && display != "flex" && display != "none" {
            return Err("display value".into());
        }
        // opacity.
        if let Some(o) = vals[P_OPACITY].clone() {
            v.opacity = self.opacity(&o)?;
        }
        // The box record (UxmlStyleApplier._box_rec_of).
        let bg = match vals[P_BG].clone() {
            Some(x) => Some(self.color(&x)?),
            None => None,
        };
        let mut widths = [0.0f64; 4];
        for k in 0..4 {
            if let Some(x) = &vals[P_BW + k] {
                match layout::parse_length(&s(x)) {
                    Len::Px(w) => widths[k] = crate::panel_scale::grid_box(w.max(0.0), true, 1.0),
                    _ => return Err("border width".into()),
                }
            }
        }
        let mut any_bcolor = false;
        let mut bcolors = [Color::from_rgba(0.0, 0.0, 0.0, 0.0); 4];
        for k in 0..4 {
            if let Some(x) = vals[P_BC + k].clone() {
                bcolors[k] = self.color(&x)?;
                any_bcolor = true;
            }
        }
        let mut drawn: Option<Color> = None;
        let mut mixed = false;
        let mut first_bcolor: Option<Color> = None;
        for k in 0..4 {
            if vals[P_BC + k].is_some() && first_bcolor.is_none() {
                first_bcolor = Some(bcolors[k]);
            }
        }
        for k in 0..4 {
            if widths[k] > 0.0 {
                match drawn {
                    None => drawn = Some(bcolors[k]),
                    Some(dc) if dc != bcolors[k] => mixed = true,
                    _ => {}
                }
            }
        }
        if !mixed {
            for k in 0..4 {
                if widths[k] > 0.0 {
                    first_bcolor = Some(bcolors[k]);
                    break;
                }
            }
        }
        let mut radii = [0.0f64; 4];
        let mut any_radius = false;
        for k in 0..4 {
            if let Some(x) = &vals[P_BR + k] {
                match layout::parse_length(&s(x)) {
                    Len::Px(r) => radii[k] = r.max(0.0),
                    _ => return Err("border radius".into()),
                }
                any_radius = any_radius || radii[k] > 0.0;
            }
        }
        let mut pads = [0.0f64; 4];
        let mut any_pad = false;
        for k in 0..4 {
            if let Some(x) = &vals[P_PAD + k] {
                match layout::parse_length(&s(x)) {
                    Len::Px(p) => pads[k] = p.max(0.0),
                    Len::Pct(_) => any_pad = true,
                    _ => {}
                }
                any_pad = any_pad || pads[k] > 0.0;
            }
        }
        let any_border = widths.iter().any(|&w| w > 0.0);
        let has_visual = bg.is_some() || any_border || any_bcolor || any_radius || any_pad;
        let bg_img = vals[P_BGIMG].is_some();
        let button = self.kind[i] == K_BUTTON;
        // A Button's box and background image are those of a themed
        // control, as a Label's (UxmlStyleApplier._apply_themed_inner).
        let label = self.kind[i] == K_LABEL || button;
        if self.kind[i] == K_EDIT {
            // The editor Control draws its own box.
        } else if bg_img {
            // The background image (and the box it goes with) as runtime v1
            // builds them (UxmlStyleApplier._apply_box / _apply_themed_inner).
            let r = self.helper.call("v2_boxes", &[(i as i64).to_variant(), label.to_variant()]);
            let a = r.try_to::<VarArray>().map_err(|_| "background image".to_string())?;
            if a.len() != 4 {
                return Err(format!("background image of element {}", i));
            }
            v.box_sb = a.get(0).and_then(|x| x.try_to::<Gd<StyleBox>>().ok());
            v.img_sb = a.get(1).and_then(|x| x.try_to::<Gd<StyleBox>>().ok());
            v.img_tex = a.get(2).and_then(|x| x.try_to::<Gd<Texture2D>>().ok());
            v.boxed = a.get(3).and_then(|x| x.try_to::<bool>().ok()).unwrap_or(false);
        } else if has_visual {
            let kind = if any_radius || mixed || (any_border && bg.is_some_and(|b| b.a > 0.0)) { 1 } else { 2 };
            let mut key: Vec<u64> = vec![kind as u64];
            let cbits = |c: &Color| -> [u64; 2] {
                [((c.r.to_bits() as u64) << 32) | c.g.to_bits() as u64, ((c.b.to_bits() as u64) << 32) | c.a.to_bits() as u64]
            };
            match bg {
                Some(b) => key.extend(cbits(&b)),
                None => key.push(u64::MAX),
            }
            for k in 0..4 {
                key.push(widths[k].to_bits());
                key.push(radii[k].to_bits());
                key.extend(cbits(&bcolors[k]));
            }
            if kind == 2 {
                match first_bcolor {
                    Some(c) => key.extend(cbits(&c)),
                    None => key.push(u64::MAX),
                }
            }
            let sb = match self.box_memo.get(&key) {
                Some(b) => b.clone(),
                None => {
                    let mut rec = VarArray::new();
                    rec.push(&(kind as i64).to_variant());
                    rec.push(&bg.map(|b| b.to_variant()).unwrap_or_default());
                    rec.push(&PackedFloat64Array::from(&widths[..]).to_variant());
                    let mut cols = VarArray::new();
                    for c in bcolors.iter() {
                        cols.push(&c.to_variant());
                    }
                    rec.push(&cols.to_variant());
                    rec.push(&PackedFloat64Array::from(&radii[..]).to_variant());
                    rec.push(&(if kind == 2 { first_bcolor.map(|c| c.to_variant()).unwrap_or_default() } else { Variant::nil() }));
                    let mut m = VarArray::new();
                    for x in [widths[3] + pads[3], widths[0] + pads[0], widths[1] + pads[1], widths[2] + pads[2]] {
                        m.push(&x.to_variant());
                    }
                    rec.push(&m.to_variant());
                    // _R_PX: the antialiased edge, one device pixel (pixels
                    // per point 1: runtime v2 has no panel scaling).
                    rec.push(&1.0f64.to_variant());
                    let b = self.helper.call("v2_make_box", &[rec.to_variant()]).try_to::<Gd<StyleBox>>().ok();
                    self.box_memo.insert(key, b.clone());
                    b
                }
            };
            v.box_sb = sb;
            v.boxed = true;
        }
        // overflow (UxmlStyleApplier._apply_overflow).
        let ov = str_of(P_OVERFLOW);
        let hidden_ov = ov == "hidden" || ov == "scroll";
        if !ov.is_empty() && !hidden_ov && ov != "visible" {
            return Err("overflow value".into());
        }
        let cbox = str_of(P_CLIPBOX);
        if !cbox.is_empty() && cbox != "padding-box" && cbox != "content-box" {
            return Err("clip box value".into());
        }
        v.clip = hidden_ov;
        if hidden_ov {
            let pxof = |x: &Option<Variant>| -> f32 {
                match x.as_ref().map(|y| layout::parse_length(&s(y))) {
                    Some(Len::Px(p)) => p.max(0.0) as f32,
                    _ => 0.0,
                }
            };
            let mut ins = [pxof(&vals[P_BW + 3]), pxof(&vals[P_BW]), pxof(&vals[P_BW + 1]), pxof(&vals[P_BW + 2])];
            if cbox == "content-box" {
                v.clip_content_box = true;
                ins[0] += pxof(&vals[P_PAD + 3]);
                ins[1] += pxof(&vals[P_PAD]);
                ins[2] += pxof(&vals[P_PAD + 1]);
                ins[3] += pxof(&vals[P_PAD + 2]);
            }
            v.clip_inset = ins;
            let mut rr = [0.0f64; 4];
            let mut round = false;
            for k in 0..4 {
                if let Some(Len::Px(p)) = vals[P_BR + k].as_ref().map(|y| layout::parse_length(&s(y))) {
                    if p > 0.0 {
                        rr[k] = p;
                        round = true;
                    }
                }
            }
            if round {
                v.clip_radii = Some(PackedFloat64Array::from(&rr[..]));
            }
        }
        // Text (a Label: UxmlStyleApplier._apply_themed_inner).
        if label {
            let to = str_of(P_TOVER);
            if !to.is_empty() && to != "clip" && !(to == "ellipsis" && !button) {
                return Err("text-overflow".into());
            }
            let pos = str_of(P_TOVERPOS);
            if !pos.is_empty() && !["start", "middle", "end"].contains(&pos.as_str()) {
                return Err("text overflow position".into());
            }
            v.color_set = vals[P_COLOR].is_some();
            let color = match vals[P_COLOR].clone() {
                Some(x) => self.color(&x)?,
                None if button => self.btheme.font_color,
                None => self.theme.font_color,
            };
            // Font and size (memoized by the values that choose them).
            let url = [P_FONT, P_FONTDEF].iter().any(|&k| str_of(k).starts_with("url("));
            let fkey = format!(
                "{}|{}|{}|{}|{}|{}|{}",
                self.kind[i],
                str_of(P_FONT), str_of(P_FONTDEF), str_of(P_FONTSTYLE), str_of(P_LSP), str_of(P_WSP), str_of(P_FONTSIZE)
            );
            let hit = if url { None } else { self.font_memo.get(&fkey).cloned() };
            let (font, size) = match hit {
                Some(h) => h,
                None => {
                    let r = self.helper.call("v2_font", &[(i as i64).to_variant(), button.to_variant()]);
                    let a = r.try_to::<VarArray>().map_err(|_| "font".to_string())?;
                    let f = a.get(0).and_then(|x| x.try_to::<Gd<Font>>().ok()).ok_or("font")?;
                    let z = a.get(1).and_then(|x| x.try_to::<i64>().ok()).unwrap_or(16) as i32;
                    if !url {
                        self.font_memo.insert(fkey, (f.clone(), z));
                    }
                    (f, z)
                }
            };
            // -unity-text-align, white-space (UxmlStyleApplier._apply_text_layout).
            let (mut ha, mut va) = (0, 0);
            let al = str_of(P_ALIGN);
            if !al.is_empty() {
                let hv = match al.as_str() {
                    "upper-left" => (0, 0),
                    "upper-center" => (1, 0),
                    "upper-right" => (2, 0),
                    "middle-left" => (0, 1),
                    "middle-center" => (1, 1),
                    "middle-right" => (2, 1),
                    "lower-left" => (0, 2),
                    "lower-center" => (1, 2),
                    "lower-right" => (2, 2),
                    _ => return Err("text align".into()),
                };
                ha = hv.0;
                va = hv.1;
            }
            let ws = str_of(P_WS);
            let trim = if ws == "pre-wrap" { 0 } else { DEFAULT_TRIM };
            let autowrap = match ws.as_str() {
                // A Button does not wrap (the applier sets autowrap on
                // Labels only).
                _ if button => AUTOWRAP_OFF,
                "normal" | "pre-wrap" => AUTOWRAP_WORD_SMART,
                "nowrap" | "pre" | "" => AUTOWRAP_OFF,
                _ => return Err("white-space".into()),
            };
            if button {
                v.bclip = hidden_ov;
            } else if to == "ellipsis" && hidden_ov && autowrap == AUTOWRAP_OFF {
                // UxmlStyleApplier._apply_elision: elided after the layout.
                v.elide = Some(GString::from(if pos.is_empty() { "end" } else { pos.as_str() }));
            }
            // -unity-text-outline (UxmlStyleApplier._apply_text_outline).
            let mut outline_size = if button { self.btheme.outline_size } else { self.theme.outline_size };
            let mut outline_color = if button { self.btheme.outline_color } else { self.theme.outline_color };
            if let Some(x) = vals[P_OUTW].clone() {
                let raw = s(&x);
                let mut w = layout::parse_number(&raw);
                if w.is_nan() {
                    w = match layout::parse_length(&raw) {
                        Len::Px(p) => p,
                        _ => return Err("outline width".into()),
                    };
                }
                if w > 0.0 {
                    outline_size = ((w * 2.0).round() as i32).max(1);
                    outline_color = match vals[P_OUTC].clone() {
                        Some(c) => self.color(&c)?,
                        None => Color::from_rgba(0.0, 0.0, 0.0, 0.0),
                    };
                }
            }
            v.text = Some(TextStyle {
                font,
                size,
                line_spacing: if button {
                    self.btheme.line_spacing
                } else if self.unity_metrics {
                    0
                } else {
                    self.theme.line_spacing
                },
                paragraph_spacing: self.theme.paragraph_spacing,
                autowrap,
                trim,
                halign: ha,
                valign: va,
                color,
                outline_size,
                outline_color,
                shadow_color: self.theme.shadow_color,
                shadow_ofs: self.theme.shadow_ofs,
                shadow_outline_size: self.theme.shadow_outline_size,
            });
        }
        if self.kind[i] == K_IMAGE {
            let r = self.helper.call("v2_image", &[(i as i64).to_variant()]);
            if let Ok(a) = r.try_to::<VarArray>() {
                if let (Some(Ok(t)), Some(Ok(m)), Some(Ok(c))) = (
                    a.get(0).map(|x| x.try_to::<Gd<Texture2D>>()),
                    a.get(1).map(|x| x.try_to::<i64>()),
                    a.get(2).map(|x| x.try_to::<Color>()),
                ) {
                    v.image = Some((t, m as i32, c));
                }
            }
            let nat = v.image.as_ref().map(|x| x.0.get_size()).unwrap_or(Vector2::ZERO);
            if self.leaves.natural[i] != nat {
                self.leaves_mut().natural[i] = nat;
                self.measure_dirty = true;
            }
        }
        // translate (UxmlStyleApplier._apply_transform: an offset of the
        // drawn box and of the hit test, never of the layout).
        if let Some(x) = vals[P_TRANSLATE].clone() {
            let r = self.helper.call("v2_translate", &[x]);
            let a = r.try_to::<VarArray>().map_err(|_| "translate".to_string())?;
            let px = a.get(0).and_then(|x| x.try_to::<Vector2>().ok()).ok_or("translate")?;
            let ratio = a.get(1).and_then(|x| x.try_to::<Vector2>().ok()).ok_or("translate")?;
            v.translate = Some((px, ratio));
        }
        // The box's horizontal border and padding, as the stylebox content
        // margins carry them before the layout resolves percentages.
        let hp = if v.boxed { widths[3] + pads[3] + widths[1] + pads[1] } else { (self.theme.normal_margins[0] + self.theme.normal_margins[2]) as f64 };
        if self.leaves.hpad[i] != hp {
            self.leaves_mut().hpad[i] = hp;
            self.measure_dirty = true;
        }
        if memo_ok {
            if self.vis_memo.len() > 4096 {
                self.vis_memo.clear();
            }
            self.vis_memo.insert(key, (keep, v.clone(), hp));
        }
        if Self::placement_differs(&self.vis[i], &v) {
            self.vis_changed = true;
        }
        self.vis[i] = v;
        self.dirty[i] = true;
        if label {
            self.make_text(i);
        }
        Ok(())
    }

    /// What the interaction Controls follow differs between two records.
    fn placement_differs(a: &Vis, b: &Vis) -> bool {
        a.gone != b.gone || a.hidden != b.hidden || a.opacity != b.opacity || a.clip != b.clip
            || a.clip_inset != b.clip_inset || a.translate != b.translate
    }

    fn leaves_mut(&mut self) -> &mut Leaves {
        Rc::get_mut(&mut self.leaves).expect("leaves are not shared outside a layout")
    }

    /// The text block of Label i (shaped again only when its text, font,
    /// size, wrap or spacing changed).
    fn make_text(&mut self, i: usize) {
        let Some(ts) = self.vis[i].text.clone() else { return };
        let text = self.texts_src[i].clone();
        if self.kind[i] == K_BUTTON {
            let mut t = self.leaves.btexts.borrow_mut();
            if let Some(b) = t[i].as_mut() {
                if b.same_shape(&text, &ts) {
                    b.st = ts;
                    return;
                }
            }
            t[i] = Some(ButtonText::new(text, ts, self.locale.clone()));
            drop(t);
            self.measure_dirty = true;
            return;
        }
        let mut t = self.leaves.texts.borrow_mut();
        if let Some(b) = t[i].as_mut() {
            if b.same_shape(&text, &ts) {
                b.st = ts;
                return;
            }
        }
        t[i] = Some(TextBlock::new(text, ts));
        drop(t);
        self.measure_dirty = true;
    }

    /// Whether a layout record changed since the last layout.
    fn records_changed(&mut self) -> bool {
        let cb = self.casc.bind();
        let c: &Cascade = cb.inner.as_ref().unwrap();
        if self.recs.recs.len() != c.len() {
            return true;
        }
        (0..c.len()).any(|i| c.layout_version(i) != self.recs.vers[i])
    }

    fn layout(&mut self, host: Vector2) -> bool {
        let _p = crate::prof::scope("v2.layout");
        self.host_size = host;
        self.measure_dirty = false;
        let leaves = self.leaves.clone();
        let src: Rc<dyn LeafSource> = leaves;
        let n = self.n;
        let io = layout::LayoutIn {
            v2: Some(src),
            controls: vec![None; n],
            boxed: vec![false; n],
            labels: vec![None; n],
            rich: vec![None; n],
            buttons: vec![false; n],
            text_clip: false,
            pixel_grid: true,
            ppp: 1.0,
            auto_size: None,
            fields: vec![false; n],
            texrects: vec![None; n],
            maxc: RefCell::new(vec![None; n]),
            maxc_on: std::cell::Cell::new(false),
            unfit: RefCell::new(vec![None; n]),
            margins: RefCell::new(vec![None; n]),
            cliptext: RefCell::new(vec![None; n]),
            touched: RefCell::new(vec![false; n]),
            ext: vec![false; n],
        };
        let cb = self.casc.bind();
        let c: &Cascade = cb.inner.as_ref().unwrap();
        self.recs.refresh(c);
        let out = layout::Pass::new(c, &io, &self.recs.recs, 0.0, self.warned.clone(), self.warnings.clone()).run(host);
        let changed = out.rects != self.rects;
        self.rects = out.rects;
        for (k, r) in self.rects.iter().enumerate() {
            if let Some(r) = r {
                self.last_size[k] = r.size;
            }
        }
        self.insets = out.insets;
        drop(io);
        changed
    }

    fn host_rect(&self, i: usize) -> Rect2 {
        let Some(r) = self.rects.get(i).copied().flatten() else { return Rect2::new(Vector2::ZERO, Vector2::ZERO) };
        let cb = self.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        let mut pos = r.position + self.tr_of(i);
        let mut p = c.parent_of(i);
        while p > 0 {
            if let Some(pr) = self.rects[p as usize] {
                pos += pr.position + self.tr_of(p as usize);
            }
            p = c.parent_of(p as usize);
        }
        Rect2::new(pos, r.size)
    }

    /// The offset of element i's `translate` (px plus the ratio of its
    /// own size).
    fn tr_of(&self, i: usize) -> Vector2 {
        match (&self.vis[i].translate, self.rects[i]) {
            (Some((px, ratio)), Some(r)) => *px + *ratio * r.size,
            _ => Vector2::ZERO,
        }
    }

    fn shown(&self, i: usize) -> bool {
        if i >= self.n || self.kind[i] == K_NONE || self.rects[i].is_none() {
            return false;
        }
        let cb = self.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        let mut k = i as i32;
        while k >= 0 {
            let v = &self.vis[k as usize];
            if v.gone || v.hidden {
                return false;
            }
            k = c.parent_of(k as usize);
        }
        true
    }

    fn pick(&self, point: Vector2, respect_picking: bool) -> i64 {
        // The last element in preorder whose border box contains the point
        // and that is shown, inside the clips of its ancestors.
        let cb = self.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        let mut best = -1i64;
        let mut origin = vec![Vector2::ZERO; self.n];
        let mut ok = vec![false; self.n];
        for i in 0..self.n {
            if self.kind[i] == K_NONE {
                continue;
            }
            let Some(r) = self.rects[i] else { continue };
            let p = c.parent_of(i);
            let (po, pok) = if p >= 0 { (origin[p as usize], ok[p as usize]) } else { (Vector2::ZERO, true) };
            let v = &self.vis[i];
            let pos = if i == 0 { Vector2::ZERO } else { po + r.position + self.tr_of(i) };
            origin[i] = pos;
            ok[i] = pok && !v.gone && !v.hidden;
            if !ok[i] {
                continue;
            }
            // An ancestor that clips: outside its clip rect (its border box,
            // or the inset of its UxmlClip) nothing below picks.
            let mut a = p;
            let mut inside = true;
            while a >= 0 {
                let av = &self.vis[a as usize];
                if av.clip {
                    if let Some(ar) = self.rects[a as usize] {
                        let ao = origin[a as usize];
                        let ins = self.clip_inset_of(a as usize);
                        let cr = Rect2::new(
                            ao + Vector2::new(ins[0], ins[1]),
                            Vector2::new(ar.size.x - ins[0] - ins[2], ar.size.y - ins[1] - ins[3]),
                        );
                        if !Rect2::new(ao, ar.size).contains_point(point) || !cr.contains_point(point) {
                            inside = false;
                            break;
                        }
                    }
                }
                a = c.parent_of(a as usize);
            }
            if !inside {
                continue;
            }
            if respect_picking && v.picking_ignore {
                continue;
            }
            if Rect2::new(pos, r.size).contains_point(point) {
                best = i as i64;
            }
        }
        best
    }

    /// The inset (left, top, right, bottom) of element i's clip of its
    /// children (UxmlClip): zero without one.
    fn clip_inset_of(&self, i: usize) -> [f32; 4] {
        let v = &self.vis[i];
        if !(v.clip && (v.clip_inset != [0.0; 4] || v.clip_radii.is_some())) {
            return [0.0; 4];
        }
        if v.clip_content_box {
            if let Some((s0, e0)) = self.insets[i] {
                return [s0.x, s0.y, e0.x, e0.y];
            }
        }
        v.clip_inset
    }

    fn free_items(&mut self) {
        let mut r = rs();
        for &it in self.clips.iter() {
            if it.is_valid() {
                r.free_rid(it);
            }
        }
        for &it in self.items.iter() {
            if it.is_valid() {
                r.free_rid(it);
            }
        }
        self.items.clear();
        self.clips.clear();
    }

    /// Records every canvas item (made on the first draw).
    fn draw_all(&mut self) {
        let _p = crate::prof::scope("v2.draw");
        let mut r = rs();
        let n = self.n;
        let host_ci = self.host.get_canvas_item();
        if self.items.len() != n {
            self.free_items();
            self.dirty.fill(true);
            self.items = vec![Rid::Invalid; n];
            self.clips = vec![Rid::Invalid; n];
            let cb = self.casc.bind();
            let c = cb.inner.as_ref().unwrap();
            let mut sib = vec![0i32; n];
            for i in 0..n {
                if self.kind[i] == K_NONE {
                    continue;
                }
                let it = r.canvas_item_create();
                self.items[i] = it;
                let p = c.parent_of(i);
                let parent_ci = if p >= 0 && self.items[p as usize].is_valid() { self.items[p as usize] } else { host_ci };
                r.canvas_item_set_parent(it, parent_ci);
                if p >= 0 {
                    r.canvas_item_set_draw_index(it, sib[p as usize]);
                    sib[p as usize] += 1;
                }
            }
        }
        for i in 0..n {
            let at = self.rects[i].map(|r| (r, self.insets[i]));
            if self.dirty[i] || self.drawn[i] != at {
                self.draw_one(i);
                self.dirty[i] = false;
                self.drawn[i] = at;
            }
        }
    }

    fn draw_one(&mut self, i: usize) {
        if self.kind[i] == K_NONE {
            return;
        }
        let mut r = rs();
        let it = self.items[i];
        r.canvas_item_clear(it);
        let v = self.vis[i].clone();
        let rect = self.rects[i];
        let Some(rect) = rect else {
            r.canvas_item_set_visible(it, false);
            return;
        };
        r.canvas_item_set_visible(it, !(v.gone || v.hidden));
        if v.translate.is_some() && i > 0 {
            // UxmlStyleApplier._apply_transform: the Control's rotation of
            // 1e-5 rad (no pixel snap) times the offset transform.
            const NO_SNAP: f32 = 1e-5;
            let rot = Transform2D::from_angle_origin(NO_SNAP, Vector2::ZERO);
            let tr = self.tr_of(i);
            let o = rot.basis_xform(tr) + rect.position;
            r.canvas_item_set_transform(it, Transform2D::from_angle_origin(NO_SNAP, o));
        } else {
            let pos = if i == 0 { Vector2::ZERO } else { rect.position };
            r.canvas_item_set_transform(it, Transform2D::from_angle_origin(0.0, pos));
        }
        r.canvas_item_set_modulate(it, Color::from_rgba(1.0, 1.0, 1.0, v.opacity));
        // A Button is fitted into its box and never smaller than its
        // minimum size (UxmlStyleApplier.fit_button, Godot's floor).
        let mut bfit: Option<[f32; 4]> = None;
        let mut size = rect.size;
        if self.kind[i] == K_BUTTON {
            let (s0, e0) = self.insets[i].unwrap_or((Vector2::ZERO, Vector2::ZERO));
            if let Some(b) = self.leaves.btexts.borrow().get(i).and_then(|b| b.as_ref()) {
                let (m, sz) = b.fit(size, [s0.x, s0.y, e0.x, e0.y], v.bclip);
                bfit = Some(m);
                size = sz;
            }
        }
        r.canvas_item_set_custom_rect_ex(it, true).rect(Rect2::new(Vector2::ZERO, size)).done();
        r.canvas_item_set_clip(it, v.clip);
        // The clip of the children (UxmlClip).
        let want_clip = v.clip && (v.clip_inset != [0.0; 4] || v.clip_radii.is_some());
        if want_clip {
            let ci = if self.clips[i].is_valid() {
                self.clips[i]
            } else {
                let ci = r.canvas_item_create();
                r.canvas_item_set_parent(ci, it);
                r.canvas_item_set_clip(ci, true);
                self.clips[i] = ci;
                ci
            };
            let ins = self.clip_inset_of(i);
            let cr = Rect2::new(
                Vector2::new(ins[0], ins[1]),
                Vector2::new((size.x - ins[0] - ins[2]).max(0.0), (size.y - ins[1] - ins[3]).max(0.0)),
            );
            r.canvas_item_set_custom_rect_ex(ci, true).rect(cr).done();
            r.canvas_item_clear(ci);
            match &v.clip_radii {
                Some(rr) => {
                    let a = self
                        .helper
                        .call("v2_mask", &[rr.to_variant(), PackedFloat64Array::from(&[ins[1] as f64, ins[2] as f64, ins[3] as f64, ins[0] as f64][..]).to_variant()])
                        .try_to::<VarArray>()
                        .unwrap_or_default();
                    let mask = a.get(0).and_then(|x| x.try_to::<Gd<StyleBox>>().ok());
                    let mat = a.get(1).and_then(|x| x.try_to::<Gd<Material>>().ok());
                    r.canvas_item_set_canvas_group_mode(ci, godot::classes::rendering_server::CanvasGroupMode::CLIP_ONLY);
                    if let Some(m) = &mat {
                        r.canvas_item_set_material(ci, m.get_rid());
                    }
                    if let Some(m) = mask {
                        m.draw(ci, Rect2::new(Vector2::ZERO, size));
                    }
                }
                None => {
                    r.canvas_item_set_canvas_group_mode(ci, godot::classes::rendering_server::CanvasGroupMode::DISABLED);
                    r.canvas_item_set_material(ci, Rid::Invalid);
                    // Disabling the canvas group turns the item's clip off.
                    r.canvas_item_set_clip(ci, true);
                }
            }
            self.reparent_children(i, ci);
        } else if self.clips[i].is_valid() {
            self.reparent_children(i, it);
            r.free_rid(self.clips[i]);
            self.clips[i] = Rid::Invalid;
        }
        if v.gone {
            return;
        }
        if self.kind[i] == K_EDIT {
            // The editor Control draws it.
            return;
        }
        let full = Rect2::new(Vector2::ZERO, size);
        if let Some(sb) = &v.box_sb {
            sb.draw(it, full);
            if self.kind[i] == K_BUTTON && self.focused[i] {
                // Button draws its focus stylebox (the same box) over it.
                sb.draw(it, full);
            }
        }
        if let Some(sb) = &v.img_sb {
            sb.draw(it, full);
        } else if let Some(t) = &v.img_tex {
            t.draw_rect(it, full, false);
        }
        if let Some((tex, mode, tint)) = &v.image {
            // The TextureRect of an Image, in the content box.
            let (s0, e0) = self.insets[i].unwrap_or((Vector2::ZERO, Vector2::ZERO));
            let area = Rect2::new(s0, Vector2::new((size.x - s0.x - e0.x).max(0.0), (size.y - s0.y - e0.y).max(0.0)));
            draw_texture_rect(it, tex, *mode, area, *tint);
        }
        if self.kind[i] == K_BUTTON && !self.text_hidden {
            if let (Some(m), Some(b)) = (bfit, self.leaves.btexts.borrow_mut().get_mut(i).and_then(|b| b.as_mut())) {
                // Button's colour of its draw mode (DRAW_DISABLED, the focus
                // colour over DRAW_NORMAL); a USS colour is on every slot.
                if !v.color_set {
                    b.st.color = if self.disabled[i] {
                        self.btheme.font_disabled_color
                    } else if self.focused[i] {
                        self.btheme.font_focus_color
                    } else {
                        self.btheme.font_color
                    };
                }
                b.draw(it, size, m);
            }
        }
        if self.kind[i] == K_LABEL && !self.text_hidden {
            let m = if v.boxed {
                let (s0, e0) = self.insets[i].unwrap_or((Vector2::ZERO, Vector2::ZERO));
                [s0.x, s0.y, e0.x, e0.y]
            } else {
                self.theme.normal_margins
            };
            let mut t = self.leaves.texts.borrow_mut();
            // An elided Label draws its elided text (UxmlStyleApplier.
            // update_elision, at the width of its content box).
            let mut shown: Option<TextBlock> = None;
            self.elided[i] = false;
            if let (Some(pos), Some(b)) = (&v.elide, t[i].as_ref()) {
                let width = size.x - (m[0] + m[2]);
                let full = b.text.clone();
                let key = (full.clone(), width, pos.clone(), b.st.size);
                let el = match &self.elide_memo[i] {
                    Some((k, e)) if *k == key => e.clone(),
                    _ => {
                        let e = self
                            .helper
                            .call("v2_elide", &[full.to_variant(), width.to_variant(), pos.to_variant(), b.st.font.to_variant(), b.st.size.to_variant()])
                            .try_to::<GString>()
                            .unwrap_or(full.clone());
                        self.elide_memo[i] = Some((key, e.clone()));
                        e
                    }
                };
                if el != full {
                    shown = Some(TextBlock::new(el, b.st.clone()));
                    self.elided[i] = true;
                }
            }
            let block = match shown.as_mut() {
                Some(x) => Some(x),
                None => t[i].as_mut(),
            };
            if let Some(b) = block {
                // A Label is never smaller than its minimum height (Godot);
                // a narrower box keeps its width (the runtime's fit).
                let content_w = ((size.x - (m[0] + m[2])) as i32).max(if b.st.autowrap != AUTOWRAP_OFF { 1 } else { 0 });
                let min = b.min_size(content_w);
                let h = size.y.max(min.y + m[1] + m[3]);
                b.draw(it, Vector2::ZERO, Vector2::new(size.x, h), m);
            }
        }
    }

    fn reparent_children(&self, i: usize, to: Rid) {
        let mut r = rs();
        let cb = self.casc.bind();
        let c = cb.inner.as_ref().unwrap();
        for ch in c.children(i) {
            if ch < self.items.len() && self.items[ch].is_valid() {
                r.canvas_item_set_parent(self.items[ch], to);
            }
        }
    }
}

/// TextureRect's draw (EXPAND_IGNORE_SIZE) of `tex` in `area` with
/// `mode` (TextureRect.StretchMode) and the tint as the modulate.
fn draw_texture_rect(ci: Rid, tex: &Gd<Texture2D>, mode: i32, area: Rect2, tint: Color) {
    let size = area.size;
    let ts = tex.get_size();
    if ts.x <= 0.0 || ts.y <= 0.0 || size.x <= 0.0 || size.y <= 0.0 {
        return;
    }
    let mut offset = area.position;
    let mut dsize = size;
    let mut region: Option<Rect2> = None;
    match mode {
        // STRETCH_SCALE
        0 => {}
        // STRETCH_TILE
        1 => {
            tex.draw_rect_ex(ci, Rect2::new(offset, dsize), true).modulate(tint).done();
            return;
        }
        // STRETCH_KEEP
        2 => dsize = ts,
        // STRETCH_KEEP_CENTERED
        3 => {
            offset += ((size - ts) / 2.0).floor();
            dsize = ts;
        }
        // STRETCH_KEEP_ASPECT, STRETCH_KEEP_ASPECT_CENTERED
        4 | 5 => {
            let mut tw = (tex.get_width() as f32 * size.y / tex.get_height() as f32) as i32;
            let mut th = size.y as i32;
            if tw as f32 > size.x {
                tw = size.x as i32;
                th = (tex.get_height() as f32 * tw as f32 / tex.get_width() as f32) as i32;
            }
            if mode == 5 {
                offset.x += (size.x - tw as f32) / 2.0;
                offset.y += (size.y - th as f32) / 2.0;
            }
            dsize = Vector2::new(tw as f32, th as f32);
        }
        // STRETCH_KEEP_ASPECT_COVERED
        6 => {
            let sc = Vector2::new(size.x / ts.x, size.y / ts.y);
            let scale = if sc.x > sc.y { sc.x } else { sc.y };
            let scaled = ts * scale;
            let p = ((scaled - size) / scale).abs() / 2.0;
            region = Some(Rect2::new(p, size / scale));
        }
        _ => {}
    }
    match region {
        Some(rg) if rg.size.x > 0.0 && rg.size.y > 0.0 => {
            tex.draw_rect_region_ex(ci, Rect2::new(offset, dsize), rg).modulate(tint).done();
        }
        _ => {
            tex.draw_rect_ex(ci, Rect2::new(offset, dsize), false).modulate(tint).done();
        }
    }
}
