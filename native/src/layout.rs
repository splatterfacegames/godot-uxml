//! Native flex layout — a line-by-line port of runtime/flex_layout.gd
//! (without its cross-pass cache, which only existed to hide GDScript
//! cost). Reads layout properties straight from the native cascade's
//! per-element values and measures leaves through engine calls, exactly as
//! UxmlDocument._measure_leaf does. Arithmetic mirrors GDScript: scalars in
//! f64, `Vector2`/`Rect2` components stored as f32 at the same points, and
//! Godot's CLAMP/MAX semantics — so rects are bit-identical
//! (bench/equiv_layout.gd, bench/equiv_runtime.gd).

use std::collections::HashMap;
use std::rc::Rc;

use godot::classes::{Control, Font, Label, Object, RichTextLabel, StyleBox};
use godot::prelude::*;

use crate::cascade::Cascade;

const EPS: f64 = 0.01;
/// flex_layout.gd NO_BOUND: no bound changes this axis of a measure.
const NO_BOUND: f64 = -1.0e30;
pub const LAYOUT_PROPS: [&str; 37] = [
    "width", "height", "min-width", "min-height", "max-width", "max-height", "flex-basis",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "row-gap", "column-gap", "flex-grow", "flex-shrink",
    "top", "right", "bottom", "left", "aspect-ratio",
    "display", "flex-direction", "flex-wrap", "justify-content", "align-items", "align-content", "align-self",
    "position", "overflow",
];
const P_W: usize = 0;
const P_H: usize = 1;
const P_MINW: usize = 2;
const P_MINH: usize = 3;
const P_MAXW: usize = 4;
const P_MAXH: usize = 5;
const P_BASIS: usize = 6;
const P_PAD: usize = 7;
const P_MAR: usize = 11;
const P_BOR: usize = 15;
const P_RGAP: usize = 19;
const P_CGAP: usize = 20;
const P_GROW: usize = 21;
const P_SHRINK: usize = 22;
const P_POS: usize = 23; // 23..26 top,right,bottom,left
const P_ASPECT: usize = 27;
const NP: usize = 28;
const E_DISPLAY: usize = 28;
const E_DIR: usize = 29;
const E_WRAP: usize = 30;
const E_JUSTIFY: usize = 31;
const E_ALIGN_ITEMS: usize = 32;
const E_ALIGN_CONTENT: usize = 33;
const E_ALIGN_SELF: usize = 34;
const E_POSITION: usize = 35;
const E_OVERFLOW: usize = 36;
const NE: usize = 9;
const T: usize = 0;
const R: usize = 1;
const B: usize = 2;
const L: usize = 3;

const JUSTIFY: [&str; 6] = ["flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly"];
const ALIGN: [&str; 5] = ["flex-start", "center", "flex-end", "stretch", "baseline"];
const ALIGN_CONTENT: [&str; 7] = ["flex-start", "center", "flex-end", "stretch", "space-between", "space-around", "space-evenly"];
const DIRECTIONS: [&str; 4] = ["column", "row", "column-reverse", "row-reverse"];
const WRAPS: [&str; 3] = ["nowrap", "wrap", "wrap-reverse"];
const POSITIONS: [&str; 2] = ["relative", "absolute"];
const UNSUPPORTED_UNITS: [&str; 14] = ["em", "rem", "vh", "vw", "vmin", "vmax", "pt", "cm", "in", "ch", "ex", "pc", "mm", "q"];

// Godot's macros.
#[inline]
fn gmax(a: f64, b: f64) -> f64 {
    if a > b { a } else { b }
}
#[inline]
fn gclamp(v: f64, lo: f64, hi: f64) -> f64 {
    if v < lo { lo } else if v > hi { hi } else { v }
}
#[inline]
fn f(x: f64) -> f32 {
    x as f32
}
#[inline]
fn d(x: f32) -> f64 {
    x as f64
}

/// Godot String::strip_edges: drops chars <= 32 at both ends.
fn strip(s: &str) -> &str {
    s.trim_matches(|c: char| (c as u32) <= 32)
}

/// Matches ^-?(\d+\.?\d*|\.\d+)<rest>; returns (number end, ok).
fn scan_number(s: &[u8]) -> Option<usize> {
    let mut i = 0;
    if i < s.len() && s[i] == b'-' {
        i += 1;
    }
    let ds = i;
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
    }
    if i > ds {
        if i < s.len() && s[i] == b'.' {
            i += 1;
            while i < s.len() && s[i].is_ascii_digit() {
                i += 1;
            }
        }
        Some(i)
    } else if i < s.len() && s[i] == b'.' {
        i += 1;
        let fs = i;
        while i < s.len() && s[i].is_ascii_digit() {
            i += 1;
        }
        if i > fs { Some(i) } else { None }
    } else {
        None
    }
}

enum Len {
    Px(f64),
    Pct(f64),
    Auto,
    Bad(String),
}

/// UssValues.parse_length.
fn parse_length(text: &str) -> Len {
    let v = strip(text);
    if v.is_empty() {
        return Len::Bad("empty value".into());
    }
    if v == "auto" || v == "initial" || v == "none" {
        return Len::Auto;
    }
    if v.starts_with("calc(") {
        return Len::Bad("calc() is not supported in USS".into());
    }
    let b = v.as_bytes();
    let bad = || Len::Bad(format!("cannot read \"{v}\" as a length"));
    let Some(ne) = scan_number(b) else { return bad() };
    if !b[ne..].iter().all(|c| c.is_ascii_alphabetic() || *c == b'%') {
        return bad();
    }
    let number: f64 = v[..ne].parse().unwrap_or(0.0);
    let unit = v[ne..].to_ascii_lowercase();
    if unit.is_empty() || unit == "px" {
        return Len::Px(number);
    }
    if unit == "%" {
        return Len::Pct(number);
    }
    if UNSUPPORTED_UNITS.contains(&unit.as_str()) {
        return Len::Bad(format!("\"{unit}\" is not a USS unit"));
    }
    Len::Bad(format!("unknown unit \"{unit}\""))
}

/// UssValues.parse_number (NAN when not a number).
/// flex_layout.gd _parse_ratio.
fn parse_ratio(text: &str) -> f64 {
    let t = strip(text);
    if t == "auto" {
        return 0.0;
    }
    let parts: Vec<&str> = t.split('/').collect();
    if parts.len() > 2 {
        return f64::NAN;
    }
    let a = parse_number(strip(parts[0]));
    if a.is_nan() || a < 0.0 {
        return f64::NAN;
    }
    if parts.len() == 1 {
        return a;
    }
    let b = parse_number(strip(parts[1]));
    if b.is_nan() || b <= 0.0 {
        return f64::NAN;
    }
    a / b
}

fn parse_number(text: &str) -> f64 {
    let v = strip(text);
    match scan_number(v.as_bytes()) {
        Some(ne) if ne == v.len() => v.parse().unwrap_or(f64::NAN),
        _ => f64::NAN,
    }
}

#[derive(Clone, Copy, PartialEq)]
enum K {
    None,
    Px,
    Pct,
    Auto,
    Bad,
    AutoKw,
    Num,
    Nan,
}

/// Parsed layout record of one element (flex_layout.gd _build_rec).
pub struct Rec {
    kinds: [K; NP],
    vals: [f64; NP],
    raws: Vec<String>,
    probs: HashMap<usize, String>,
    enums: [Option<String>; NE],
}

fn build_rec(vals_in: &[Option<GString>]) -> Rec {
    let mut r = Rec {
        kinds: [K::None; NP],
        vals: [0.0; NP],
        raws: vec![String::new(); NP],
        probs: HashMap::new(),
        enums: Default::default(),
    };
    for pid in 0..NP {
        let Some(raw) = &vals_in[pid] else { continue };
        let raw = raw.to_string();
        if pid == P_ASPECT {
            let ar = parse_ratio(&raw);
            if ar.is_nan() {
                r.kinds[pid] = K::Nan;
            } else if ar <= 0.0 {
                r.kinds[pid] = K::Auto;
            } else {
                r.kinds[pid] = K::Num;
                r.vals[pid] = ar;
            }
        } else if pid == P_GROW || pid == P_SHRINK {
            let n = parse_number(&raw);
            if n.is_nan() {
                r.kinds[pid] = K::Nan;
            } else {
                r.kinds[pid] = K::Num;
                r.vals[pid] = n;
            }
        } else if (P_PAD..P_BOR).contains(&pid) && strip(&raw) == "auto" {
            r.kinds[pid] = K::AutoKw;
        } else {
            match parse_length(&raw) {
                Len::Px(v) => {
                    r.kinds[pid] = K::Px;
                    r.vals[pid] = v;
                }
                Len::Pct(v) => {
                    r.kinds[pid] = K::Pct;
                    r.vals[pid] = v;
                }
                Len::Bad(p) => {
                    r.kinds[pid] = K::Bad;
                    r.probs.insert(pid, p);
                }
                Len::Auto => r.kinds[pid] = K::Auto,
            }
        }
        r.raws[pid] = raw;
    }
    for e in 0..NE {
        r.enums[e] = vals_in[NP + e].as_ref().map(|g| g.to_string());
    }
    r
}

type Edges = [f64; 4];

#[derive(Clone, Copy)]
enum CtlKind {
    None,
    Plain,
    Boxed,
}

pub struct LayoutIn {
    pub controls: Vec<Option<Gd<Control>>>,
    pub boxed: Vec<bool>,
    pub labels: Vec<Option<Gd<Label>>>,
    /// Rich text Labels (RichTextLabel): wrap-volatile like Labels.
    pub rich: Vec<Option<Gd<RichTextLabel>>>,
    /// Buttons (Button and its subclasses): fitted to their box by the
    /// placement (UxmlStyleApplier.fit_button) and, with children, not
    /// measured.
    pub buttons: Vec<bool>,
    /// Some control carries `uxml_clip_text` (overflow: hidden text); while
    /// false the measurer skips the meta check (UxmlStyleApplier.clip_texts).
    pub text_clip: bool,
    /// Round the output to the pixel grid (UxmlDocument.pixel_grid; Unity's
    /// RoundToPixelGrid). Same rule as UxmlFlexLayout.round_to_pixel_grid.
    pub pixel_grid: bool,
    /// UxmlField wrappers (insets via set_content_insets).
    pub fields: Vec<bool>,
    /// TextureRect natives (Image elements: anchor offsets follow insets).
    pub texrects: Vec<Option<Gd<Control>>>,
    /// The style applier while some Label/Button has an active
    /// -unity-text-auto-size (UxmlStyleApplier.auto_sizes > 0): its
    /// autosize_measure / autosize_place serve both layout paths.
    pub auto_size: Option<Gd<Object>>,
    /// Max-content widths of wrapping Labels by text (label_max_content),
    /// kept across layouts; layout_place drops the entries of re-applied
    /// controls and of controls whose insets changed. Used only while
    /// `maxc_on` (the placing layout).
    pub maxc: std::cell::RefCell<Vec<Option<(GString, f64)>>>,
    pub maxc_on: std::cell::Cell<bool>,
    /// The unfitted height of a fitted Label (-1: not fitted) across
    /// layouts, as the measure reads it from `uxml_fit` and `uxml_unfit`.
    /// Dropped like `maxc`, and when the placement fits the Label or sets a
    /// best-fit font size. Used only while `maxc_on`.
    pub unfit: std::cell::RefCell<Vec<Option<f64>>>,
    /// The `uxml_margins` of each control's normal stylebox override
    /// (None inside: no override or no meta) across layouts. Only the
    /// style applier writes them (apply(), apply_resolved_insets), so an
    /// entry is dropped when its control is re-applied (`force`) or its
    /// inset hook runs. Used only while `maxc_on`.
    pub margins: std::cell::RefCell<Vec<Option<Option<[f64; 4]>>>>,
    /// Whether each control carries `uxml_clip_text`, across layouts. Only
    /// the style applier's apply() sets or removes the meta, so an entry is
    /// dropped when its control is re-applied (`force`, and place_only).
    /// Used only while `maxc_on`: a meta check per text control and pass
    /// cost as much as the rest of its measure.
    pub cliptext: std::cell::RefCell<Vec<Option<bool>>>,
    /// Elements whose control the placement changed in a way a measure
    /// can read (a fit, an inset hook, a best-fit font): the next pass of
    /// the cross-pass cache treats them as changed (see XCache).
    pub touched: std::cell::RefCell<Vec<bool>>,
    /// Elements whose control something outside the layout moves (the rows
    /// of a collection view, CollectionBehavior._place): their placement
    /// checks the control's position and size again.
    pub ext: Vec<bool>,
}

impl LayoutIn {
    /// The `uxml_margins` of control `c` (element i): through the
    /// cross-layout cache while `maxc_on`.
    fn margins_of(&self, i: usize, c: &Gd<Control>, sn_normal: &StringName, sn_margins: &StringName) -> Option<[f64; 4]> {
        let on = self.maxc_on.get();
        if on {
            if let Some(Some(m)) = self.margins.borrow().get(i) {
                return *m;
            }
        }
        let m = read_margins(c, sn_normal, sn_margins);
        if on {
            if let Some(e) = self.margins.borrow_mut().get_mut(i) {
                *e = Some(m);
            }
        }
        m
    }
}

/// Native placement state: the last layout and the insets last handed to
/// each control's inset hooks.
#[derive(Default)]
pub struct Placement {
    pub last: Option<Out>,
    hooked: Vec<Option<(Vector2, Vector2)>>,
    sn_fit: Option<StringName>,
    /// The height each Label was last fitted for (NaN: not fitted).
    fit_h: Vec<f32>,
    /// UxmlStyleApplier.fit_seen: the box height of the last fit_label
    /// call and the control height after it; a forced (re-applied)
    /// placement drops it.
    fit_seen: Vec<Option<(f32, f32)>>,
    /// Buttons fitted by UxmlStyleApplier.fit_button at their last
    /// placement.
    bfit: Vec<bool>,
    /// What each fitted Button was last fitted for: its rect size, insets
    /// and its minimum size after the fit. A fitted Button is placed again
    /// by every layout; with the same inputs, the same minimum size (its
    /// text) and its size at the rect, fit_button would write nothing, so
    /// it is not called. A forced (re-applied) placement drops it.
    bfit_at: Vec<Option<(Vector2, Vector2, Vector2, Vector2)>>,
    /// The rect each control was last placed at.
    placed_at: Vec<Option<Rect2>>,
    /// Per element: placed by the last placing pass (not skipped as clean
    /// by place_clean).
    pub replaced: Vec<bool>,
}

impl Placement {
    /// UxmlDocument._place_control for element i. Inset hooks (UxmlField.
    /// set_content_insets / applier.apply_resolved_insets) are idempotent
    /// for unchanged insets on unchanged styleboxes, so they only run when
    /// the insets changed or the element was just re-applied (`force`).
    /// place() of a placing pass: `clean` when the element did not change
    /// since the last placing pass (XCache::validate). A clean control at
    /// the rect and insets it was last placed at, outside a fit, would get
    /// no write: it is skipped.
    pub fn place_clean(&mut self, io: &LayoutIn, i: usize, applier: &Option<Gd<Object>>, force: bool, clean: bool) {
        let n = io.controls.len();
        if self.replaced.len() != n {
            self.replaced = vec![true; n];
        }
        self.replaced[i] = true;
        if clean && !force && i != 0 {
            if let (Some(out), Some(c)) = (&self.last, &io.controls[i]) {
                let n = io.controls.len();
                if out.rects[i].is_none() {
                    // Not laid out (display: none): place() does nothing.
                    self.replaced[i] = false;
                    return;
                }
                if let Some(r) = out.rects[i] {
                    if self.placed_at.len() == n
                        && self.placed_at[i] == Some(r)
                        && self.hooked.len() == n
                        && out.insets[i].is_some()
                        && self.hooked[i] == out.insets[i]
                        && io.auto_size.is_none()
                        && (io.ext.is_empty() || !io.ext[i] || c.get_position() == r.position)
                        && ((io.labels[i].is_none() && io.rich[i].is_none() && !io.ext.get(i).copied().unwrap_or(true)) || c.get_size() == r.size)
                    {
                        self.replaced[i] = false;
                        return;
                    }
                }
            }
        }
        self.place(io, i, applier, force);
    }

    fn touch(io: &LayoutIn, i: usize) {
        if let Some(t) = io.touched.borrow_mut().get_mut(i) {
            *t = true;
        }
    }

    pub fn place(&mut self, io: &LayoutIn, i: usize, applier: &Option<Gd<Object>>, force: bool) {
        let _p = crate::prof::scope("place1");
        if self.placed_at.len() != io.controls.len() {
            self.placed_at = vec![None; io.controls.len()];
        }
        if let Some(out) = &self.last {
            self.placed_at[i] = out.rects.get(i).copied().flatten();
        }
        if force {
            // Re-applied: new styleboxes, font and size.
            if let Some(e) = io.margins.borrow_mut().get_mut(i) {
                *e = None;
            }
        }
        if i == 0 {
            return; // document root: the host box, never positioned
        }
        let Some(out) = &self.last else { return };
        let Some(mut c) = io.controls[i].clone() else { return };
        let Some(r) = out.rects[i] else { return };
        if let Some(a) = &io.auto_size {
            if c.has_meta("uxml_autosize") {
                // UxmlDocument._place_control: fit the font to the content
                // box before the size lands.
                let cs = match out.insets[i] {
                    Some((start, end)) => r.size - start - end,
                    None => r.size,
                };
                let mut a = a.clone();
                a.call("autosize_place", &[c.to_variant(), cs.to_variant()]);
                Self::touch(io, i);
                io.unfit.borrow_mut()[i] = None;
            }
        }
        // A control already at its rect is not moved: setting the same
        // position or size changes nothing, but costs about 1.3 us each
        // (offset recomputation), and most controls keep their rect when a
        // layout runs again.
        if c.get_position() != r.position {
            c.set_position(r.position);
        }
        if c.get_size() != r.size {
            c.set_size(r.size);
        }
        if let (Some(lbl), Some(a)) = (&io.labels[i], applier) {
            // UxmlDocument._place_control: a Label narrower than its text
            // (UxmlStyleApplier.fit_label_width) gets clip_text and the
            // `uxml_clip_text` meta the measure reads.
            if d(c.get_size().x) > d(r.size.x) + 0.01 {
                let mut a = a.clone();
                a.call("fit_label_width", &[c.to_variant()]);
                Self::touch(io, i);
                if let Some(e) = io.cliptext.borrow_mut().get_mut(i) {
                    *e = None;
                }
                if lbl.has_meta("uxml_wfit") {
                    c.set_size(r.size);
                }
            }
        }
        if let (Some(lbl), Some(a)) = (&io.labels[i], applier) {
            // UxmlDocument._place_control: Godot floors a Label at one text
            // line; Unity's box can be shorter (UxmlStyleApplier.fit_label).
            // A fitted Label is fitted again only for a new height.
            if self.fit_h.len() != io.controls.len() {
                self.fit_h = vec![f32::NAN; io.controls.len()];
                self.fit_seen = vec![None; io.controls.len()];
            }
            if force {
                self.fit_seen[i] = None;
                io.unfit.borrow_mut()[i] = None;
                // apply() drops the fit of a Label whose font changed.
                if !self.fit_h[i].is_nan() && !lbl.has_meta(&*self.sn_fit.get_or_insert_with(|| StringName::from("uxml_fit"))) {
                    self.fit_h[i] = f32::NAN;
                }
            }
            // fit_h: the height a Label was fitted for (NaN: not fitted). A
            // one-line Label taller than its box is fitted; a fitted Label
            // is fitted again for a new height (UxmlDocument._place_control
            // does the same).
            let sn_fit = self.sn_fit.get_or_insert_with(|| StringName::from("uxml_fit"));
            let fh = self.fit_h[i];
            let fitted = !fh.is_nan();
            let now_h = c.get_size().y;
            let floored = d(now_h) > d(r.size.y) + 0.01;
            let mut call = (floored && (fitted || lbl.get_autowrap_mode() == godot::classes::text_server::AutowrapMode::OFF))
                || (fitted && fh != r.size.y);
            if call && self.fit_seen[i] == Some((r.size.y, now_h)) {
                call = false;
            }
            if call {
                let mut a = a.clone();
                a.call("fit_label", &[c.to_variant(), r.size.to_variant()]);
                Self::touch(io, i);
                self.fit_h[i] = if lbl.has_meta(&*sn_fit) { r.size.y } else { f32::NAN };
                self.fit_seen[i] = Some((r.size.y, c.get_size().y));
                io.unfit.borrow_mut()[i] = None;
            }
        }
        let Some((start, end)) = out.insets[i] else { return };
        if self.hooked.len() != io.controls.len() {
            self.hooked = vec![None; io.controls.len()];
        }
        let changed = force || self.hooked[i] != Some((start, end));
        if changed && !force {
            // New insets give the Label new stylebox margins.
            if let Some(e) = io.maxc.borrow_mut().get_mut(i) {
                *e = None;
            }
            if let Some(e) = io.unfit.borrow_mut().get_mut(i) {
                *e = None;
            }
        }
        if changed {
            // The hook below sets the stylebox margins (uxml_margins).
            if let Some(e) = io.margins.borrow_mut().get_mut(i) {
                *e = None;
            }
        }
        if io.fields[i] {
            if changed {
                c.upcast::<Object>().call("set_content_insets", &[start.to_variant(), end.to_variant()]);
                Self::touch(io, i);
            }
        } else {
            if let Some(mut tr) = io.texrects[i].clone() {
                tr.set_offset(godot::builtin::Side::LEFT, start.x);
                tr.set_offset(godot::builtin::Side::TOP, start.y);
                tr.set_offset(godot::builtin::Side::RIGHT, -end.x);
                tr.set_offset(godot::builtin::Side::BOTTOM, -end.y);
            }
            if changed {
                if let Some(a) = applier {
                    let mut a = a.clone();
                    a.call("apply_resolved_insets", &[c.to_variant(), start.to_variant(), end.to_variant()]);
                    Self::touch(io, i);
                }
            }
            // UxmlDocument._place_control: a Button floored at its minimum
            // size gets content margins that fit its box
            // (UxmlStyleApplier.fit_button); a fitted Button is fitted again
            // for every placement.
            if let Some(a) = applier {
                if self.bfit.len() != io.controls.len() {
                    self.bfit = vec![false; io.controls.len()];
                    self.bfit_at = vec![None; io.controls.len()];
                }
                if force {
                    self.bfit_at[i] = None;
                }
                let size = c.get_size();
                if io.buttons[i] && (self.bfit[i] || size != r.size) {
                    if self.bfit[i]
                        && size == r.size
                        && self.bfit_at[i] == Some((r.size, start, end, c.get_minimum_size()))
                    {
                        self.hooked[i] = Some((start, end));
                        return;
                    }
                    let mut a = a.clone();
                    let fitted = a.call("fit_button", &[c.to_variant(), r.size.to_variant(), start.to_variant(), end.to_variant()]);
                    Self::touch(io, i);
                    self.bfit[i] = fitted.try_to::<bool>().unwrap_or(false);
                    self.bfit_at[i] = if self.bfit[i] {
                        Some((r.size, start, end, c.get_minimum_size()))
                    } else {
                        None
                    };
                    // fit_button sets the stylebox margins (uxml_margins).
                    if let Some(e) = io.margins.borrow_mut().get_mut(i) {
                        *e = None;
                    }
                }
            }
        }
        self.hooked[i] = Some((start, end));
    }
}

/// Layout results per preorder index (None: not laid out — display:none
/// or non-visual).
pub struct Out {
    pub rects: Vec<Option<Rect2>>,
    pub content: Vec<Option<Vector2>>,
    pub insets: Vec<Option<(Vector2, Vector2)>>,
    /// The rects before the pixel-grid rounding (a later subtree layout
    /// starts from them), and the containing-block width each element was
    /// laid out with.
    pub raw: Vec<Option<Rect2>>,
    pub cbs: Vec<f64>,
}

impl Out {
    /// The Dictionaries UxmlFlexLayout.compute returns (equivalence/debug).
    pub fn to_dicts(&self, c: &Cascade) -> (VarDictionary, VarDictionary, VarDictionary) {
        let (mut r, mut cs, mut ins) = (VarDictionary::new(), VarDictionary::new(), VarDictionary::new());
        for i in 0..self.rects.len() {
            let el = c.element_var(i);
            if let Some(v) = self.rects[i] {
                r.set(&el, v);
            }
            if let Some(v) = self.content[i] {
                cs.set(&el, v);
            }
            if let Some((s, e)) = self.insets[i] {
                let mut pair = VarArray::new();
                pair.push(&s.to_variant());
                pair.push(&e.to_variant());
                ins.set(&el, &pair);
            }
        }
        (r, cs, ins)
    }
}

#[derive(Clone)]
struct MemoE {
    kx: f64,
    ky: f64,
    kh: f64,
    bx: f64,
    by: f64,
    tx: f64,
    ty: f64,
    lin_w: f64,
    lin_h: f64,
    entry: Vec<f64>,
    out: Vector2,
    exit: Vec<f64>,
}

/// The last layout() call of an element in a placing pass: its border-box
/// size, containing-block width and the widths of the wrapping Labels of its
/// subtree before and after it. Its outputs are the subtree's entries of the
/// previous Out.
#[derive(Clone)]
pub struct LayE {
    size: Vector2,
    cb: f64,
    entry: Vec<f64>,
    exit: Vec<f64>,
}

/// What a placing pass hands to the next one (XCache).
#[derive(Default)]
pub struct Carry {
    meas: Vec<Vec<MemoE>>,
    lay: Vec<Option<LayE>>,
    pure: Vec<Option<(f64, Vector2)>>,
    vset: Vec<HashMap<u64, (f64, Vector2)>>,
    vread: Vec<HashMap<u64, Vector2>>,
    volatile: Vec<bool>,
}

/// What a control measures from, as far as the layout can see: its
/// combined minimum size, the natural size of a UxmlBox and the text of a
/// text control. Compared at the start of every placing pass with the value
/// of the last one.
#[derive(Clone, PartialEq)]
pub struct Fp {
    min: Vector2,
    nat: Vector2,
    text: Option<GString>,
}

/// Cross-pass cache of the placing layout (layout_place). A pass keeps the
/// measure entries and the last layout() call of every element whose
/// subtree did not change since the pass that made them, and the leaf
/// measures of every element that did not change. An element changed when
/// its layout record changed, its control was applied again (`force`),
/// the placement touched its control (LayoutIn::touched) or its Fp differs.
/// The results are those of a pass without the cache: every entry is a pure
/// function of the state of its subtree and of its key.
#[derive(Default)]
pub struct XCache {
    pub carry: Option<Carry>,
    fp: Vec<Option<Fp>>,
    key: Option<(usize, bool, bool)>,
    /// UxmlBox.natural_epoch now (set_natural_epoch) and at the last
    /// validate(): natural sizes are read again only when it moved.
    pub nat_epoch: i64,
    nat_seen: i64,
}

impl XCache {
    pub fn clear(&mut self) {
        let e = self.nat_epoch;
        *self = XCache::default();
        self.nat_epoch = e;
        self.nat_seen = -1;
    }

    /// Drops the layout entries of the subtrees of `roots` and of their
    /// ancestors: a subtree layout (layout_subtrees) wrote new outputs
    /// there, which the entries no longer describe.
    pub fn drop_layouts(&mut self, c: &Cascade, roots: &[usize]) {
        let Some(carry) = self.carry.as_mut() else { return };
        for &r in roots {
            if r >= carry.lay.len() {
                continue;
            }
            for j in r..c.subtree_end(r) {
                carry.lay[j] = None;
            }
            let mut p = c.parent_of(r);
            while p >= 0 {
                carry.lay[p as usize] = None;
                p = c.parent_of(p as usize);
            }
        }
    }

    /// The elements that changed since the last placing pass (see XCache),
    /// and the subtrees that hold one. Updates the fingerprints.
    pub fn validate(&mut self, c: &Cascade, io: &LayoutIn, forced: &[bool], rec_changed: &[bool]) -> (Vec<bool>, Vec<bool>) {
        let _p = crate::prof::scope("xc.validate");
        let n = c.len();
        let key = (n, io.text_clip, io.auto_size.is_some());
        let all = self.key != Some(key) || self.fp.len() != n || self.carry.is_none();
        if all {
            self.fp = vec![None; n];
            self.carry = None;
            self.key = Some(key);
        }
        let mut chg = vec![all; n];
        let read_nat = all || self.nat_epoch != self.nat_seen;
        self.nat_seen = self.nat_epoch;
        let sn_nat = StringName::from("natural_size");
        let mut touched = io.touched.borrow_mut();
        if touched.len() != n {
            *touched = vec![false; n];
        }
        for i in 0..n {
            if forced[i] || rec_changed.get(i).copied().unwrap_or(true) || touched[i] {
                chg[i] = true;
            }
            touched[i] = false;
            let prev = &self.fp[i];
            let fp = io.controls[i].as_ref().map(|ctl| {
                // A UxmlBox measures as its natural size (measure_leaf): its
                // minimum size is not read.
                if io.boxed[i] {
                    let nat = if read_nat {
                        ctl.clone().upcast::<Object>().get(&sn_nat).try_to::<Vector2>().unwrap_or(Vector2::ZERO)
                    } else {
                        prev.as_ref().map(|p| p.nat).unwrap_or(Vector2::ZERO)
                    };
                    return Fp { min: Vector2::ZERO, nat, text: None };
                }
                let min = ctl.get_combined_minimum_size();
                let nat = Vector2::ZERO;
                let text = if let Some(l) = &io.labels[i] {
                    Some(l.get_text())
                } else if let Some(r) = &io.rich[i] {
                    Some(r.get_text())
                } else if io.buttons[i] {
                    ctl.clone().try_cast::<godot::classes::Button>().ok().map(|b| b.get_text())
                } else {
                    None
                };
                Fp { min, nat, text }
            });
            if fp != self.fp[i] {
                chg[i] = true;
                self.fp[i] = fp;
            }
        }
        let mut sub = chg.clone();
        for i in (1..n).rev() {
            if sub[i] {
                let p = c.parent_of(i);
                if p >= 0 {
                    sub[p as usize] = true;
                }
            }
        }
        (chg, sub)
    }
}

/// The cross-pass state of one placing pass (Pass::new_cached).
pub struct Cached<'a> {
    pub chg: Vec<bool>,
    pub sub: Vec<bool>,
    pub prev: Option<&'a Out>,
    pub carry: Carry,
}

pub struct Pass<'a> {
    xc: Option<(Vec<bool>, Vec<bool>, Option<&'a Out>)>,
    lay_c: Vec<Option<LayE>>,
    c: &'a Cascade,
    io: &'a LayoutIn,
    recs: &'a [Rec],
    kinds: Vec<CtlKind>,
    warned: VarDictionary,
    warnings: VarArray,
    out: Out,
    // per-pass memos
    pad_m: Vec<Option<(f64, Edges)>>,
    mar_m: Vec<Option<(f64, Edges)>>,
    bor_m: Vec<Option<Edges>>,
    kids_m: Vec<Option<Rc<Vec<usize>>>>,
    enum_m: Vec<[Option<&'static str>; NE]>,
    abs_m: Vec<Option<Rc<Vec<usize>>>>,
    num_m: Vec<[Option<f64>; 2]>,
    sens_m: Vec<i32>,
    meas_m: Vec<Vec<MemoE>>,
    margins_m: Vec<Option<Option<[f64; 4]>>>,
    /// Per-pass memo: the control carries `uxml_clip_text` (metas do not
    /// change during a pass).
    cliptext_m: Vec<Option<bool>>,
    /// Some element is best-fit text; per-pass memo of hint_sub.
    any_hinted: bool,
    hs_m: Vec<Option<bool>>,
    pure_m: Vec<Option<(f64, Vector2)>>,
    /// Per-pass memo: the max-content width of a wrapping Label.
    maxc_m: Vec<Option<f32>>,
    /// "font", "font_size", "normal".
    sn_names: [StringName; 4],
    /// Per-pass memo: the unfitted height of a fitted Label, -1 for a Label
    /// without `uxml_fit` (UxmlStyleApplier.fit_label, unfitted_height).
    fit_m: Vec<Option<f64>>,
    /// Best-fit text (-unity-text-auto-size): measured through
    /// UxmlStyleApplier.autosize_measure, which reads the width hint.
    hinted: Vec<bool>,
    // volatile (wrapping label) emulation
    volatile: Vec<bool>,
    vw: Vec<f64>,
    vset: Vec<HashMap<u64, (f64, Vector2)>>,
    vread: Vec<HashMap<u64, Vector2>>,
    vl_m: Vec<Option<Rc<Vec<usize>>>>,
    sn_natural: StringName,
    sn_normal: StringName,
    sn_margins: StringName,
    sn_full: StringName,
    sn_elided: StringName,
    sn_text: StringName,
    sn_cliptext: StringName,
    sn_clip: StringName,
    sn_clipfull: StringName,
    sn_fit: StringName,
    sn_unfit: StringName,
}

impl<'a> Pass<'a> {
    pub fn new(c: &'a Cascade, io: &'a LayoutIn, recs: &'a [Rec], _sbw: f64, warned: VarDictionary, warnings: VarArray) -> Self {
        Self::new_with(c, io, recs, warned, warnings, None, None)
    }

    /// A pass that lays out only the subtrees of `roots` (run_subtrees):
    /// the controls outside them are not read.
    pub fn new_sub(c: &'a Cascade, io: &'a LayoutIn, recs: &'a [Rec], warned: VarDictionary, warnings: VarArray, roots: &[usize]) -> Self {
        let mut only = vec![false; c.len()];
        for &r in roots {
            for j in r..c.subtree_end(r) {
                only[j] = true;
            }
        }
        Self::new_with(c, io, recs, warned, warnings, None, Some(&only))
    }

    /// `keep`: the elements that changed since the last placing pass and
    /// its volatile flags, which unchanged elements keep (only an apply
    /// changes the autowrap mode or the best-fit meta).
    fn new_with(c: &'a Cascade, io: &'a LayoutIn, recs: &'a [Rec], warned: VarDictionary, warnings: VarArray, keep: Option<(&Vec<bool>, &mut Vec<bool>)>, only: Option<&[bool]>) -> Self {
        let n = c.len();
        let keep = keep.filter(|(_, v)| v.len() == n);
        let mut kinds = vec![CtlKind::None; n];
        let mut volatile = vec![false; n];
        let mut vw = vec![0.0; n];
        let mut hinted = vec![false; n];
        let sn_normal = StringName::from("normal");
        let sn_margins = StringName::from("uxml_margins");
        for i in 0..n {
            if only.is_some_and(|o| !o[i]) {
                continue;
            }
            if let Some(ctl) = &io.controls[i] {
                kinds[i] = if io.boxed[i] { CtlKind::Boxed } else { CtlKind::Plain };
                if let Some((chg, vol)) = &keep {
                    if !chg[i] && io.auto_size.is_none() {
                        if vol[i] {
                            volatile[i] = true;
                            vw[i] = d(ctl.get_size().x) - hpad_of(io.margins_of(i, ctl, &sn_normal, &sn_margins));
                        }
                        continue;
                    }
                }
                if io.auto_size.is_some() && ctl.has_meta("uxml_autosize") {
                    hinted[i] = true;
                    continue;
                }
                let wraps = match (&io.labels[i], &io.rich[i]) {
                    (Some(lbl), _) => lbl.get_autowrap_mode() != godot::classes::text_server::AutowrapMode::OFF,
                    (None, Some(r)) => r.get_autowrap_mode() != godot::classes::text_server::AutowrapMode::OFF,
                    _ => false,
                };
                if wraps {
                    volatile[i] = true;
                    vw[i] = d(ctl.get_size().x) - hpad_of(io.margins_of(i, ctl, &sn_normal, &sn_margins));
                }
            }
        }
        let any_hinted = hinted.iter().any(|&h| h);
        Pass {
            xc: None,
            lay_c: vec![],
            c,
            io,
            recs,
            kinds,
            warned,
            warnings,
            out: Out {
                rects: vec![None; n],
                content: vec![None; n],
                insets: vec![None; n],
                raw: vec![],
                cbs: vec![0.0; n],
            },
            pad_m: vec![None; n],
            mar_m: vec![None; n],
            bor_m: vec![None; n],
            kids_m: vec![None; n],
            abs_m: vec![None; n],
            enum_m: (0..n).map(|_| Default::default()).collect(),
            num_m: vec![[None, None]; n],
            sens_m: vec![-1; n],
            meas_m: (0..n).map(|_| vec![]).collect(),
            margins_m: vec![None; n],
            cliptext_m: vec![None; n],
            fit_m: vec![None; n],
            any_hinted,
            hs_m: vec![None; n],
            pure_m: vec![None; n],
            maxc_m: vec![None; n],
            sn_names: [StringName::from("font"), StringName::from("font_size"), StringName::from("normal"), StringName::from("uxml_maxc")],
            hinted,
            volatile,
            vw,
            vset: (0..n).map(|_| HashMap::new()).collect(),
            vread: (0..n).map(|_| HashMap::new()).collect(),
            vl_m: vec![None; n],
            sn_natural: StringName::from("natural_size"),
            sn_normal: StringName::from("normal"),
            sn_margins: StringName::from("uxml_margins"),
            sn_full: StringName::from("uxml_full_text"),
            sn_elided: StringName::from("uxml_elided"),
            sn_text: StringName::from("text"),
            sn_cliptext: StringName::from("uxml_clip_text"),
            sn_clip: StringName::from("clip_text"),
            sn_clipfull: StringName::from("uxml_clip_full"),
            sn_fit: StringName::from("uxml_fit"),
            sn_unfit: StringName::from("uxml_unfit"),
        }
    }

    /// A placing pass with the cross-pass cache (see XCache).
    pub fn new_cached(c: &'a Cascade, io: &'a LayoutIn, recs: &'a [Rec], warned: VarDictionary, warnings: VarArray, cached: Cached<'a>) -> Self {
        let Cached { chg, sub, prev, mut carry } = cached;
        let mut p = Self::new_with(c, io, recs, warned, warnings, Some((&chg, &mut carry.volatile)), None);
        let n = c.len();
        let ok = carry.meas.len() == n && prev.is_some_and(|o| o.raw.len() == n);
        if ok {
            for i in 0..n {
                if !sub[i] {
                    p.meas_m[i] = std::mem::take(&mut carry.meas[i]);
                }
                if !chg[i] {
                    p.pure_m[i] = carry.pure[i];
                    p.vset[i] = std::mem::take(&mut carry.vset[i]);
                    p.vread[i] = std::mem::take(&mut carry.vread[i]);
                }
            }
            p.lay_c = std::mem::take(&mut carry.lay);
            for i in 0..n {
                if sub[i] {
                    p.lay_c[i] = None;
                }
            }
        } else {
            p.lay_c = vec![None; n];
        }
        p.xc = Some((chg, sub, if ok { prev } else { None }));
        p
    }

    /// The state the next placing pass starts from (XCache).
    fn carry_out(&mut self) -> Carry {
        let n = self.c.len();
        let mut lay = std::mem::take(&mut self.lay_c);
        for j in 0..n {
            if self.out.rects[j].is_none() {
                lay[j] = None;
            }
        }
        let mut meas = std::mem::take(&mut self.meas_m);
        for m in meas.iter_mut() {
            if m.len() > 24 {
                m.clear();
            }
        }
        let mut vset = std::mem::take(&mut self.vset);
        let mut vread = std::mem::take(&mut self.vread);
        for k in 0..n {
            if vset[k].len() > 24 {
                vset[k].clear();
            }
            if vread[k].len() > 24 {
                vread[k].clear();
            }
        }
        Carry { meas, lay, pure: std::mem::take(&mut self.pure_m), vset, vread, volatile: std::mem::take(&mut self.volatile) }
    }

    /// run() of a cached pass: the output and what the next pass starts from.
    pub fn run_cached(mut self, host: Vector2) -> (Out, Carry) {
        self.layout(0, Rect2::new(Vector2::ZERO, host), d(host.x));
        let carry = self.carry_out();
        self.out.raw = self.out.rects.clone();
        if self.io.pixel_grid {
            let mut rounded = self.out.rects.clone();
            round_node(self.c, 0, 0.0, 0.0, &self.out.raw, &mut rounded);
            self.out.rects = rounded;
        }
        (self.out, carry)
    }

    pub fn run(mut self, host: Vector2) -> Out {
        self.layout(0, Rect2::new(Vector2::ZERO, host), d(host.x));
        self.out.raw = self.out.rects.clone();
        if self.io.pixel_grid {
            let mut rounded = self.out.rects.clone();
            round_node(self.c, 0, 0.0, 0.0, &self.out.raw, &mut rounded);
            self.out.rects = rounded;
        }
        self.out
    }

    /// Lays out only the subtrees `roots`: (preorder index, unrounded rect,
    /// containing-block width, unrounded absolute position of the parent),
    /// each as the full pass reached it. The entries of the other elements
    /// stay None (UxmlDocument._do_local_layout).
    pub fn run_subtrees(mut self, roots: &[(usize, Rect2, f64, f64, f64)]) -> Out {
        for &(i, rect, cb, _, _) in roots {
            self.layout(i, rect, cb);
        }
        self.out.raw = self.out.rects.clone();
        if self.io.pixel_grid {
            let mut rounded = self.out.rects.clone();
            for &(i, _, _, al, at) in roots {
                round_node(self.c, i, al, at, &self.out.raw, &mut rounded);
            }
            self.out.rects = rounded;
        }
        self.out
    }

    // ------------------------------------------------------------- warnings

    fn warn_once(&mut self, i: usize, prop: &str, message: String) {
        let key = format!("{prop}:{message}").to_variant();
        if self.warned.contains_key(&key) {
            return;
        }
        self.warned.set(&key, true);
        let mut dd = VarDictionary::new();
        dd.set("kind", "unsupported-value");
        dd.set("severity", crate::cascade::severity_of("unsupported-value"));
        dd.set("message", message.as_str());
        dd.set("file", &self.c.file());
        let (offset, line, column) = self.c.location(i);
        dd.set("offset", offset);
        dd.set("line", line);
        dd.set("column", column);
        dd.set("end_offset", self.c.end_offset(i));
        self.warnings.push(&dd.to_variant());
    }

    // ------------------------------------------------------------- access

    fn str_(&self, i: usize, e: usize, default: &'static str) -> &'a str {
        let recs: &'a [Rec] = self.recs;
        recs[i].enums[e - NP].as_deref().unwrap_or(default)
    }

    fn num(&mut self, i: usize, pid: usize, default: f64) -> f64 {
        let slot = pid - P_GROW;
        if let Some(v) = self.num_m[i][slot] {
            return v;
        }
        let mut out = default;
        match self.recs[i].kinds[pid] {
            K::Nan => {
                let name = LAYOUT_PROPS[pid];
                let dflt = if default == 0.0 { "0.0" } else { "1.0" };
                let m = format!("{}: \"{}\" is not a number; {} used", name, self.recs[i].raws[pid], dflt);
                self.warn_once(i, name, m);
            }
            K::Num => out = self.recs[i].vals[pid],
            _ => {}
        }
        self.num_m[i][slot] = Some(out);
        out
    }

    fn enum_(&mut self, i: usize, e: usize, valid: &'static [&'static str], default: &'static str) -> &'static str {
        if let Some(v) = self.enum_m[i][e - NP] {
            return v;
        }
        let raw = self.str_(i, e, default);
        let v = match valid.iter().find(|x| **x == raw) {
            Some(x) => *x,
            None => {
                let name = LAYOUT_PROPS[e];
                let m = format!("{name}: \"{raw}\" is not supported; {default} used");
                self.warn_once(i, name, m);
                default
            }
        };
        self.enum_m[i][e - NP] = Some(v);
        v
    }

    /// NAN for auto.
    fn lenr(&mut self, i: usize, pid: usize, base: f64) -> f64 {
        match self.recs[i].kinds[pid] {
            K::Px => self.recs[i].vals[pid],
            K::Pct => {
                if base < 0.0 {
                    f64::NAN
                } else {
                    base * self.recs[i].vals[pid] / 100.0
                }
            }
            K::Bad => {
                let name = LAYOUT_PROPS[pid];
                let m = format!("{}: {}", name, self.recs[i].probs[&pid]);
                self.warn_once(i, name, m);
                f64::NAN
            }
            _ => f64::NAN,
        }
    }

    /// flex_layout.gd _ratio.
    fn ratio(&mut self, i: usize) -> f64 {
        match self.recs[i].kinds[P_ASPECT] {
            K::Num => self.recs[i].vals[P_ASPECT],
            K::Nan => {
                let m = format!("aspect-ratio: \"{}\" is not a valid ratio; auto used", self.recs[i].raws[P_ASPECT]);
                self.warn_once(i, "aspect-ratio", m);
                0.0
            }
            _ => 0.0,
        }
    }

    fn dim(&mut self, i: usize, pid: usize, base: f64) -> f64 {
        let r = self.lenr(i, pid, base);
        if r.is_nan() { -1.0 } else { r }
    }

    fn bound(&mut self, i: usize, pid: usize, base: f64, is_min: bool) -> f64 {
        if self.recs[i].kinds[pid] == K::None {
            return if is_min { -1.0 } else { f64::INFINITY };
        }
        let r = self.lenr(i, pid, base);
        if r.is_nan() {
            return if is_min { -1.0 } else { f64::INFINITY };
        }
        r
    }

    fn min_or(&mut self, i: usize, pid: usize, base: f64, fallback: f64) -> f64 {
        let b = self.bound(i, pid, base, true);
        if b < 0.0 { fallback } else { b }
    }

    fn edges(&mut self, i: usize, base: usize, cb: f64, allow_negative: bool) -> Edges {
        let mut out = [0.0; 4];
        for k in 0..4 {
            let pid = base + k;
            let kind = self.recs[i].kinds[pid];
            if kind == K::None {
                continue;
            }
            if kind == K::AutoKw {
                if base != P_MAR {
                    let name = LAYOUT_PROPS[pid];
                    self.warn_once(i, name, format!("{name}: auto is not supported; 0 used"));
                }
                continue;
            }
            let r = self.lenr(i, pid, cb);
            if r.is_nan() {
                continue;
            } else if r < 0.0 && !allow_negative {
                let name = LAYOUT_PROPS[pid];
                self.warn_once(i, name, format!("{name}: negative values are invalid; 0 used"));
            } else {
                out[k] = if self.io.pixel_grid { grid_box(r, false) } else { r };
            }
        }
        out
    }

    fn padding(&mut self, i: usize, cb: f64) -> Edges {
        if let Some((w, e)) = self.pad_m[i] {
            if w == cb {
                return e;
            }
        }
        let e = self.edges(i, P_PAD, cb, false);
        self.pad_m[i] = Some((cb, e));
        e
    }

    fn margins(&mut self, i: usize, cb: f64) -> Edges {
        if let Some((w, e)) = self.mar_m[i] {
            if w == cb {
                return e;
            }
        }
        let e = self.edges(i, P_MAR, cb, true);
        self.mar_m[i] = Some((cb, e));
        e
    }

    fn borders(&mut self, i: usize) -> Edges {
        if let Some(e) = self.bor_m[i] {
            return e;
        }
        let mut out = [0.0; 4];
        for k in 0..4 {
            let pid = P_BOR + k;
            match self.recs[i].kinds[pid] {
                K::Px => {
                    let v = self.recs[i].vals[pid];
                    out[k] = if self.io.pixel_grid { grid_box(v, true) } else { gmax(0.0, v) };
                }
                K::Bad => {
                    let name = LAYOUT_PROPS[pid];
                    let m = format!("{}: {}", name, self.recs[i].probs[&pid]);
                    self.warn_once(i, name, m);
                }
                K::Pct => {
                    let name = LAYOUT_PROPS[pid];
                    self.warn_once(i, name, format!("{name}: percentages are not supported for border width"));
                }
                _ => {}
            }
        }
        self.bor_m[i] = Some(out);
        out
    }

    fn gap(&mut self, i: usize, pid: usize, base: f64) -> f64 {
        match self.recs[i].kinds[pid] {
            K::Px => gmax(0.0, self.recs[i].vals[pid]),
            K::Pct => {
                if base < 0.0 { 0.0 } else { gmax(0.0, base * self.recs[i].vals[pid] / 100.0) }
            }
            K::Bad => {
                let name = LAYOUT_PROPS[pid];
                let m = format!("{}: {}", name, self.recs[i].probs[&pid]);
                self.warn_once(i, name, m);
                0.0
            }
            _ => 0.0,
        }
    }

    fn flex_children(&mut self, i: usize) -> Rc<Vec<usize>> {
        if let Some(k) = &self.kids_m[i] {
            return k.clone();
        }
        let mut out = vec![];
        let mut abs = vec![];
        for ch in self.c.children(i) {
            if self.c.non_visual(ch) {
                continue;
            }
            let display = self.str_(ch, E_DISPLAY, "flex");
            if display == "none" {
                continue;
            }
            if display != "flex" {
                self.warn_once(ch, "display", format!("display: \"{display}\" is not supported; flex used"));
            }
            if self.recs[ch].enums[E_POSITION - NP].is_some()
                && self.enum_(ch, E_POSITION, &POSITIONS, "relative") == "absolute"
            {
                abs.push(ch);
            } else {
                out.push(ch);
            }
        }
        let rc = Rc::new(out);
        self.kids_m[i] = Some(rc.clone());
        self.abs_m[i] = Some(Rc::new(abs));
        rc
    }

    fn abs_children(&mut self, i: usize) -> Rc<Vec<usize>> {
        self.flex_children(i);
        self.abs_m[i].clone().unwrap()
    }

    /// flex_layout.gd _rel_offset.
    fn rel_offset(&mut self, ch: usize, base: Vector2) -> Vector2 {
        let mut out = [0.0f64; 2];
        let lft = self.lenr(ch, P_POS + L, d(base.x));
        if !lft.is_nan() {
            out[0] = lft;
        } else {
            let rgt = self.lenr(ch, P_POS + R, d(base.x));
            if !rgt.is_nan() {
                out[0] = -rgt;
            }
        }
        let top = self.lenr(ch, P_POS + T, d(base.y));
        if !top.is_nan() {
            out[1] = top;
        } else {
            let bot = self.lenr(ch, P_POS + B, d(base.y));
            if !bot.is_nan() {
                out[1] = -bot;
            }
        }
        Vector2::new(f(out[0]), f(out[1]))
    }

    /// flex_layout.gd _layout_abs.
    fn layout_abs(&mut self, i: usize, size: Vector2, pad: Edges, bor: Edges, kids: &[usize]) {
        let sx = d(size.x);
        let sy = d(size.y);
        let cbw = gmax(0.0, sx - bor[L] - bor[R]);
        let cbh = gmax(0.0, sy - bor[T] - bor[B]);
        let row = self.is_row(i);
        let reverse = self.reverse_main(i);
        let justify = self.enum_(i, E_JUSTIFY, &JUSTIFY, "flex-start");
        let align_items = self.enum_(i, E_ALIGN_ITEMS, &ALIGN, "stretch");
        for &ch in kids {
            let m = self.margins(ch, cbw);
            let pads = self.padding(ch, cbw);
            let bors = self.borders(ch);
            let in_w = pads[L] + pads[R] + bors[L] + bors[R];
            let in_h = pads[T] + pads[B] + bors[T] + bors[B];
            let lft = self.lenr(ch, P_POS + L, cbw);
            let rgt = self.lenr(ch, P_POS + R, cbw);
            let top = self.lenr(ch, P_POS + T, cbh);
            let bot = self.lenr(ch, P_POS + B, cbh);
            let mut w = self.dim(ch, P_W, cbw);
            if w < 0.0 && !lft.is_nan() && !rgt.is_nan() {
                w = gmax(0.0, cbw - lft - rgt - m[L] - m[R]);
            }
            let mut h = self.dim(ch, P_H, cbh);
            if h < 0.0 && !top.is_nan() && !bot.is_nan() {
                h = gmax(0.0, cbh - top - bot - m[T] - m[B]);
            }
            let aar = self.ratio(ch);
            if aar > 0.0 {
                if w >= 0.0 && h < 0.0 {
                    h = w / aar;
                } else if h >= 0.0 && w < 0.0 {
                    w = h * aar;
                }
            }
            if w < 0.0 || h < 0.0 {
                let nat = self.measure(ch, Vector2::new(f(cbw), f(cbh)), w, -1.0, -1.0);
                if w < 0.0 {
                    w = d(nat.x);
                }
                if h < 0.0 {
                    h = d(nat.y);
                }
            }
            let lo = self.min_or(ch, P_MINW, cbw, 0.0);
            let hi = self.bound(ch, P_MAXW, cbw, false);
            w = gmax(gclamp(w, lo, hi), in_w);
            let lo = self.min_or(ch, P_MINH, cbh, 0.0);
            let hi = self.bound(ch, P_MAXH, cbh, false);
            h = gmax(gclamp(h, lo, hi), in_h);
            let mut al: &str = self.str_(ch, E_ALIGN_SELF, "auto");
            if al == "auto" {
                al = align_items;
            }
            let x = if !lft.is_nan() {
                bor[L] + lft + m[L]
            } else if !rgt.is_nan() {
                sx - bor[R] - rgt - m[R] - w
            } else {
                abs_free(if row { justify } else { al }, row && reverse, sx, w, bor[L] + pad[L] + m[L])
            };
            let y = if !top.is_nan() {
                bor[T] + top + m[T]
            } else if !bot.is_nan() {
                sy - bor[B] - bot - m[B] - h
            } else {
                abs_free(if row { al } else { justify }, !row && reverse, sy, h, bor[T] + pad[T] + m[T])
            };
            self.layout(ch, Rect2::new(Vector2::new(f(x), f(y)), Vector2::new(f(w), f(h))), cbw);
        }
    }

    fn is_row(&mut self, i: usize) -> bool {
        let dd = self.enum_(i, E_DIR, &DIRECTIONS, "column");
        dd == "row" || dd == "row-reverse"
    }

    fn reverse_main(&mut self, i: usize) -> bool {
        self.enum_(i, E_DIR, &DIRECTIONS, "column").ends_with("-reverse")
    }

    /// UxmlFlexLayout._stretch_hint: the border-box width hint of a
    /// best-fit text item in a column whose cross axis stretches it.
    fn stretch_hint(&mut self, ch: usize, row: bool, align_items: &str, ac: f64, m: &Edges) -> f64 {
        if row || ac < 0.0 {
            return -1.0;
        }
        // Yoga measures a stretched child at the stretched width: a
        // container whose content wraps gets its real height (a row-wrap
        // grid in a ScrollView). Leaves: only best-fit text reads the hint.
        if self.flex_children(ch).is_empty() && !self.hinted[ch] {
            return -1.0;
        }
        let mut al: &str = self.str_(ch, E_ALIGN_SELF, "auto");
        if al == "auto" {
            al = align_items;
        }
        if al != "stretch" || self.dim(ch, P_W, ac) >= 0.0 {
            return -1.0;
        }
        gmax(0.0, ac - m[L] - m[R])
    }

    fn sens(&mut self, i: usize) -> i32 {
        if self.sens_m[i] >= 0 {
            return self.sens_m[i];
        }
        let k = &self.recs[i].kinds;
        let mut s = 0;
        if k[P_W] == K::Pct || k[P_MINW] == K::Pct || k[P_MAXW] == K::Pct || (P_PAD..P_PAD + 4).any(|p| k[p] == K::Pct) {
            s |= 1;
        }
        if k[P_H] == K::Pct || k[P_MINH] == K::Pct || k[P_MAXH] == K::Pct {
            s |= 2;
        }
        // Leaves and containers both read the width hint (see stretch_hint).
        s |= 4;
        self.sens_m[i] = s;
        s
    }

    fn vlist(&mut self, i: usize) -> Rc<Vec<usize>> {
        if let Some(v) = &self.vl_m[i] {
            return v.clone();
        }
        let mut out = vec![];
        if self.volatile[i] {
            out.push(i);
        }
        for ch in self.c.children(i) {
            out.extend(self.vlist(ch).iter().copied());
        }
        let rc = Rc::new(out);
        self.vl_m[i] = Some(rc.clone());
        rc
    }

    // ------------------------------------------------------------- measurer

    /// UxmlDocument._measure_leaf.
    fn measure_leaf(&mut self, i: usize, content_w: f64) -> Vector2 {
        let _p = crate::prof::scope(if self.volatile[i] { "measure_leaf.volatile" } else { "measure_leaf" });
        let Some(c) = self.io.controls[i].clone() else { return Vector2::ZERO };
        if self.volatile[i] && content_w >= 0.0 {
            // UxmlDocument._measure_leaf: the content width plus the USS
            // padding and border.
            let mut s = c.get_size();
            s.x = f(content_w + hpad_of(self.sb_margins(i, &c)));
            let mut cm = c.clone();
            cm.set_size(s);
        }
        let clipped = match self.kinds[i] {
            _ if self.hinted[i] => false,
            CtlKind::Boxed => false,
            _ if !self.io.text_clip => false,
            _ if self.io.maxc_on.get() => {
                let kept = self.io.cliptext.borrow()[i];
                match kept {
                    Some(v) => v,
                    None => {
                        let v = c.has_meta(&self.sn_cliptext);
                        self.io.cliptext.borrow_mut()[i] = Some(v);
                        v
                    }
                }
            }
            _ => *self.cliptext_m[i].get_or_insert_with(|| c.has_meta(&self.sn_cliptext)),
        };
        let mut ms = match self.kinds[i] {
            _ if self.hinted[i] => {
                // UxmlStyleApplier.autosize_measure (the GDScript measurer
                // calls the same function).
                let mut a = self.io.auto_size.clone().unwrap();
                a.call("autosize_measure", &[c.to_variant(), content_w.to_variant()]).try_to::<Vector2>().unwrap_or(Vector2::ZERO)
            }
            CtlKind::Boxed => c.clone().upcast::<Object>().get(&self.sn_natural).try_to::<Vector2>().unwrap_or(Vector2::ZERO),
            _ if clipped => {
                // overflow: hidden / elided text measures as its full text
                // with clip_text off (UxmlDocument._measure_leaf), kept in
                // `uxml_clip_full` for the full text and the clipped
                // minimum size.
                let mut o = c.clone().upcast::<Object>();
                let shown = o.get(&self.sn_text);
                let swap = c.has_meta(&self.sn_full) && shown == c.get_meta(&self.sn_elided);
                let full = if swap { c.get_meta(&self.sn_full) } else { shown.clone() };
                let clipped_ms = c.get_combined_minimum_size();
                let hit = if c.has_meta(&self.sn_clipfull) {
                    c.get_meta(&self.sn_clipfull).try_to::<VarArray>().ok().and_then(|a| {
                        let same = a.len() == 3
                            && a.get(0).map(|v| v == full).unwrap_or(false)
                            && a.get(1).and_then(|v| v.try_to::<Vector2>().ok()) == Some(clipped_ms);
                        if same { a.get(2).and_then(|v| v.try_to::<Vector2>().ok()) } else { None }
                    })
                } else {
                    None
                };
                match hit {
                    Some(m) => m,
                    None => {
                        o.set(&self.sn_clip, &false.to_variant());
                        if swap {
                            o.set(&self.sn_text, &full);
                        }
                        let m = c.get_combined_minimum_size();
                        if swap {
                            o.set(&self.sn_text, &shown);
                        }
                        o.set(&self.sn_clip, &true.to_variant());
                        let mut arr = VarArray::new();
                        arr.push(&full);
                        arr.push(&clipped_ms.to_variant());
                        arr.push(&m.to_variant());
                        o.set_meta(&self.sn_clipfull, &arr.to_variant());
                        m
                    }
                }
            }
            _ => c.get_combined_minimum_size(),
        };
        if let Some(lbl) = self.io.labels[i].clone() {
            if self.volatile[i] {
                // Unity measures wrapping text at its max-content width
                // (UxmlDocument._measure_leaf). It does not depend on the
                // width: once per pass.
                let mc = match self.maxc_m[i] {
                    Some(v) => v,
                    None => {
                        let v = f(self.max_content(i, &lbl));
                        self.maxc_m[i] = Some(v);
                        v
                    }
                };
                ms.x = mc;
            }
            let fit_h = match self.fit_m[i] {
                Some(v) => v,
                None => {
                    let on = self.io.maxc_on.get();
                    let kept = if on { self.io.unfit.borrow()[i] } else { None };
                    let v = match kept {
                        Some(v) => v,
                        None if lbl.has_meta(&self.sn_fit) => unfitted_height(&lbl, &self.sn_unfit),
                        None => -1.0,
                    };
                    if on {
                        self.io.unfit.borrow_mut()[i] = Some(v);
                    }
                    self.fit_m[i] = Some(v);
                    v
                }
            };
            if fit_h >= 0.0 {
                ms.y = f(fit_h);
            }
        }
        if let Some(lbl) = &self.io.labels[i] {
            // Unity measures an empty text 0 x 0 (UxmlDocument._measure_leaf).
            if lbl.get_text().is_empty() {
                return Vector2::ZERO;
            }
        }
        if let Some(m) = self.sb_margins(i, &c) {
            ms.x = f(gmax(0.0, d(ms.x) - m[0] - m[2]));
            ms.y = f(gmax(0.0, d(ms.y) - m[1] - m[3]));
        }
        ms
    }

    /// The `uxml_margins` of element i's control, once per pass (and across
    /// passes through LayoutIn::margins_of).
    fn sb_margins(&mut self, i: usize, c: &Gd<Control>) -> Option<[f64; 4]> {
        if let Some(m) = self.margins_m[i] {
            return m;
        }
        let m = self.io.margins_of(i, c, &self.sn_normal, &self.sn_margins);
        self.margins_m[i] = Some(m);
        m
    }

    fn measure_call(&mut self, i: usize, hint: f64) -> Vector2 {
        if !self.volatile[i] {
            // A pure measure repeats within a pass: one engine call per
            // element and argument (only best-fit text reads the argument).
            let arg = if self.hinted[i] { hint } else { -1.0 };
            if let Some((a, r)) = self.pure_m[i] {
                if a == arg {
                    return r;
                }
            }
            let r = self.measure_leaf(i, hint);
            self.pure_m[i] = Some((arg, r));
            return r;
        }
        if hint >= 0.0 {
            if let Some(&(actual, res)) = self.vset[i].get(&hint.to_bits()) {
                self.vw[i] = actual;
                return res;
            }
            let res = self.measure_leaf(i, hint);
            let ctl = self.io.controls[i].clone().unwrap();
            let actual = d(ctl.get_size().x) - hpad_of(self.sb_margins(i, &ctl));
            self.vset[i].insert(hint.to_bits(), (actual, res));
            self.vread[i].insert(actual.to_bits(), res);
            self.vw[i] = actual;
            return res;
        }
        let cur = self.vw[i];
        if let Some(&r) = self.vread[i].get(&cur.to_bits()) {
            return r;
        }
        let res = self.measure_leaf(i, cur);
        self.vread[i].insert(cur.to_bits(), res);
        res
    }

    // ------------------------------------------------------------- measure

    /// flex_layout.gd _measure: bx/by are the measure bounds (Yoga AtMost;
    /// -1 for none).
    fn measure(&mut self, i: usize, avail: Vector2, hint: f64, bx: f64, by: f64) -> Vector2 {
        self.measure_t(i, avail, hint, bx, by).0
    }

    /// label_max_content through the cross-layout cache (by text).
    fn max_content(&self, i: usize, lbl: &Gd<Label>) -> f64 {
        if !self.io.maxc_on.get() {
            return label_max_content(lbl, &self.sn_names);
        }
        let text = lbl.get_text();
        if let Some((t, v)) = &self.io.maxc.borrow()[i] {
            if *t == text {
                return *v;
            }
        }
        let v = label_max_content(lbl, &self.sn_names);
        self.io.maxc.borrow_mut()[i] = Some((text, v));
        v
    }

    /// flex_layout.gd _has_dim.
    fn has_dim(&self, i: usize, pid: usize, base: f64) -> bool {
        let r = &self.recs[i];
        match r.kinds[pid] {
            K::Px => r.vals[pid] >= 0.0,
            K::Pct => base >= 0.0 && base * r.vals[pid] / 100.0 >= 0.0,
            _ => false,
        }
    }

    /// flex_layout.gd _has_flow_kids.
    fn has_flow_kids(&self, i: usize) -> bool {
        if let Some(k) = &self.kids_m[i] {
            return !k.is_empty();
        }
        for ch in self.c.children(i) {
            if self.c.non_visual(ch) {
                continue;
            }
            if self.str_(ch, E_DISPLAY, "flex") == "none" {
                continue;
            }
            if self.str_(ch, E_POSITION, "relative") == "absolute" {
                continue;
            }
            return true;
        }
        false
    }

    /// flex_layout.gd _hint_sub.
    fn hint_sub(&mut self, i: usize) -> bool {
        if !self.any_hinted {
            return false;
        }
        if let Some(v) = self.hs_m[i] {
            return v;
        }
        let mut out = self.hinted[i];
        if !out {
            for ch in self.c.children(i) {
                if self.hint_sub(ch) {
                    out = true;
                    break;
                }
            }
        }
        self.hs_m[i] = Some(out);
        out
    }

    /// The measure and its bound thresholds (flex_layout.gd _measure,
    /// entries [13] and [14]).
    fn measure_t(&mut self, i: usize, avail: Vector2, hint: f64, bx: f64, by: f64) -> (Vector2, f64, f64, f64, f64) {
        let mut bx = bx;
        let mut by = by;
        if bx >= 0.0 && (self.has_dim(i, P_W, d(avail.x)) || (hint >= 0.0 && self.has_flow_kids(i))) {
            bx = -1.0;
        }
        if by >= 0.0 && self.has_dim(i, P_H, d(avail.y)) {
            by = -1.0;
        }
        let sens = self.sens(i);
        let kx = if sens & 1 != 0 { d(avail.x) } else { 0.0 };
        let ky = if sens & 2 != 0 { d(avail.y) } else { 0.0 };
        let kh = if sens & 4 != 0 { hint } else { -1.0 };
        let vl = self.vlist(i);
        // Memo lookup: the entry widths are compared in place (most calls
        // hit; collecting them first cost an allocation per call).
        for e in &self.meas_m[i] {
            if e.kx == kx
                && e.ky == ky
                && e.kh == kh
                && e.bx == bx
                && e.by == by
                && e.entry.len() == vl.len()
                && vl.iter().zip(e.entry.iter()).all(|(&v, &w)| self.vw[v] == w)
            {
                for (k, &v) in vl.iter().enumerate() {
                    self.vw[v] = e.exit[k];
                }
                return (e.out, e.tx, e.ty, e.lin_w, e.lin_h);
            }
        }
        let entry: Vec<f64> = vl.iter().map(|&v| self.vw[v]).collect();
        if by >= 0.0 {
            let r = self.measure_t(i, avail, hint, bx, -1.0);
            if below(r.2, r.4, by) {
                return r;
            }
        } else if bx >= 0.0 && vl.is_empty() && !self.hint_sub(i) {
            let r = self.measure_t(i, avail, hint, -1.0, -1.0);
            if below(r.1, r.3, bx) {
                return r;
            }
        }
        let w = self.dim(i, P_W, d(avail.x));
        let h = self.dim(i, P_H, d(avail.y));
        let pad = self.padding(i, d(avail.x));
        let bor = self.borders(i);
        let in_w = pad[L] + pad[R] + bor[L] + bor[R];
        let in_h = pad[T] + pad[B] + bor[T] + bor[B];
        let kids = self.flex_children(i);
        let (bw, bh);
        let mut tx = NO_BOUND;
        let mut ty = NO_BOUND;
        let mut lin_w = -1.0;
        let mut lin_h = -1.0;
        if kids.is_empty() {
            lin_w = in_w;
            lin_h = in_h;
            let mut hint2 = -1.0;
            if hint >= 0.0 {
                hint2 = gmax(0.0, hint - in_w);
            } else if w >= 0.0 {
                hint2 = gmax(0.0, w - in_w);
            } else if bx >= 0.0 {
                // Yoga AtMost: text lays out in the width the container has.
                hint2 = gmax(0.0, bx - in_w);
            }
            let intr = self.measure_call(i, hint2);
            // Unity clamps a leaf measure to the space the leaf has.
            let mut ix = d(intr.x);
            let mut iy = d(intr.y);
            if w < 0.0 {
                tx = ix;
            }
            if h < 0.0 {
                ty = iy;
            }
            if bx >= 0.0 {
                ix = f64::min(ix, gmax(0.0, bx - in_w));
            }
            if by >= 0.0 {
                iy = f64::min(iy, gmax(0.0, by - in_h));
            }
            bw = if w >= 0.0 { w } else { ix + in_w };
            bh = if h >= 0.0 { h } else { iy + in_h };
        } else {
            let mut cw = if w >= 0.0 { w - in_w } else { -1.0 };
            if cw < 0.0 && hint >= 0.0 {
                cw = gmax(0.0, hint - in_w);
            }
            let ch = if h >= 0.0 { h - in_h } else { -1.0 };
            let mut lx = cw;
            if lx < 0.0 && bx >= 0.0 {
                lx = gmax(0.0, bx - in_w);
            }
            let mut ly = ch;
            if ly < 0.0 && by >= 0.0 {
                ly = gmax(0.0, by - in_h);
            }
            let (nat, mtx, mty) = self.measure_content(i, Vector2::new(f(cw), f(ch)), lx, ly);
            // UxmlDocument._measure_leaf: a text control with children
            // measures nothing (Unity measures text on leaves only).
            let textish = self.io.labels[i].is_some() || self.io.rich[i].is_some() || self.io.buttons[i];
            let chrome = if textish { Vector2::ZERO } else { self.measure_call(i, cw) };
            bw = if w >= 0.0 { w } else { gmax(d(nat.x), d(chrome.x)) + in_w };
            bh = if h >= 0.0 { h } else { gmax(d(nat.y), d(chrome.y)) + in_h };
            if w < 0.0 && hint < 0.0 && mtx > NO_BOUND {
                tx = mtx + in_w;
            }
            if h < 0.0 && mty > NO_BOUND {
                ty = mty + in_h;
            }
        }
        let (mut bw, mut bh) = (bw, bh);
        let ar = self.ratio(i);
        if ar > 0.0 {
            tx = f64::INFINITY;
            ty = f64::INFINITY;
            if h >= 0.0 && w < 0.0 {
                bw = h * ar;
            } else if h < 0.0 {
                bh = bw / ar;
            }
        }
        let minw = self.min_or(i, P_MINW, d(avail.x), 0.0);
        let maxw = self.bound(i, P_MAXW, d(avail.x), false);
        let ox = gmax(gclamp(bw, minw, maxw), in_w);
        let minh = self.min_or(i, P_MINH, d(avail.y), 0.0);
        let maxh = self.bound(i, P_MAXH, d(avail.y), false);
        let mut oy = gmax(gclamp(bh, minh, maxh), in_h);
        let mut ox = ox;
        if !kids.is_empty() && self.str_(i, E_OVERFLOW, "visible") == "scroll" {
            if w < 0.0 && hint < 0.0 {
                tx = gmax(tx, ox);
            }
            if h < 0.0 {
                ty = gmax(ty, oy);
            }
        }
        if !kids.is_empty() && (bx >= 0.0 || by >= 0.0) && self.str_(i, E_OVERFLOW, "visible") == "scroll" {
            // Yoga: an auto-sized scroll box measured AtMost stays inside the
            // space it has on its cross axis; on its main axis only when the
            // box and one of its children grow.
            let row = self.is_row(i);
            let mut main_clamp = false;
            if self.num(i, P_GROW, 0.0) > 0.0 {
                for &k in kids.iter() {
                    if self.num(k, P_GROW, 0.0) > 0.0 {
                        main_clamp = true;
                        break;
                    }
                }
            }
            if bx >= 0.0 && w < 0.0 && hint < 0.0 && (main_clamp || !row) {
                ox = gmax(f64::min(ox, bx), in_w);
            }
            if by >= 0.0 && h < 0.0 && (main_clamp || row) {
                oy = gmax(f64::min(oy, by), in_h);
            }
        }
        let out = Vector2::new(f(ox), f(oy));
        let exit: Vec<f64> = vl.iter().map(|&v| self.vw[v]).collect();
        self.meas_m[i].push(MemoE { kx, ky, kh, bx, by, tx, ty, lin_w, lin_h, entry, out, exit });
        (out, tx, ty, lin_w, lin_h)
    }

    /// flex_layout.gd _measure_content: lx/ly bound the content (Yoga
    /// AtMost; -1 for none).
    fn measure_content(&mut self, i: usize, cavail: Vector2, lx: f64, ly: f64) -> (Vector2, f64, f64) {
        let kids = self.flex_children(i);
        if kids.is_empty() {
            return (Vector2::ZERO, NO_BOUND, NO_BOUND);
        }
        let row = self.is_row(i);
        let wrap = self.enum_(i, E_WRAP, &WRAPS, "nowrap") != "nowrap";
        let (main, cross) = if row { (0, 1) } else { (1, 0) };
        let comp = |v: Vector2, a: usize| if a == 0 { d(v.x) } else { d(v.y) };
        let gap_m = self.gap(i, if row { P_CGAP } else { P_RGAP }, comp(cavail, main));
        let gap_c = self.gap(i, if row { P_RGAP } else { P_CGAP }, comp(cavail, cross));
        let am = if row { lx } else { ly };
        let (mut lx, mut ly) = (lx, ly);
        // Yoga: a scroll container does not bound its children on its main axis.
        let sc = self.str_(i, E_OVERFLOW, "visible") == "scroll";
        if sc {
            if row {
                lx = -1.0;
            } else {
                ly = -1.0;
            }
        }
        let mut cx = NO_BOUND;
        let mut cy = NO_BOUND;
        let mut lines_main: Vec<f64> = vec![];
        let mut lines_cross: Vec<f64> = vec![];
        let (mut cur_main, mut cur_cross, mut cur_n) = (0.0f64, 0.0f64, 0usize);
        for &ch in kids.iter() {
            let m = self.margins(ch, d(cavail.x));
            let bxc = if lx < 0.0 { -1.0 } else { gmax(0.0, lx - m[L] - m[R]) };
            let byc = if ly < 0.0 { -1.0 } else { gmax(0.0, ly - m[T] - m[B]) };
            let (msz, ctx, cty, clw, clh) = self.measure_b(ch, cavail, -1.0, bxc, byc);
            let ex = ext(ctx, clw);
            if ex > NO_BOUND {
                cx = gmax(cx, ex + m[L] + m[R]);
            }
            let ey = ext(cty, clh);
            if ey > NO_BOUND {
                cy = gmax(cy, ey + m[T] + m[B]);
            }
            let (o_main, o_cross) = if row {
                (d(msz.x) + m[L] + m[R], d(msz.y) + m[T] + m[B])
            } else {
                (d(msz.y) + m[T] + m[B], d(msz.x) + m[L] + m[R])
            };
            if wrap && am >= 0.0 && cur_n > 0 && cur_main + gap_m + o_main > am + EPS {
                lines_main.push(cur_main);
                lines_cross.push(cur_cross);
                cur_main = 0.0;
                cur_cross = 0.0;
                cur_n = 0;
            }
            cur_main += (if cur_n > 0 { gap_m } else { 0.0 }) + o_main;
            cur_cross = gmax(cur_cross, o_cross);
            cur_n += 1;
        }
        if cur_n > 0 {
            lines_main.push(cur_main);
            lines_cross.push(cur_cross);
        }
        let mut out = [0.0f32; 2];
        for k in 0..lines_main.len() {
            out[main] = f(gmax(d(out[main]), lines_main[k]));
            out[cross] = f(d(out[cross]) + (lines_cross[k] + if k > 0 { gap_c } else { 0.0 }));
        }
        if wrap {
            if row {
                cx = gmax(cx, d(out[0]));
            } else {
                cy = gmax(cy, d(out[1]));
            }
        }
        if sc {
            if row {
                cx = NO_BOUND;
            } else {
                cy = NO_BOUND;
            }
        }
        (Vector2::new(out[0], out[1]), cx, cy)
    }

    /// flex_layout.gd _measure_b.
    fn measure_b(&mut self, i: usize, avail: Vector2, hint: f64, bx: f64, by: f64) -> (Vector2, f64, f64, f64, f64) {
        if (bx >= 0.0 || by >= 0.0) && self.vlist(i).is_empty() && !self.hint_sub(i) {
            let r = self.measure_t(i, avail, hint, -1.0, -1.0);
            if (bx < 0.0 || below(r.1, r.3, bx)) && (by < 0.0 || below(r.2, r.4, by)) {
                return r;
            }
        }
        self.measure_t(i, avail, hint, bx, by)
    }

    // ------------------------------------------------------------- arrange

    fn layout(&mut self, i: usize, rect: Rect2, cb: f64) {
        let mut entry: Option<Vec<f64>> = None;
        if self.xc.is_some() {
            let vl = self.vlist(i);
            if let (Some((_, sub, Some(prev))), Some(e)) = (&self.xc, &self.lay_c[i]) {
                if !sub[i]
                    && e.size == rect.size
                    && e.cb == cb
                    && e.entry.len() == vl.len()
                    && vl.iter().zip(e.entry.iter()).all(|(&v, &w)| self.vw[v] == w)
                {
                    let _p = crate::prof::scope("xc.layout_hit");
                    let prev: &Out = prev;
                    self.out.rects[i] = Some(rect);
                    self.out.cbs[i] = cb;
                    self.out.insets[i] = prev.insets[i];
                    self.out.content[i] = prev.content[i];
                    for j in i + 1..self.c.subtree_end(i) {
                        self.out.rects[j] = prev.raw[j];
                        self.out.content[j] = prev.content[j];
                        self.out.insets[j] = prev.insets[j];
                        self.out.cbs[j] = prev.cbs[j];
                    }
                    let exit = e.exit.clone();
                    for (k, &v) in vl.iter().enumerate() {
                        self.vw[v] = exit[k];
                    }
                    return;
                }
            }
            entry = Some(vl.iter().map(|&v| self.vw[v]).collect());
        }
        self.layout_inner(i, rect, cb);
        if let Some(entry) = entry {
            let vl = self.vlist(i);
            let exit = vl.iter().map(|&v| self.vw[v]).collect();
            self.lay_c[i] = Some(LayE { size: rect.size, cb, entry, exit });
        }
    }

    fn layout_inner(&mut self, i: usize, rect: Rect2, cb: f64) {
        self.out.rects[i] = Some(rect);
        self.out.cbs[i] = cb;
        let pad = self.padding(i, cb);
        let bor = self.borders(i);
        let start = Vector2::new(f(bor[L] + pad[L]), f(bor[T] + pad[T]));
        let end = Vector2::new(f(bor[R] + pad[R]), f(bor[B] + pad[B]));
        self.out.insets[i] = Some((start, end));
        let inner = Vector2::new(f(bor[L] + pad[L]), f(bor[T] + pad[T]));
        let content = Rect2::new(
            inner,
            Vector2::new(
                f(gmax(0.0, d(rect.size.x) - (pad[L] + pad[R] + bor[L] + bor[R]))),
                f(gmax(0.0, d(rect.size.y) - (pad[T] + pad[B] + bor[T] + bor[B]))),
            ),
        );
        let kids = self.flex_children(i);
        let abs = self.abs_children(i);
        if kids.is_empty() {
            self.out.content[i] = Some(Vector2::ZERO);
        } else {
            let ext = self.place(i, content, &kids[..]);
            self.out.content[i] = Some(ext);
        }
        if !abs.is_empty() {
            self.layout_abs(i, rect.size, pad, bor, &abs[..]);
        }
    }

    /// Yoga's single flex child (Unity's layout, measured: lay-shrink-wrap):
    /// in a container laid out at its size, the one child that grows and
    /// shrinks, when no flexible sibling follows it, has a flex basis of 0.
    /// Every child counts (display: none ones too); an absolute child is not
    /// flexible. Read from the records without diagnostics.
    fn single_flex(&self, i: usize) -> Option<usize> {
        let mut single: Option<usize> = None;
        let num = |ch: usize, pid: usize, dflt: f64| -> f64 {
            if self.recs[ch].kinds[pid] == K::Num { self.recs[ch].vals[pid] } else { dflt }
        };
        let mut ch = i + 1;
        let e = self.c.subtree_end(i);
        while ch < e {
            let next = self.c.subtree_end(ch);
            if !self.c.non_visual(ch) {
                let grow = num(ch, P_GROW, 0.0);
                let shrink = num(ch, P_SHRINK, 1.0);
                if single.is_some() {
                    let abs = self.recs[ch].enums[E_POSITION - NP].as_deref().map(str::trim) == Some("absolute");
                    if !abs && (grow != 0.0 || shrink != 0.0) {
                        return None;
                    }
                } else if grow > 0.0 && shrink > 0.0 {
                    single = Some(ch);
                }
            }
            ch = next;
        }
        single
    }

    fn place(&mut self, i: usize, area: Rect2, kids: &[usize]) -> Vector2 {
        let single = self.single_flex(i);
        let row = self.is_row(i);
        let wrap_mode = self.enum_(i, E_WRAP, &WRAPS, "nowrap");
        let justify = self.enum_(i, E_JUSTIFY, &JUSTIFY, "flex-start");
        let align_items = self.enum_(i, E_ALIGN_ITEMS, &ALIGN, "stretch");
        let align_content = self.enum_(i, E_ALIGN_CONTENT, &ALIGN_CONTENT, "flex-start");
        let (main, cross) = if row { (0usize, 1usize) } else { (1, 0) };
        let comp = |v: Vector2, a: usize| if a == 0 { d(v.x) } else { d(v.y) };
        let am = comp(area.size, main);
        let ac = comp(area.size, cross);
        let gap_m = self.gap(i, if row { P_CGAP } else { P_RGAP }, am);
        let gap_c = self.gap(i, if row { P_RGAP } else { P_CGAP }, ac);
        let size_prop = if row { P_W } else { P_H };
        let cross_prop = if row { P_H } else { P_W };
        let min_main = if row { P_MINW } else { P_MINH };
        let max_main = if row { P_MAXW } else { P_MAXH };
        let min_cross = if row { P_MINH } else { P_MINW };
        let max_cross = if row { P_MAXH } else { P_MAXW };
        let asx = d(area.size.x);
        let ms_i = if row { L } else { T };
        let me_i = if row { R } else { B };
        let cs_i = if row { T } else { L };
        let ce_i = if row { B } else { R };
        // Measure bounds (Yoga AtMost): the area less each item's margins; a
        // scroll container leaves its main axis unbounded.
        let sc = self.str_(i, E_OVERFLOW, "visible") == "scroll";
        let bnd_x = if sc && row { -1.0 } else { asx };
        let bnd_y = if sc && !row { -1.0 } else { d(area.size.y) };
        let bnd = |m: &Edges| -> (f64, f64) {
            (
                if bnd_x < 0.0 { -1.0 } else { gmax(0.0, bnd_x - m[L] - m[R]) },
                if bnd_y < 0.0 { -1.0 } else { gmax(0.0, bnd_y - m[T] - m[B]) },
            )
        };

        let n = kids.len();
        let mut it_m: Vec<Edges> = Vec::with_capacity(n);
        let mut it_main = vec![0.0f64; n];
        let mut it_min = vec![0.0f64; n];
        let mut it_max = vec![0.0f64; n];
        let mut it_inc = vec![0.0f64; n];
        let mut it_grow = vec![0.0f64; n];
        let mut it_shrink = vec![0.0f64; n];
        let mut it_frozen = vec![false; n];
        let mut it_cross = vec![0.0f64; n];
        let mut it_ncross = vec![0.0f64; n];
        let mut it_pos = vec![0.0f64; n];
        let mut it_cpos = vec![0.0f64; n];
        let mut it_mmain = vec![0.0f64; n];
        let mut it_mcross = vec![0.0f64; n];
        for k in 0..n {
            let ch = kids[k];
            let m = self.margins(ch, asx);
            let sh = self.stretch_hint(ch, row, align_items, ac, &m);
            let (bxc, byc) = bnd(&m);
            let nat = self.measure_b(ch, area.size, sh, bxc, byc).0;
            let basis = self.lenr(ch, P_BASIS, am);
            let hyp = if single == Some(ch) {
                0.0
            } else if !basis.is_nan() {
                basis
            } else {
                let explicit = self.dim(ch, size_prop, am);
                if explicit >= 0.0 { explicit } else { comp(nat, main) }
            };
            let mut mn = self.bound(ch, min_main, am, true);
            if mn < 0.0 {
                mn = 0.0;
            }
            let mut mx = self.bound(ch, max_main, am, false);
            let pads = self.padding(ch, asx);
            let bors = self.borders(ch);
            let (in_main, in_cross) = if row {
                (pads[L] + pads[R] + bors[L] + bors[R], pads[T] + pads[B] + bors[T] + bors[B])
            } else {
                (pads[T] + pads[B] + bors[T] + bors[B], pads[L] + pads[R] + bors[L] + bors[R])
            };
            mn = gmax(mn, in_main);
            mx = gmax(mx, mn);
            it_main[k] = gclamp(hyp, mn, mx);
            it_min[k] = mn;
            it_max[k] = mx;
            it_inc[k] = in_cross;
            it_grow[k] = gmax(0.0, self.num(ch, P_GROW, 0.0));
            it_shrink[k] = gmax(0.0, self.num(ch, P_SHRINK, 1.0));
            if row {
                it_mmain[k] = m[L] + m[R];
                it_mcross[k] = m[T] + m[B];
            } else {
                it_mmain[k] = m[T] + m[B];
                it_mcross[k] = m[L] + m[R];
            }
            it_m.push(m);
        }

        let mut line_lo: Vec<usize> = vec![];
        let mut line_hi: Vec<usize> = vec![];
        if wrap_mode == "nowrap" {
            line_lo.push(0);
            line_hi.push(n);
        } else {
            let mut start = 0;
            let mut cur_main = 0.0f64;
            for k in 0..n {
                let outer = it_main[k] + it_mmain[k];
                let mut need = (if k > start { gap_m } else { 0.0 }) + outer;
                if k > start && cur_main + need > am + EPS {
                    line_lo.push(start);
                    line_hi.push(k);
                    start = k;
                    cur_main = 0.0;
                    need = outer;
                }
                cur_main += need;
            }
            line_lo.push(start);
            line_hi.push(n);
        }
        let nlines = line_lo.len();
        for li in 0..nlines {
            flex_line(line_lo[li], line_hi[li], &mut it_main, &it_mmain, &it_min, &it_max, &it_grow, &it_shrink, &mut it_frozen, am, gap_m);
        }

        let mut l_cross = vec![0.0f64; nlines];
        let mut l_pos = vec![0.0f64; nlines];
        for li in 0..nlines {
            let mut line_cross = 0.0f64;
            for k in line_lo[li]..line_hi[li] {
                let ch = kids[k];
                let explicit = self.dim(ch, cross_prop, ac);
                let car = self.ratio(ch);
                // Yoga: an aspect ratio derives the cross size from the
                // main size, over an explicit cross dimension
                // (UxmlFlexLayout; measured: lay-minmax).
                let mut nat = if car > 0.0 {
                    if row { it_main[k] / car } else { it_main[k] * car }
                } else if explicit >= 0.0 {
                    explicit
                } else {
                    let (bxc, byc) = bnd(&it_m[k]);
                    let v = self.measure_b(ch, area.size, if row { it_main[k] } else { -1.0 }, bxc, byc).0;
                    comp(v, cross)
                };
                let cmin = gmax(self.min_or(ch, min_cross, ac, 0.0), it_inc[k]);
                let mxb = self.bound(ch, max_cross, ac, false);
                nat = gclamp(nat, cmin, gmax(mxb, cmin));
                it_ncross[k] = nat;
                line_cross = gmax(line_cross, nat + it_mcross[k]);
            }
            l_cross[li] = line_cross;
        }

        let mut lines_cross = 0.0f64;
        for li in 0..nlines {
            lines_cross += l_cross[li] + if li > 0 { gap_c } else { 0.0 };
        }
        if wrap_mode == "nowrap" && ac >= 0.0 {
            l_cross[0] = ac;
            lines_cross = ac;
        } else if wrap_mode != "nowrap" && ac >= 0.0 && align_content == "stretch" && ac > lines_cross {
            let extra = (ac - lines_cross) / nlines as f64;
            for li in 0..nlines {
                l_cross[li] += extra;
            }
            lines_cross = ac;
        }
        let free_c = if ac >= 0.0 { ac - lines_cross } else { 0.0 };
        let apos_cross = comp(area.position, cross);
        let mut cpos = apos_cross;
        let mut cstep = gap_c;
        match align_content {
            "center" => cpos += free_c / 2.0,
            "flex-end" => cpos += free_c,
            "space-between" => cstep += if nlines > 1 { free_c / (nlines - 1) as f64 } else { 0.0 },
            "space-around" => {
                let u = free_c / nlines as f64;
                cpos += u / 2.0;
                cstep += u;
            }
            "space-evenly" => {
                let u2 = free_c / (nlines + 1) as f64;
                cpos += u2;
                cstep += u2;
            }
            _ => {}
        }
        for li in 0..nlines {
            l_pos[li] = cpos;
            cpos += l_cross[li] + cstep;
        }
        if wrap_mode == "wrap-reverse" && ac >= 0.0 {
            for li in 0..nlines {
                l_pos[li] = apos_cross + ac - (l_pos[li] - apos_cross) - l_cross[li];
            }
        }

        let reverse = self.reverse_main(i);
        let apos_main = comp(area.position, main);
        for li in 0..nlines {
            let (lo, hi) = (line_lo[li], line_hi[li]);
            let cnt = hi - lo;
            let mut used = gap_m * gmax(0.0, cnt as f64 - 1.0);
            for k in lo..hi {
                used += it_main[k] + it_mmain[k];
            }
            let free = am - used;
            let mut start = 0.0f64;
            let mut step = gap_m;
            let mut nauto = 0usize;
            for k in lo..hi {
                let ak = &self.recs[kids[k]].kinds;
                if ak[P_MAR + ms_i] == K::AutoKw {
                    nauto += 1;
                }
                if ak[P_MAR + me_i] == K::AutoKw {
                    nauto += 1;
                }
            }
            if nauto > 0 {
                let per = gmax(0.0, free) / nauto as f64;
                let mut cur = apos_main;
                for k in lo..hi {
                    let ak = &self.recs[kids[k]].kinds;
                    if ak[P_MAR + ms_i] == K::AutoKw {
                        cur += per;
                    }
                    it_pos[k] = cur + it_m[k][ms_i];
                    cur += it_mmain[k] + it_main[k] + gap_m;
                    if ak[P_MAR + me_i] == K::AutoKw {
                        cur += per;
                    }
                }
            }
            if nauto == 0 { match justify {
                "center" => start = free / 2.0,
                "flex-end" => start = free,
                "space-between" => step += if cnt > 1 { free / (cnt - 1) as f64 } else { 0.0 },
                "space-around" => {
                    let u = free / cnt as f64;
                    start = u / 2.0;
                    step += u;
                }
                "space-evenly" => {
                    let u2 = free / (cnt + 1) as f64;
                    start = u2;
                    step += u2;
                }
                _ => {}
            }
            let mut cursor = apos_main + start;
            for k in lo..hi {
                it_pos[k] = cursor + it_m[k][ms_i];
                cursor += it_mmain[k] + it_main[k] + step;
            } }
            if reverse {
                for k in lo..hi {
                    let outer_start = it_pos[k] - it_m[k][ms_i];
                    let outer_len = it_mmain[k] + it_main[k];
                    it_pos[k] = 2.0 * apos_main + am - outer_start - outer_len + it_m[k][ms_i];
                }
            }
        }

        for li in 0..nlines {
            let lc = l_cross[li];
            let lp = l_pos[li];
            for k in line_lo[li]..line_hi[li] {
                let ch = kids[k];
                let mut al: &str = self.str_(ch, E_ALIGN_SELF, "auto");
                if al == "auto" {
                    al = align_items;
                }
                if !ALIGN.contains(&al) {
                    self.warn_once(ch, "align-self", format!("align-self: \"{al}\" is not supported; flex-start used"));
                    al = "flex-start";
                }
                if al == "baseline" {
                    self.warn_once(ch, "align-items", "baseline alignment is not supported; flex-start used".into());
                    al = "flex-start";
                }
                let mct = it_mcross[k];
                let ca_s = self.recs[ch].kinds[P_MAR + cs_i] == K::AutoKw;
                let ca_e = self.recs[ch].kinds[P_MAR + ce_i] == K::AutoKw;
                if ca_s || ca_e {
                    it_cross[k] = it_ncross[k];
                    let rem = gmax(0.0, lc - it_cross[k] - mct);
                    it_cpos[k] = if ca_s && ca_e {
                        lp + rem / 2.0 + it_m[k][cs_i]
                    } else if ca_s {
                        lp + rem + it_m[k][cs_i]
                    } else {
                        lp + it_m[k][cs_i]
                    };
                    continue;
                }
                if al == "stretch" && self.dim(ch, cross_prop, ac) < 0.0 && self.ratio(ch) <= 0.0 {
                    let smin = gmax(self.min_or(ch, min_cross, ac, 0.0), it_inc[k]);
                    let mxb = self.bound(ch, max_cross, ac, false);
                    it_cross[k] = gclamp(gmax(0.0, lc - mct), smin, gmax(mxb, smin));
                } else {
                    // A scroll box keeps inside its line through the measure
                    // bound (see measure).
                    it_cross[k] = it_ncross[k];
                }
                let mc_start = it_m[k][cs_i];
                let mc_end = it_m[k][ce_i];
                it_cpos[k] = match al {
                    "center" => lp + (lc - it_cross[k] - mct) / 2.0 + mc_start,
                    "flex-end" => lp + lc - it_cross[k] - mc_end,
                    _ => lp + mc_start,
                };
            }
        }

        let mut extent = [0.0f32; 2];
        for li in 0..nlines {
            for k in line_lo[li]..line_hi[li] {
                let mut pos = [0.0f32; 2];
                pos[main] = f(it_pos[k]);
                pos[cross] = f(it_cpos[k]);
                let mut size = [0.0f32; 2];
                size[main] = f(it_main[k]);
                size[cross] = f(it_cross[k]);
                let kd = &self.recs[kids[k]].kinds;
                let mut at = Vector2::new(pos[0], pos[1]);
                if kd[P_POS] != K::None || kd[P_POS + 1] != K::None || kd[P_POS + 2] != K::None || kd[P_POS + 3] != K::None {
                    at += self.rel_offset(kids[k], area.size);
                }
                self.layout(kids[k], Rect2::new(at, Vector2::new(size[0], size[1])), asx);
                let mend = it_m[k][me_i];
                let mcend = it_m[k][ce_i];
                extent[main] = f(gmax(d(extent[main]), d(pos[main]) + d(size[main]) + mend - apos_main));
                extent[cross] = f(gmax(d(extent[cross]), d(pos[cross]) + d(size[cross]) + mcend - apos_cross));
            }
        }
        Vector2::new(extent[0], extent[1])
    }
}

#[allow(clippy::too_many_arguments)]
fn flex_line(
    lo: usize,
    hi: usize,
    it_main: &mut [f64],
    it_mmain: &[f64],
    it_min: &[f64],
    it_max: &[f64],
    it_grow: &[f64],
    it_shrink: &[f64],
    it_frozen: &mut [bool],
    am: f64,
    gap_m: f64,
) {
    let cnt = hi - lo;
    for _ in 0..cnt + 1 {
        let mut used = gap_m * gmax(0.0, cnt as f64 - 1.0);
        for k in lo..hi {
            used += it_main[k] + it_mmain[k];
        }
        let free = am - used;
        if free.abs() < EPS {
            break;
        }
        let mut froze = false;
        if free > 0.0 {
            let mut gsum = 0.0;
            for k in lo..hi {
                if !it_frozen[k] {
                    gsum += it_grow[k];
                }
            }
            if gsum <= 0.0 {
                break;
            }
            let eff = if gsum >= 1.0 { free } else { free * gsum };
            for k in lo..hi {
                if it_frozen[k] || it_grow[k] <= 0.0 {
                    continue;
                }
                let target = it_main[k] + eff * it_grow[k] / gsum;
                if target > it_max[k] + EPS {
                    it_main[k] = it_max[k];
                    it_frozen[k] = true;
                    froze = true;
                } else if target < it_min[k] - EPS {
                    it_main[k] = it_min[k];
                    it_frozen[k] = true;
                    froze = true;
                } else {
                    it_main[k] = target;
                }
            }
        } else {
            let mut ssum = 0.0;
            for k in lo..hi {
                if !it_frozen[k] {
                    ssum += it_shrink[k] * it_main[k];
                }
            }
            if ssum <= 0.0 {
                break;
            }
            let eff = if ssum >= 1.0 { -free } else { -free * ssum };
            for k in lo..hi {
                if it_frozen[k] || it_shrink[k] <= 0.0 {
                    continue;
                }
                let target = it_main[k] - eff * it_shrink[k] * it_main[k] / ssum;
                if target < it_min[k] - EPS {
                    it_main[k] = it_min[k];
                    it_frozen[k] = true;
                    froze = true;
                } else if target > it_max[k] + EPS {
                    it_main[k] = it_max[k];
                    it_frozen[k] = true;
                    froze = true;
                } else {
                    it_main[k] = target;
                }
            }
        }
        if !froze {
            break;
        }
    }
}

/// Records for every element, rebuilt only where the cascade's layout
/// values changed (version per element).
#[derive(Default)]
pub struct RecCache {
    pub recs: Vec<Rec>,
    pub vers: Vec<u64>,
    /// The records that changed since the last take_changed().
    changed: Vec<bool>,
}

impl RecCache {
    /// Rebuilds the records whose layout values changed.
    pub fn refresh(&mut self, c: &Cascade) {
        let n = c.len();
        if self.recs.len() != n {
            self.recs = (0..n).map(|i| build_rec(c.layout_values(i))).collect();
            self.vers = (0..n).map(|i| c.layout_version(i)).collect();
            self.changed = vec![true; n];
            return;
        }
        if self.changed.len() != n {
            self.changed = vec![true; n];
        }
        for i in 0..n {
            let v = c.layout_version(i);
            if v != self.vers[i] {
                self.recs[i] = build_rec(c.layout_values(i));
                self.vers[i] = v;
                self.changed[i] = true;
            }
        }
    }

    /// Per element: its record changed since the last call (every refresh
    /// in between counts, the subtree layouts' included).
    pub fn take_changed(&mut self) -> Vec<bool> {
        let n = self.recs.len();
        std::mem::replace(&mut self.changed, vec![false; n])
    }
}

/// flex_layout.gd _abs_free.
/// UxmlStyleApplier.label_max_content: the longest paragraph of a Label as
/// one line, plus its stylebox margins, kept in the `uxml_maxc` meta for the
/// text.
fn label_max_content(l: &Gd<Label>, sn: &[StringName; 4]) -> f64 {
    let text = l.get_text();
    if l.has_meta(&sn[3]) {
        if let Ok(c) = l.get_meta(&sn[3]).try_to::<VarArray>() {
            let same = c.get(0).and_then(|v| v.try_to::<GString>().ok()).map(|v| v == text).unwrap_or(false);
            if same {
                if let Some(v) = c.get(1).and_then(|v| v.try_to::<f64>().ok()) {
                    return v;
                }
            }
        }
    }
    let mut font: Option<Gd<Font>> = l.get_theme_font(&sn[0]);
    let mut fs = l.get_theme_font_size(&sn[1]);
    if let Some(ls) = l.get_label_settings() {
        if let Some(lf) = ls.get_font() {
            font = Some(lf);
        }
        fs = ls.get_font_size();
    }
    let mut t = text.clone();
    if l.is_uppercase() {
        t = t.to_upper();
    }
    let mut w = 0.0f64;
    if let Some(fo) = font {
        if !t.is_empty() {
            w = d(fo.get_multiline_string_size_ex(&t).width(-1.0).font_size(fs).done().x);
        }
    }
    let sb = l.get_theme_stylebox(&sn[2]);
    let total = w + sb.map(|s| d(s.get_minimum_size().x)).unwrap_or(0.0);
    let mut arr = VarArray::new();
    arr.push(&text.to_variant());
    arr.push(&total.to_variant());
    let mut lm = l.clone();
    lm.set_meta(&sn[3], &arr.to_variant());
    total
}

/// UxmlStyleApplier.unfitted_height: one line of the font a fitted Label has
/// without the fit, plus its stylebox margins; kept in the same
/// `uxml_unfit` meta.
fn unfitted_height(l: &Gd<Label>, sn_unfit: &StringName) -> f64 {
    if l.has_meta(sn_unfit) {
        if let Ok(v) = l.get_meta(sn_unfit).try_to::<f64>() {
            return v;
        }
    }
    let mut base: Option<Gd<Font>> = l.get_theme_font("font");
    if l.has_meta("uxml_fit_base") {
        let keep = l.get_meta("uxml_fit_base").try_to::<VarArray>().ok();
        base = keep.and_then(|a| a.get(1)).and_then(|v| v.try_to::<Gd<Font>>().ok());
    }
    let fs = l.get_theme_font_size("font_size");
    let fh = base.map(|b| d(b.get_height_ex().font_size(fs).done())).unwrap_or(0.0);
    let sb = l.get_theme_stylebox("normal");
    let out = fh + sb.map(|s| d(s.get_minimum_size().y)).unwrap_or(0.0);
    let mut lm = l.clone();
    lm.set_meta(sn_unfit, &out.to_variant());
    out
}

/// UxmlDocument._hpad: the horizontal `uxml_margins` of the control's
/// normal stylebox.
fn hpad_of(m: Option<[f64; 4]>) -> f64 {
    match m {
        Some(m) => m[0] + m[2],
        None => 0.0,
    }
}

/// The `uxml_margins` meta of the control's normal stylebox override, if
/// both exist (UxmlDocument._measure_leaf / _hpad).
fn read_margins(c: &Gd<Control>, sn_normal: &StringName, sn_margins: &StringName) -> Option<[f64; 4]> {
    if c.has_theme_stylebox_override(sn_normal) {
        if let Some(sb) = c.get_theme_stylebox(sn_normal) {
            let sb: Gd<StyleBox> = sb;
            if sb.has_meta(sn_margins) {
                let a = sb.get_meta(sn_margins).to::<VarArray>();
                let g = |k: usize| a.at(k).try_to::<f64>().unwrap_or(0.0);
                return Some([g(0), g(1), g(2), g(3)]);
            }
        }
    }
    None
}

/// flex_layout.gd _ext.
fn ext(t: f64, lin: f64) -> f64 {
    if t <= NO_BOUND {
        return NO_BOUND;
    }
    if lin >= 0.0 { t + lin } else { t + 0.001 }
}

/// flex_layout.gd _below.
fn below(t: f64, lin: f64, b: f64) -> bool {
    if lin < 0.0 {
        return t <= b - 0.001;
    }
    t <= gmax(0.0, b - lin)
}

fn abs_free(mode: &str, reverse: bool, outer: f64, sz: f64, lead: f64) -> f64 {
    if mode == "center" {
        return (outer - sz) / 2.0;
    }
    let mut at_end = mode == "flex-end";
    if reverse {
        at_end = !at_end;
    }
    if at_end { outer - sz } else { lead }
}


// ------------------------------------------------------------- pixel grid

/// Yoga's RoundToPixelGrid at one pixel per point (UxmlFlexLayout.
/// round_to_pixel_grid): a position rounds on its own, a size is the
/// difference of the rounded absolute edges, children start from the
/// unrounded absolute position.
fn round_node(c: &Cascade, i: usize, abs_l: f64, abs_t: f64, src: &[Option<Rect2>], out: &mut [Option<Rect2>]) {
    let Some(r) = src[i] else { return };
    let left = d(r.position.x);
    let top = d(r.position.y);
    let al = abs_l + left;
    let at = abs_t + top;
    // Unity rounds a position from the absolute edges: the rounded
    // absolute position less the rounded absolute position of the parent.
    out[i] = Some(Rect2::new(
        Vector2::new(f(pixel(al) - pixel(abs_l)), f(pixel(at) - pixel(abs_t))),
        Vector2::new(f(pixel(al + d(r.size.x)) - pixel(al)), f(pixel(at + d(r.size.y)) - pixel(at))),
    ));
    for ch in c.children(i) {
        round_node(c, ch, al, at, src, out);
    }
}

/// A margin, padding or border width on the pixel grid (UxmlFlexLayout.
/// grid_box): margins and padding round to the nearest pixel, halves up; a
/// nonzero border is at least one pixel wide (measured in Unity).
fn grid_box(v: f64, border: bool) -> f64 {
    if border {
        if v <= 0.0 { 0.0 } else { gmax(1.0, pixel(v)) }
    } else {
        pixel(v)
    }
}

/// Yoga's roundValueToPixelGrid (no forced ceil/floor); C fmod semantics.
fn pixel(v: f64) -> f64 {
    let mut fr = v % 1.0;
    if fr < 0.0 {
        fr += 1.0;
    }
    if fr.abs() < 0.0001 {
        return v - fr;
    }
    if (fr - 1.0).abs() < 0.0001 {
        return v - fr + 1.0;
    }
    v - fr + if fr > 0.5 || (fr - 0.5).abs() < 0.0001 { 1.0 } else { 0.0 }
}
