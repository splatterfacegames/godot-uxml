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

use godot::classes::{Control, Label, Object, StyleBox};
use godot::prelude::*;

use crate::cascade::Cascade;

const EPS: f64 = 0.01;
pub const LAYOUT_PROPS: [&str; 35] = [
    "width", "height", "min-width", "min-height", "max-width", "max-height", "flex-basis",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "row-gap", "column-gap", "flex-grow", "flex-shrink",
    "top", "right", "bottom", "left",
    "display", "flex-direction", "flex-wrap", "justify-content", "align-items", "align-content", "align-self",
    "position",
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
const NP: usize = 27;
const E_DISPLAY: usize = 27;
const E_DIR: usize = 28;
const E_WRAP: usize = 29;
const E_JUSTIFY: usize = 30;
const E_ALIGN_ITEMS: usize = 31;
const E_ALIGN_CONTENT: usize = 32;
const E_ALIGN_SELF: usize = 33;
const E_POSITION: usize = 34;
const NE: usize = 8;
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
        if pid == P_GROW || pid == P_SHRINK {
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
    /// UxmlField wrappers (insets via set_content_insets).
    pub fields: Vec<bool>,
    /// TextureRect natives (Image elements: anchor offsets follow insets).
    pub texrects: Vec<Option<Gd<Control>>>,
}

/// Native placement state: the last layout and the insets last handed to
/// each control's inset hooks.
#[derive(Default)]
pub struct Placement {
    pub last: Option<Out>,
    hooked: Vec<Option<(Vector2, Vector2)>>,
}

impl Placement {
    /// UxmlDocument._place_control for element i. Inset hooks (UxmlField.
    /// set_content_insets / applier.apply_resolved_insets) are idempotent
    /// for unchanged insets on unchanged styleboxes, so they only run when
    /// the insets changed or the element was just re-applied (`force`).
    pub fn place(&mut self, io: &LayoutIn, i: usize, applier: &Option<Gd<Object>>, force: bool) {
        if i == 0 {
            return; // document root: the host box, never positioned
        }
        let Some(out) = &self.last else { return };
        let Some(mut c) = io.controls[i].clone() else { return };
        let Some(r) = out.rects[i] else { return };
        c.set_position(r.position);
        c.set_size(r.size);
        let Some((start, end)) = out.insets[i] else { return };
        if self.hooked.len() != io.controls.len() {
            self.hooked = vec![None; io.controls.len()];
        }
        let changed = force || self.hooked[i] != Some((start, end));
        if io.fields[i] {
            if changed {
                c.upcast::<Object>().call("set_content_insets", &[start.to_variant(), end.to_variant()]);
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

struct MemoE {
    kx: f64,
    ky: f64,
    kh: f64,
    entry: Vec<f64>,
    out: Vector2,
    exit: Vec<f64>,
}

pub struct Pass<'a> {
    c: &'a Cascade,
    io: &'a LayoutIn,
    recs: &'a [Rec],
    kinds: Vec<CtlKind>,
    sbw: f64,
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
    // volatile (wrapping label) emulation
    volatile: Vec<bool>,
    vw: Vec<f64>,
    vset: Vec<HashMap<u64, (f64, Vector2)>>,
    vread: Vec<HashMap<u64, Vector2>>,
    vl_m: Vec<Option<Rc<Vec<usize>>>>,
    sn_natural: StringName,
    sn_normal: StringName,
    sn_margins: StringName,
}

impl<'a> Pass<'a> {
    pub fn new(c: &'a Cascade, io: &'a LayoutIn, recs: &'a [Rec], sbw: f64, warned: VarDictionary, warnings: VarArray) -> Self {
        let n = c.len();
        let mut kinds = vec![CtlKind::None; n];
        let mut volatile = vec![false; n];
        let mut vw = vec![0.0; n];
        for i in 0..n {
            if let Some(ctl) = &io.controls[i] {
                kinds[i] = if io.boxed[i] { CtlKind::Boxed } else { CtlKind::Plain };
                if let Some(lbl) = &io.labels[i] {
                    if lbl.get_autowrap_mode() != godot::classes::text_server::AutowrapMode::OFF {
                        volatile[i] = true;
                        vw[i] = d(ctl.get_size().x);
                    }
                }
            }
        }
        Pass {
            c,
            io,
            recs,
            kinds,
            sbw,
            warned,
            warnings,
            out: Out { rects: vec![None; n], content: vec![None; n], insets: vec![None; n] },
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
            volatile,
            vw,
            vset: (0..n).map(|_| HashMap::new()).collect(),
            vread: (0..n).map(|_| HashMap::new()).collect(),
            vl_m: vec![None; n],
            sn_natural: StringName::from("natural_size"),
            sn_normal: StringName::from("normal"),
            sn_margins: StringName::from("uxml_margins"),
        }
    }

    pub fn run(mut self, host: Vector2) -> Out {
        self.layout(0, Rect2::new(Vector2::ZERO, host), d(host.x));
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
        dd.set("message", message.as_str());
        dd.set("file", &self.c.file());
        let (offset, line, column) = self.c.location(i);
        dd.set("offset", offset);
        dd.set("line", line);
        dd.set("column", column);
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
                let name = LAYOUT_PROPS[pid];
                self.warn_once(i, name, format!("{name}: auto is not supported; 0 used"));
                continue;
            }
            let r = self.lenr(i, pid, cb);
            if r.is_nan() {
                continue;
            } else if r < 0.0 && !allow_negative {
                let name = LAYOUT_PROPS[pid];
                self.warn_once(i, name, format!("{name}: negative values are invalid; 0 used"));
            } else {
                out[k] = r;
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
                K::Px => out[k] = gmax(0.0, self.recs[i].vals[pid]),
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
            if w < 0.0 || h < 0.0 {
                let nat = self.measure(ch, Vector2::new(f(cbw), f(cbh)), w);
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
        if self.flex_children(i).is_empty() {
            s |= 4;
        }
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
        let Some(c) = self.io.controls[i].clone() else { return Vector2::ZERO };
        if self.volatile[i] && content_w >= 0.0 {
            let mut s = c.get_size();
            s.x = f(content_w);
            let mut cm = c.clone();
            cm.set_size(s);
        }
        let mut ms = match self.kinds[i] {
            CtlKind::Boxed => c.clone().upcast::<Object>().get(&self.sn_natural).try_to::<Vector2>().unwrap_or(Vector2::ZERO),
            _ => c.get_combined_minimum_size(),
        };
        if self.margins_m[i].is_none() {
            let mut m: Option<[f64; 4]> = None;
            if c.has_theme_stylebox_override(&self.sn_normal) {
                if let Some(sb) = c.get_theme_stylebox(&self.sn_normal) {
                    let sb: Gd<StyleBox> = sb;
                    if sb.has_meta(&self.sn_margins) {
                        let a = sb.get_meta(&self.sn_margins).to::<VarArray>();
                        let g = |k: usize| a.at(k).try_to::<f64>().unwrap_or(0.0);
                        m = Some([g(0), g(1), g(2), g(3)]);
                    }
                }
            }
            self.margins_m[i] = Some(m);
        }
        if let Some(Some(m)) = self.margins_m[i] {
            ms.x = f(gmax(0.0, d(ms.x) - m[0] - m[2]));
            ms.y = f(gmax(0.0, d(ms.y) - m[1] - m[3]));
        }
        ms
    }

    fn measure_call(&mut self, i: usize, hint: f64) -> Vector2 {
        if !self.volatile[i] {
            return self.measure_leaf(i, hint);
        }
        if hint >= 0.0 {
            if let Some(&(actual, res)) = self.vset[i].get(&hint.to_bits()) {
                self.vw[i] = actual;
                return res;
            }
            let res = self.measure_leaf(i, hint);
            let actual = d(self.io.controls[i].as_ref().unwrap().get_size().x);
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

    fn measure(&mut self, i: usize, avail: Vector2, hint: f64) -> Vector2 {
        let sens = self.sens(i);
        let kx = if sens & 1 != 0 { d(avail.x) } else { 0.0 };
        let ky = if sens & 2 != 0 { d(avail.y) } else { 0.0 };
        let kh = if sens & 4 != 0 { hint } else { -1.0 };
        let vl = self.vlist(i);
        let entry: Vec<f64> = vl.iter().map(|&v| self.vw[v]).collect();
        for e in &self.meas_m[i] {
            if e.kx == kx && e.ky == ky && e.kh == kh && e.entry == entry {
                for (k, &v) in vl.iter().enumerate() {
                    self.vw[v] = e.exit[k];
                }
                return e.out;
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
        if kids.is_empty() {
            let mut hint2 = -1.0;
            if hint >= 0.0 {
                hint2 = gmax(0.0, hint - in_w);
            } else if w >= 0.0 {
                hint2 = gmax(0.0, w - in_w);
            }
            let intr = self.measure_call(i, hint2);
            bw = if w >= 0.0 { w } else { d(intr.x) + in_w };
            bh = if h >= 0.0 { h } else { d(intr.y) + in_h };
        } else {
            let cw = if w >= 0.0 { w - in_w } else { -1.0 };
            let ch = if h >= 0.0 { h - in_h } else { -1.0 };
            let nat = self.measure_content(i, Vector2::new(f(cw), f(ch)));
            let chrome = self.measure_call(i, cw);
            bw = if w >= 0.0 { w } else { gmax(d(nat.x), d(chrome.x)) + in_w };
            bh = if h >= 0.0 { h } else { gmax(d(nat.y), d(chrome.y)) + in_h };
        }
        let minw = self.min_or(i, P_MINW, d(avail.x), 0.0);
        let maxw = self.bound(i, P_MAXW, d(avail.x), false);
        let ox = gmax(gclamp(bw, minw, maxw), in_w);
        let minh = self.min_or(i, P_MINH, d(avail.y), 0.0);
        let maxh = self.bound(i, P_MAXH, d(avail.y), false);
        let oy = gmax(gclamp(bh, minh, maxh), in_h);
        let out = Vector2::new(f(ox), f(oy));
        let exit: Vec<f64> = vl.iter().map(|&v| self.vw[v]).collect();
        self.meas_m[i].push(MemoE { kx, ky, kh, entry, out, exit });
        out
    }

    fn measure_content(&mut self, i: usize, cavail: Vector2) -> Vector2 {
        let kids = self.flex_children(i);
        if kids.is_empty() {
            return Vector2::ZERO;
        }
        let row = self.is_row(i);
        let wrap = self.enum_(i, E_WRAP, &WRAPS, "nowrap") != "nowrap";
        let (main, cross) = if row { (0, 1) } else { (1, 0) };
        let comp = |v: Vector2, a: usize| if a == 0 { d(v.x) } else { d(v.y) };
        let gap_m = self.gap(i, if row { P_CGAP } else { P_RGAP }, comp(cavail, main));
        let gap_c = self.gap(i, if row { P_RGAP } else { P_CGAP }, comp(cavail, cross));
        let am = comp(cavail, main);
        let mut lines_main: Vec<f64> = vec![];
        let mut lines_cross: Vec<f64> = vec![];
        let (mut cur_main, mut cur_cross, mut cur_n) = (0.0f64, 0.0f64, 0usize);
        for &ch in kids.iter() {
            let msz = self.measure(ch, cavail, -1.0);
            let m = self.margins(ch, d(cavail.x));
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
        Vector2::new(out[0], out[1])
    }

    // ------------------------------------------------------------- arrange

    fn layout(&mut self, i: usize, rect: Rect2, cb: f64) {
        self.out.rects[i] = Some(rect);
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
        } else if self.c.is_scroll_view(i) {
            self.layout_scroll(i, content, pad, bor, &kids[..]);
        } else {
            let ext = self.place(i, content, &kids[..]);
            self.out.content[i] = Some(ext);
        }
        if !abs.is_empty() {
            self.layout_abs(i, rect.size, pad, bor, &abs[..]);
        }
    }

    fn layout_scroll(&mut self, i: usize, content: Rect2, pad: Edges, bor: Edges, kids: &[usize]) {
        let pad_bor = Vector2::new(f(pad[L] + bor[L]), f(pad[T] + bor[T]));
        let mut avail_w = d(content.size.x);
        let mut nat = self.measure_content(i, Vector2::new(f(avail_w), -1.0));
        if d(nat.y) > d(content.size.y) + EPS && self.sbw > 0.0 {
            avail_w = gmax(0.0, avail_w - self.sbw);
            nat = self.measure_content(i, Vector2::new(f(avail_w), -1.0));
        }
        let content_h = gmax(d(nat.y), d(content.size.y));
        let area = Rect2::new(pad_bor, Vector2::new(f(avail_w), f(content_h)));
        self.place(i, area, kids);
        self.out.content[i] = Some(Vector2::new(f(avail_w), nat.y) + pad_bor);
    }

    fn place(&mut self, i: usize, area: Rect2, kids: &[usize]) -> Vector2 {
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
            let nat = self.measure(ch, area.size, -1.0);
            let basis = self.lenr(ch, P_BASIS, am);
            let hyp = if !basis.is_nan() {
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
                let mut nat = if explicit >= 0.0 {
                    explicit
                } else {
                    let v = self.measure(ch, area.size, if row { it_main[k] } else { -1.0 });
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
            match justify {
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
            }
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
                if al == "stretch" && self.dim(ch, cross_prop, ac) < 0.0 {
                    let smin = gmax(self.min_or(ch, min_cross, ac, 0.0), it_inc[k]);
                    let mxb = self.bound(ch, max_cross, ac, false);
                    it_cross[k] = gclamp(gmax(0.0, lc - mct), smin, gmax(mxb, smin));
                } else {
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
}

impl RecCache {
    pub fn refresh(&mut self, c: &Cascade) {
        let n = c.len();
        if self.recs.len() != n {
            self.recs = (0..n).map(|i| build_rec(c.layout_values(i))).collect();
            self.vers = (0..n).map(|i| c.layout_version(i)).collect();
            return;
        }
        for i in 0..n {
            let v = c.layout_version(i);
            if v != self.vers[i] {
                self.recs[i] = build_rec(c.layout_values(i));
                self.vers[i] = v;
            }
        }
    }
}

/// flex_layout.gd _abs_free.
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
