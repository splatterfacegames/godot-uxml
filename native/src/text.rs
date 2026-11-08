//! `UxmlText`: the text of a plain Label element, drawn by the core.
//!
//! A port of Godot 4.7.1's Label (`scene/gui/label.cpp`: `_shape`,
//! `_update_visible`, `get_layout_data`, `_get_line_rect`,
//! `get_minimum_size`, `get_line_count`, `get_line_height` and the draw of
//! `NOTIFICATION_DRAW`) to TextServer calls, for left-to-right text without
//! visible-character limits, skipped lines or tab stops. It has the
//! properties of a Label that the runtime writes (`text`,
//! `horizontal_alignment`, `vertical_alignment`, `autowrap_mode`,
//! `autowrap_trim_flags`, `clip_text`, `text_overrun_behavior`, `uppercase`,
//! `label_settings`) under the same names, and it reads the theme items of
//! the `Label` theme type (its overrides first). It is a Control so that the
//! drawing order, clipping, modulation and visibility are those of the Label
//! it stands for; what it saves is a Label's work: a Label entering the tree
//! costs about 90 us and one of these about 30 (bench/prof/label_cost.gd).
//!
//! UxmlDocument makes one for a Label that nothing but the document reaches
//! (docs/design.md, "Core-drawn text"), and swaps a real Label in, with the
//! same state, when an API call hands out the control.
use std::cell::RefCell;

use godot::classes::notify::ControlNotification;
use godot::classes::text_server::{
    AutowrapMode, Direction, JustificationFlag, LineBreakFlag, OverrunBehavior, TextOverrunFlag,
};
use godot::classes::{
    Control, Font, IControl, LabelSettings, StyleBox, TextServer, TextServerManager, TranslationServer,
};
use godot::builtin::Side;
use godot::global::{HorizontalAlignment, VerticalAlignment};
use godot::prelude::*;

thread_local! {
    static TS: RefCell<Option<Gd<TextServer>>> = const { RefCell::new(None) };
}

fn ts() -> Gd<TextServer> {
    debug_assert!(LineBreakFlag::TRIM_START_EDGE_SPACES.ord() == 64 && LineBreakFlag::TRIM_END_EDGE_SPACES.ord() == 128);
    debug_assert!(JustificationFlag::SKIP_LAST_LINE.ord() == 32 && JustificationFlag::DO_NOT_SKIP_SINGLE_LINE.ord() == 128);
    TS.with(|t| {
        let mut t = t.borrow_mut();
        if t.is_none() {
            *t = TextServerManager::singleton().get_primary_interface();
        }
        t.clone().expect("text server")
    })
}

/// The theme type variation of every UxmlText: a variation of `Label` in
/// the default theme, so that a theme lookup without a type resolves the
/// items of a Label (Godot only follows variations that a theme declares).
const VARIATION: &str = "UxmlTextLabel";

pub fn ensure_variation() {
    thread_local! {
        static DONE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    if DONE.with(|d| d.get()) {
        return;
    }
    if let Some(mut th) = godot::classes::ThemeDb::singleton().get_default_theme() {
        if th.get_type_variation_base(VARIATION) != StringName::from("Label") {
            th.set_type_variation(VARIATION, "Label");
        }
        DONE.with(|d| d.set(true));
    }
}

/// Drop the cached text server (extension shutdown).
pub fn clear_cache() {
    TS.with(|t| *t.borrow_mut() = None);
    NAMES.with(|n| *n.borrow_mut() = None);
}

/// The theme item names of a Label.
#[derive(Clone)]
struct Names {

    normal: StringName,
    focus: StringName,
    line_spacing: StringName,
    paragraph_spacing: StringName,
    font: StringName,
    font_size: StringName,
    font_color: StringName,
    font_shadow_color: StringName,
    shadow_offset_x: StringName,
    shadow_offset_y: StringName,
    font_outline_color: StringName,
    outline_size: StringName,
    shadow_outline_size: StringName,
}

thread_local! {
    static NAMES: RefCell<Option<Names>> = const { RefCell::new(None) };
}

fn names() -> Names {
    NAMES.with(|n| {
        let mut n = n.borrow_mut();
        if n.is_none() {
            *n = Some(Names::new());
        }
        n.as_ref().unwrap().clone()
    })
}

impl Names {
    fn new() -> Self {
        Names {
        normal: StringName::from("normal"),
        focus: StringName::from("focus"),
        line_spacing: StringName::from("line_spacing"),
        paragraph_spacing: StringName::from("paragraph_spacing"),
        font: StringName::from("font"),
        font_size: StringName::from("font_size"),
        font_color: StringName::from("font_color"),
        font_shadow_color: StringName::from("font_shadow_color"),
        shadow_offset_x: StringName::from("shadow_offset_x"),
        shadow_offset_y: StringName::from("shadow_offset_y"),
        font_outline_color: StringName::from("font_outline_color"),
        outline_size: StringName::from("outline_size"),
        shadow_outline_size: StringName::from("shadow_outline_size"),
        }
    }
}

struct Para {
    rid: Rid,
    text: GString,
    lines: Vec<Rid>,
    dirty: bool,
    lines_dirty: bool,
}

#[derive(Clone)]
struct Theme {
    normal: Gd<StyleBox>,
    focus: Option<Gd<StyleBox>>,
    line_spacing: i32,
    paragraph_spacing: i32,
    font: Gd<Font>,
    font_size: i32,
    font_color: Color,
    shadow_color: Color,
    shadow_ofs: Vector2,
    outline_color: Color,
    outline_size: i32,
    shadow_outline_size: i32,
}

#[derive(Default)]
struct State {
    paras: Vec<Para>,
    text_dirty: bool,
    font_dirty: bool,
    dirty: bool,
    minsize: Vector2,
    total_lines: usize,
    theme: Option<Theme>,
    /// The font and size the paragraphs were shaped with, and the width
    /// their lines were broken at (-1: not yet).
    shaped_font: Option<(Gd<Font>, i32)>,
    shaped_width: i32,
    /// A resize since the last shape (of text whose breaks follow the width).
    resized: bool,
    /// A theme change since the last shape.
    theme_new: bool,
}

/// Font, size and spacings after the LabelSettings, as Label reads them.
struct Eff {
    font: Gd<Font>,
    size: i32,
    font_h: i32,
    line_spacing: i32,
    paragraph_spacing: i32,
}

#[derive(GodotClass)]
#[class(base = Control)]
pub struct UxmlText {
    base: Base<Control>,
    #[var(get = get_text, set = set_text)]
    text: GString,
    xl_text: GString,
    #[var(get = get_horizontal_alignment, set = set_horizontal_alignment)]
    horizontal_alignment: i32,
    #[var(get = get_vertical_alignment, set = set_vertical_alignment)]
    vertical_alignment: i32,
    #[var(get = get_autowrap_mode, set = set_autowrap_mode)]
    autowrap_mode: i32,
    #[var(get = get_autowrap_trim_flags, set = set_autowrap_trim_flags)]
    autowrap_trim_flags: i32,
    #[var(get = is_clipping_text, set = set_clip_text)]
    clip_text: bool,
    #[var(get = get_text_overrun_behavior, set = set_text_overrun_behavior)]
    text_overrun_behavior: i32,
    #[var(get = is_uppercase, set = set_uppercase)]
    uppercase: bool,
    #[var(get = get_label_settings, set = set_label_settings)]
    label_settings: Option<Gd<LabelSettings>>,
    /// Control.TextDirection (3: inherited).
    #[var(get = get_text_direction, set = set_text_direction)]
    text_direction: i32,
    /// Kept for the copies that read it (UxmlTextShadow); only -1 (all) is
    /// drawn.
    #[var]
    visible_characters: i32,
    st: RefCell<State>,
}

/// BREAK_TRIM_START_EDGE_SPACES | BREAK_TRIM_END_EDGE_SPACES (Label's default).
const DEFAULT_TRIM: i32 = 64 | 128;
/// BREAK_TRIM_MASK: the trim flags of a Label.
const TRIM_MASK: i32 = 16 | 32 | 64 | 128;
/// WORD_BOUND | KASHIDA | SKIP_LAST_LINE | DO_NOT_SKIP_SINGLE_LINE (Label's jst_flags).
const JST_DEFAULT: u64 = 2 | 1 | 32 | 128;

#[godot_api]
impl IControl for UxmlText {
    fn init(base: Base<Control>) -> Self {
        // Label's constructor; and every get_theme_* without a type (this
        // class's and the runtime's) resolves the items of a Label.
        {
            let mut g = base.to_init_gd();
            g.set_mouse_filter(godot::classes::control::MouseFilter::IGNORE);
            g.set_v_size_flags(godot::classes::control::SizeFlags::SHRINK_CENTER);
            ensure_variation();
            g.set_theme_type_variation(VARIATION);
        }
        Self {
            base,
            text: GString::new(),
            xl_text: GString::new(),
            horizontal_alignment: 0,
            vertical_alignment: 0,
            autowrap_mode: 0,
            autowrap_trim_flags: DEFAULT_TRIM,
            clip_text: false,
            text_overrun_behavior: 0,
            uppercase: false,
            label_settings: None,
            text_direction: 3,
            visible_characters: -1,
            st: RefCell::new(State { text_dirty: true, font_dirty: true, dirty: true, shaped_width: -1, ..Default::default() }),
        }
    }

    fn get_minimum_size(&self) -> Vector2 {
        let _p = crate::prof::scope("tx.min");
        self.ensure_shaped();
        let th = self.theme();
        let e = self.eff(&th);
        let mut min = self.st.borrow().minsize;
        min.y = min.y.max(e.font.get_height_ex().font_size(e.size).done());
        let ms = th.normal.get_minimum_size();
        if self.autowrap_mode != 0 {
            if self.clip_text || self.text_overrun_behavior != 0 {
                min.y = 1.0;
            }
            Vector2::new(1.0, min.y) + ms
        } else {
            if self.clip_text || self.text_overrun_behavior != 0 {
                min.x = 1.0;
            }
            min + ms
        }
    }

    fn draw(&mut self) {
        self.draw_text();
    }

    fn on_notification(&mut self, what: ControlNotification) {
        let _p = crate::prof::scope("tx.notif");
        match what {
            ControlNotification::THEME_CHANGED => {
                // The theme is read again; the paragraphs are shaped again
                // when the font or the size changed (shape(): Label shapes
                // again at every theme change, with the same result).
                // As Label (Control::_update_theme_item_cache): the items are
                // read now, and kept until the next theme change; overrides
                // written in between are not seen until then.
                let th = self.read_theme(false);
                {
                    let mut st = self.st.borrow_mut();
                    st.theme = Some(th);
                    st.theme_new = true;
                }
                self.base_mut().queue_redraw();
                // Control's own handler measured the control before this one
                // ran (with the items of before): measure again.
                self.base_mut().update_minimum_size();
            }
            ControlNotification::RESIZED => {
                // Label breaks the lines again at every resize; only the
                // breaks of wrapping, trimmed or filled text follow the
                // width (shape() compares it).
                if self.autowrap_mode != 0 || self.text_overrun_behavior != 0 || self.horizontal_alignment == HorizontalAlignment::FILL.ord() {
                    self.st.borrow_mut().resized = true;
                }
            }
            ControlNotification::TRANSLATION_CHANGED => {
                let t = self.text.clone();
                self.xl_text = self.base().atr(&t);
                self.st.borrow_mut().text_dirty = true;
                self.base_mut().queue_redraw();
            }
            ControlNotification::LAYOUT_DIRECTION_CHANGED => {
                self.base_mut().queue_redraw();
            }
            ControlNotification::PREDELETE => {
                self.free_paras();
            }
            _ => {}
        }
    }
}

#[godot_api]
impl UxmlText {
    #[func]
    fn set_text(&mut self, t: GString) {
        if self.text == t {
            return;
        }
        self.xl_text = self.base().atr(&t);
        self.text = t;
        self.st.borrow_mut().text_dirty = true;
        self.base_mut().queue_redraw();
        self.base_mut().update_minimum_size();
    }

    #[func]
    fn set_text_direction(&mut self, d: i32) {
        if self.text_direction == d {
            return;
        }
        self.text_direction = d;
        self.st.borrow_mut().font_dirty = true;
        self.base_mut().queue_redraw();
    }

    #[func]
    fn get_text_direction(&self) -> i32 {
        self.text_direction
    }

    #[func]
    fn get_text(&self) -> GString {
        self.text.clone()
    }

    #[func]
    fn set_horizontal_alignment(&mut self, a: i32) {
        if self.horizontal_alignment == a {
            return;
        }
        let fill = a == HorizontalAlignment::FILL.ord() || self.horizontal_alignment == HorizontalAlignment::FILL.ord();
        self.horizontal_alignment = a;
        if fill {
            for p in self.st.borrow_mut().paras.iter_mut() {
                p.lines_dirty = true;
            }
        }
        self.base_mut().queue_redraw();
    }

    #[func]
    fn get_horizontal_alignment(&self) -> i32 {
        self.horizontal_alignment
    }

    #[func]
    fn set_vertical_alignment(&mut self, a: i32) {
        if self.vertical_alignment == a {
            return;
        }
        self.vertical_alignment = a;
        self.base_mut().queue_redraw();
    }

    #[func]
    fn get_vertical_alignment(&self) -> i32 {
        self.vertical_alignment
    }

    #[func]
    fn set_autowrap_mode(&mut self, m: i32) {
        if self.autowrap_mode == m {
            return;
        }
        self.autowrap_mode = m;
        for p in self.st.borrow_mut().paras.iter_mut() {
            p.lines_dirty = true;
        }
        self.base_mut().queue_redraw();
        self.base_mut().update_minimum_size();
    }

    #[func]
    fn get_autowrap_mode(&self) -> i32 {
        self.autowrap_mode
    }

    #[func]
    fn set_autowrap_trim_flags(&mut self, f: i32) {
        let f = f & TRIM_MASK;
        if self.autowrap_trim_flags == f {
            return;
        }
        self.autowrap_trim_flags = f;
        for p in self.st.borrow_mut().paras.iter_mut() {
            p.lines_dirty = true;
        }
        self.base_mut().queue_redraw();
        self.base_mut().update_minimum_size();
    }

    #[func]
    fn get_autowrap_trim_flags(&self) -> i32 {
        self.autowrap_trim_flags
    }

    #[func]
    fn set_clip_text(&mut self, c: bool) {
        if self.clip_text == c {
            return;
        }
        self.clip_text = c;
        self.base_mut().queue_redraw();
        self.base_mut().update_minimum_size();
    }

    #[func]
    fn is_clipping_text(&self) -> bool {
        self.clip_text
    }

    #[func]
    fn set_text_overrun_behavior(&mut self, b: i32) {
        if self.text_overrun_behavior == b {
            return;
        }
        self.text_overrun_behavior = b;
        for p in self.st.borrow_mut().paras.iter_mut() {
            p.lines_dirty = true;
        }
        self.base_mut().queue_redraw();
        if self.clip_text || self.text_overrun_behavior != 0 {
            self.base_mut().update_minimum_size();
        }
    }

    #[func]
    fn get_text_overrun_behavior(&self) -> i32 {
        self.text_overrun_behavior
    }

    #[func]
    fn set_uppercase(&mut self, u: bool) {
        if self.uppercase == u {
            return;
        }
        self.uppercase = u;
        self.st.borrow_mut().text_dirty = true;
        self.base_mut().queue_redraw();
    }

    #[func]
    fn is_uppercase(&self) -> bool {
        self.uppercase
    }

    #[func]
    fn set_label_settings(&mut self, s: Option<Gd<LabelSettings>>) {
        if self.label_settings == s {
            return;
        }
        let cb = self.to_gd().callable("_settings_changed");
        if let Some(mut old) = self.label_settings.take() {
            if old.is_connected("changed", &cb) {
                old.disconnect("changed", &cb);
            }
        }
        if let Some(mut new) = s.clone() {
            new.connect("changed", &cb);
        }
        self.label_settings = s;
        self.settings_changed();
    }

    #[func]
    fn get_label_settings(&self) -> Option<Gd<LabelSettings>> {
        self.label_settings.clone()
    }

    #[func]
    fn _settings_changed(&mut self) {
        self.settings_changed();
    }

    /// Label.get_line_count(): 1 outside the tree.
    #[func]
    fn get_line_count(&self) -> i32 {
        if !self.base().is_inside_tree() {
            return 1;
        }
        self.ensure_shaped();
        self.st.borrow().total_lines as i32
    }

    #[func]
    fn get_visible_line_count(&self) -> i32 {
        let th = self.theme();
        let st = self.st.borrow();
        self.visible_lines(&st, &th)
    }

    /// Label.get_line_height(p_line = -1).
    #[func]
    fn get_line_height(&self, line: i32) -> i32 {
        let th = self.theme();
        let e = self.eff(&th);
        let st = self.st.borrow();
        self.line_height(&st, &e, line)
    }

    // The properties, under the names of a Label's.
    #[func]
    fn _uxml_text_props() -> PackedStringArray {
        PackedStringArray::from(&[
            GString::from("text"),
            GString::from("horizontal_alignment"),
            GString::from("vertical_alignment"),
            GString::from("autowrap_mode"),
            GString::from("autowrap_trim_flags"),
            GString::from("clip_text"),
            GString::from("text_overrun_behavior"),
            GString::from("uppercase"),
            GString::from("label_settings"),
        ])
    }
}

impl UxmlText {
    pub fn text_ref(&self) -> &GString {
        &self.text
    }

    pub fn autowrap(&self) -> i32 {
        self.autowrap_mode
    }

    pub fn settings(&self) -> Option<Gd<LabelSettings>> {
        self.label_settings.clone()
    }

    pub fn upper(&self) -> bool {
        self.uppercase
    }

    fn settings_changed(&mut self) {
        self.st.borrow_mut().font_dirty = true;
        self.base_mut().queue_redraw();
        self.base_mut().update_minimum_size();
    }

    fn free_paras(&self) {
        let mut st = self.st.borrow_mut();
        if st.paras.is_empty() {
            return;
        }
        let mut t = ts();
        for p in st.paras.drain(..) {
            for l in p.lines {
                t.free_rid(l);
            }
            t.free_rid(p.rid);
        }
    }

    /// The theme items of the Label theme type, overrides first.
    fn theme(&self) -> Theme {
        if let Some(t) = &self.st.borrow().theme {
            return t.clone();
        }
        // Before the first theme change: the items of a new Label (its
        // theme cache at construction: the Label theme type, no overrides).
        let t = self.read_theme(true);
        self.st.borrow_mut().theme = Some(t.clone());
        t
    }

    fn read_theme(&self, initial: bool) -> Theme {
        let _p = crate::prof::scope("tx.theme");
        let n = names();
        let lbl = StringName::from("Label");
        let t = {
            let n = &n;
            let b = self.base();
            let lbl = &lbl;
            let sb = |x: &StringName| -> Option<Gd<StyleBox>> {
                if initial { b.get_theme_stylebox_ex(x).theme_type(lbl).done() } else { b.get_theme_stylebox(x) }
            };
            let k = |x: &StringName| -> i32 {
                if initial { b.get_theme_constant_ex(x).theme_type(lbl).done() } else { b.get_theme_constant(x) }
            };
            let c = |x: &StringName| -> Color {
                if initial { b.get_theme_color_ex(x).theme_type(lbl).done() } else { b.get_theme_color(x) }
            };
            let font = if initial { b.get_theme_font_ex(&n.font).theme_type(lbl).done() } else { b.get_theme_font(&n.font) };
            let font_size = if initial {
                b.get_theme_font_size_ex(&n.font_size).theme_type(lbl).done()
            } else {
                b.get_theme_font_size(&n.font_size)
            };
            Theme {
                normal: sb(&n.normal).unwrap_or_else(|| godot::classes::StyleBoxEmpty::new_gd().upcast()),
                focus: sb(&n.focus),
                line_spacing: k(&n.line_spacing),
                paragraph_spacing: k(&n.paragraph_spacing),
                font: font.expect("Label font"),
                font_size,
                font_color: c(&n.font_color),
                shadow_color: c(&n.font_shadow_color),
                shadow_ofs: Vector2::new(k(&n.shadow_offset_x) as f32, k(&n.shadow_offset_y) as f32),
                outline_color: c(&n.font_outline_color),
                outline_size: k(&n.outline_size),
                shadow_outline_size: k(&n.shadow_outline_size),
            }
        };
        t
    }

    fn eff(&self, th: &Theme) -> Eff {
        let (font, size, ls, ps) = match &self.label_settings {
            Some(s) => (
                s.get_font().unwrap_or_else(|| th.font.clone()),
                s.get_font_size(),
                s.get_line_spacing() as i32,
                s.get_paragraph_spacing() as i32,
            ),
            None => (th.font.clone(), th.font_size, th.line_spacing, th.paragraph_spacing),
        };
        let font_h = font.get_height_ex().font_size(size).done() as i32;
        Eff { font, size, font_h, line_spacing: ls, paragraph_spacing: ps }
    }

    fn asc_dsc(t: &Gd<TextServer>, rid: Rid, font_h: i32) -> (f64, f64) {
        let mut asc = t.shaped_text_get_ascent(rid);
        let mut dsc = t.shaped_text_get_descent(rid);
        if asc + dsc < font_h as f64 {
            let diff = font_h as f64 - (asc + dsc);
            asc += diff / 2.0;
            dsc += diff - (diff / 2.0);
        }
        (asc, dsc)
    }

    fn line_height(&self, st: &State, e: &Eff, line: i32) -> i32 {
        let t = ts();
        if line >= 0 && (line as usize) < st.total_lines {
            let mut k = line as usize;
            for p in &st.paras {
                if k < p.lines.len() {
                    let (a, d) = Self::asc_dsc(&t, p.lines[k], e.font_h);
                    return (a + d) as i32;
                }
                k -= p.lines.len();
            }
            0
        } else if st.total_lines > 0 {
            let mut h = e.font_h as f32;
            for p in &st.paras {
                for &l in &p.lines {
                    h = h.max(t.shaped_text_get_size(l).y);
                }
            }
            h as i32
        } else {
            e.font_h
        }
    }

    fn ensure_shaped(&self) {
        let need = {
            let st = self.st.borrow();
            st.dirty || st.font_dirty || st.text_dirty || st.resized || st.theme_new
                || st.paras.iter().any(|p| p.lines_dirty || p.dirty)
        };
        if need {
            self.shape();
        }
    }

    fn visible_lines(&self, st: &State, th: &Theme) -> i32 {
        let e = self.eff(th);
        let t = ts();
        let h = self.base().get_size().y;
        let limit = (h - th.normal.get_minimum_size().y + e.line_spacing as f32).ceil();
        let mut total_h: f32 = 0.0;
        let mut vis = 0;
        for p in &st.paras {
            for &l in &p.lines {
                let (a, d) = Self::asc_dsc(&t, l, e.font_h);
                total_h = (total_h as f64 + (a + d + e.line_spacing as f64)) as f32;
                if total_h > limit {
                    break;
                }
                vis += 1;
            }
            total_h += e.paragraph_spacing as f32;
        }
        vis
    }

    fn shape(&self) {
        let _p = crate::prof::scope("tx.shape");
        let mut t = ts();
        let th = self.theme();
        let e = self.eff(&th);
        let lang = TranslationServer::singleton().get_locale();
        let style_min = th.normal.get_minimum_size();
        let (size, maxw, rtl) = {
            let b = self.base();
            (b.get_size(), b.get_combined_maximum_size().x, b.is_layout_rtl())
        };
        let mut width = (size.x - style_min.x) as i32;
        let wrap_max = self.autowrap_mode != 0 && maxw > 0.0;
        let mut maximum_width = -1;
        if wrap_max {
            maximum_width = (maxw - style_min.x) as i32;
            if maximum_width <= 0 {
                maximum_width = 1;
            }
            width = maximum_width;
        }
        let mut st = self.st.borrow_mut();
        st.theme_new = false;
        let fkey = (e.font.clone(), e.size);
        if st.shaped_font.as_ref() != Some(&fkey) {
            st.font_dirty = true;
        }
        if st.resized {
            st.resized = false;
            if st.shaped_width != width {
                for p in st.paras.iter_mut() {
                    p.lines_dirty = true;
                }
            }
        }
        if st.text_dirty {
            for p in st.paras.drain(..) {
                for l in p.lines {
                    t.free_rid(l);
                }
                t.free_rid(p.rid);
            }
            let txt = if self.uppercase {
                t.string_to_upper_ex(&self.xl_text).language(&lang).done()
            } else {
                self.xl_text.clone()
            };
            let s = txt.to_string();
            for part in s.split('\n') {
                let rid = t.create_shaped_text();
                st.paras.push(Para {
                    rid,
                    text: GString::from(format!("{}\u{200B}", part).as_str()),
                    lines: vec![],
                    dirty: true,
                    lines_dirty: true,
                });
            }
            st.text_dirty = false;
        }
        let font_dirty = st.font_dirty;
        let rids = e.font.get_rids();
        let feats = e.font.get_opentype_features();
        let mut flags = LineBreakFlag::MANDATORY.ord();
        match self.autowrap_mode {
            x if x == AutowrapMode::WORD_SMART.ord() => {
                flags = LineBreakFlag::WORD_BOUND.ord() | LineBreakFlag::ADAPTIVE.ord() | LineBreakFlag::MANDATORY.ord()
            }
            x if x == AutowrapMode::WORD.ord() => flags = LineBreakFlag::WORD_BOUND.ord() | LineBreakFlag::MANDATORY.ord(),
            x if x == AutowrapMode::ARBITRARY.ord() => {
                flags = LineBreakFlag::GRAPHEME_BOUND.ord() | LineBreakFlag::MANDATORY.ord()
            }
            _ => {}
        }
        flags |= self.autowrap_trim_flags as u64;
        let mut total = 0;
        for p in st.paras.iter_mut() {
            if p.dirty || font_dirty {
                if p.dirty {
                    t.shaped_text_clear(p.rid);
                }
                let dir = if self.text_direction == 3 {
                    if rtl { Direction::RTL } else { Direction::LTR }
                } else {
                    Direction::from_ord(self.text_direction)
                };
                t.shaped_text_set_direction_ex(p.rid).direction(dir).done();
                if p.dirty {
                    t.shaped_text_add_string_ex(p.rid, &p.text, &rids, e.size as i64)
                        .opentype_features(&feats)
                        .language(&lang)
                        .done();
                } else {
                    let spans = t.shaped_get_span_count(p.rid);
                    for i in 0..spans {
                        t.shaped_set_span_update_font_ex(p.rid, i, &rids, e.size as i64)
                            .opentype_features(&feats)
                            .done();
                    }
                }
                p.dirty = false;
                p.lines_dirty = true;
            }
            if p.lines_dirty {
                for &l in &p.lines {
                    t.free_rid(l);
                }
                p.lines.clear();
                let lb = t
                    .shaped_text_get_line_breaks_ex(p.rid, width as f64)
                    .start(0)
                    .break_flags(LineBreakFlag::from_ord(flags))
                    .done();
                let lb = lb.as_slice();
                let mut i = 0;
                while i + 1 < lb.len() {
                    p.lines.push(t.shaped_text_substr(p.rid, lb[i] as i64, (lb[i + 1] - lb[i]) as i64));
                    i += 2;
                }
            }
            total += p.lines.len();
        }
        st.total_lines = total;
        st.dirty = false;
        st.font_dirty = false;
        st.shaped_font = Some(fkey);
        st.shaped_width = width;

        if self.xl_text.is_empty() {
            let h = self.line_height(&st, &e, -1);
            st.minsize = Vector2::new(1.0, h as f32);
            return;
        }

        let visible = self.visible_lines(&st, &th);
        let lines_hidden = visible > 0 && (visible as usize) < total;
        let mut line_index: i32 = 0;
        if self.autowrap_mode == 0 || wrap_max {
            st.minsize.x = 0.0;
        }
        let ell = 0x2026;
        let fill = self.horizontal_alignment == HorizontalAlignment::FILL.ord();
        let jst = JST_DEFAULT;
        let mut minw = st.minsize.x;
        for p in st.paras.iter_mut() {
            if self.autowrap_mode == 0 {
                for &l in &p.lines {
                    let w = t.shaped_text_get_size(l).x;
                    if minw < w {
                        minw = w;
                    }
                }
            } else if wrap_max {
                minw = minw.max(t.shaped_text_get_size(p.rid).x);
            }
            if p.lines_dirty {
                let mut of = overrun_flags(self.text_overrun_behavior);
                let n = p.lines.len() as i32;
                if self.autowrap_mode != 0 {
                    if lines_hidden {
                        of |= TextOverrunFlag::ENFORCE_ELLIPSIS.ord();
                    }
                    if fill {
                        let to = jst_to(&t, &p.lines, jst);
                        for i in 0..n {
                            if i < to {
                                t.shaped_text_fit_to_width_ex(p.lines[i as usize], width as f64)
                                    .justification_flags(JustificationFlag::from_ord(jst))
                                    .done();
                            } else if i == visible - line_index - 1 {
                                t.shaped_text_set_custom_ellipsis(p.lines[i as usize], ell);
                                t.shaped_text_overrun_trim_to_width_ex(p.lines[i as usize])
                                    .width(width as f64)
                                    .overrun_trim_flags(TextOverrunFlag::from_ord(of))
                                    .done();
                            }
                        }
                    } else if lines_hidden && visible - line_index - 1 >= 0 && visible - line_index - 1 < n {
                        let l = p.lines[(visible - line_index - 1) as usize];
                        t.shaped_text_set_custom_ellipsis(l, ell);
                        t.shaped_text_overrun_trim_to_width_ex(l)
                            .width(width as f64)
                            .overrun_trim_flags(TextOverrunFlag::from_ord(of))
                            .done();
                    }
                } else {
                    let to = jst_to(&t, &p.lines, jst);
                    for i in 0..n {
                        let l = p.lines[i as usize];
                        if i < to && fill {
                            t.shaped_text_fit_to_width_ex(l, width as f64)
                                .justification_flags(JustificationFlag::from_ord(jst))
                                .done();
                            of |= TextOverrunFlag::JUSTIFICATION_AWARE.ord();
                            t.shaped_text_set_custom_ellipsis(l, ell);
                            t.shaped_text_overrun_trim_to_width_ex(l)
                                .width(width as f64)
                                .overrun_trim_flags(TextOverrunFlag::from_ord(of))
                                .done();
                            t.shaped_text_fit_to_width_ex(l, width as f64)
                                .justification_flags(JustificationFlag::from_ord(
                                    jst | JustificationFlag::CONSTRAIN_ELLIPSIS.ord(),
                                ))
                                .done();
                        } else {
                            t.shaped_text_set_custom_ellipsis(l, ell);
                            t.shaped_text_overrun_trim_to_width_ex(l)
                                .width(width as f64)
                                .overrun_trim_flags(TextOverrunFlag::from_ord(of))
                                .done();
                        }
                    }
                }
                p.lines_dirty = false;
            }
            line_index += p.lines.len() as i32;
        }
        if wrap_max && maximum_width > 0 {
            minw = minw.min(maximum_width as f32);
        }
        st.minsize.x = minw;

        // _update_visible
        let mut h: f32 = 0.0;
        for p in &st.paras {
            for &l in &p.lines {
                let (a, d) = Self::asc_dsc(&t, l, e.font_h);
                h = (h as f64 + (a + d + e.line_spacing as f64)) as f32;
            }
            h += e.paragraph_spacing as f32;
        }
        if h > 0.0 {
            h -= (e.line_spacing + e.paragraph_spacing) as f32;
        }
        st.minsize.y = h;
        drop(st);
        if self.autowrap_mode == 0 || !self.clip_text || self.text_overrun_behavior == 0 {
            let mut g = self.to_gd();
            g.upcast_mut::<Control>().update_minimum_size();
        }
    }

    fn draw_text(&mut self) {
        let ci = self.base().get_canvas_item();
        if self.clip_text {
            godot::classes::RenderingServer::singleton().canvas_item_set_clip(ci, true);
        }
        let mut t = ts();
        {
            let mut st = self.st.borrow_mut();
            for p in st.paras.iter_mut() {
                if !t.shaped_text_is_ready(p.rid) {
                    p.dirty = true;
                }
                if p.lines.iter().any(|&l| !t.shaped_text_is_ready(l)) {
                    p.lines_dirty = true;
                }
            }
        }
        self.ensure_shaped();
        let th = self.theme();
        let e = self.eff(&th);
        let (font_color, shadow_color, shadow_ofs, outline_color, outline_size, shadow_outline_size) = match &self.label_settings {
            Some(s) => (
                s.get_font_color(),
                s.get_shadow_color(),
                s.get_shadow_offset(),
                s.get_outline_color(),
                s.get_outline_size(),
                s.get_shadow_size(),
            ),
            None => (th.font_color, th.shadow_color, th.shadow_ofs, th.outline_color, th.outline_size, th.shadow_outline_size),
        };
        let size = self.base().get_size();
        let rtl_layout = self.base().is_layout_rtl();
        let rect = Rect2::new(Vector2::ZERO, size);
        if self.base().has_focus() {
            if let Some(f) = &th.focus {
                f.draw(ci, rect);
            }
        } else {
            th.normal.draw(ci, rect);
        }
        let st = self.st.borrow();
        // get_layout_data
        let style_h = th.normal.get_minimum_size().y;
        let limit = (size.y - style_h + e.line_spacing as f32).ceil();
        let mut total_h: f32 = 0.0;
        let mut vis = 0usize;
        for p in &st.paras {
            for &l in &p.lines {
                let (a, d) = Self::asc_dsc(&t, l, e.font_h);
                total_h = (total_h as f64 + (a + d + e.line_spacing as f64)) as f32;
                if total_h > limit {
                    break;
                }
                vis += 1;
            }
            total_h += e.paragraph_spacing as f32;
        }
        let last = st.total_lines.min(vis);
        total_h = 0.0;
        let mut k = 0usize;
        'outer: for p in &st.paras {
            if k >= last {
                break;
            }
            for &l in &p.lines {
                if k >= last {
                    total_h += e.paragraph_spacing as f32;
                    break 'outer;
                }
                let (a, d) = Self::asc_dsc(&t, l, e.font_h);
                total_h = (total_h as f64 + (a + d + e.line_spacing as f64)) as f32;
                k += 1;
            }
            total_h += e.paragraph_spacing as f32;
        }
        total_h += th.normal.get_margin(Side::TOP) + th.normal.get_margin(Side::BOTTOM);
        let mut vbegin: i32 = 0;
        let mut vsep: i32 = 0;
        if vis > 0 {
            let content = total_h - e.line_spacing as f32 - e.paragraph_spacing as f32;
            match self.vertical_alignment {
                x if x == VerticalAlignment::CENTER.ord() => vbegin = ((size.y - content) / 2.0) as i32,
                x if x == VerticalAlignment::BOTTOM.ord() => vbegin = (size.y - content) as i32,
                x if x == VerticalAlignment::FILL.ord() => {
                    if vis > 1 {
                        vsep = ((size.y - content) / (vis as f32 - 1.0)) as i32;
                    }
                }
                _ => {}
            }
        }
        let style_ofs = Vector2::new(th.normal.get_margin(Side::LEFT), th.normal.get_margin(Side::TOP));
        let margin_r = th.normal.get_margin(Side::RIGHT);
        let mut ofs = Vector2::new(0.0, style_ofs.y + vbegin as f32);
        let line_spacing = e.line_spacing + vsep;
        let (so_n, sh_n) = match &self.label_settings {
            Some(s) => (s.get_stacked_outline_count(), s.get_stacked_shadow_count()),
            None => (0, 0),
        };
        let mut drawn = 0usize;
        // Positions in f64 as Label's (Vector2 is real_t, f32 here as there).
        for p in &st.paras {
            if drawn >= last {
                break;
            }
            let end = p.lines.len().min(last - drawn);
            let p_rtl = t.shaped_text_get_inferred_direction(p.rid) == Direction::RTL;
            for &l in &p.lines[..end] {
                let lsize = t.shaped_text_get_size(l);
                let far = (size.x - margin_r - lsize.x) as i32 as f32;
                ofs.x = match self.horizontal_alignment {
                    x if x == HorizontalAlignment::CENTER.ord() => ((size.x - lsize.x) as i32 / 2) as f32,
                    x if x == HorizontalAlignment::RIGHT.ord() => {
                        if rtl_layout { style_ofs.x } else { far }
                    }
                    x if x == HorizontalAlignment::LEFT.ord() => {
                        if rtl_layout { far } else { style_ofs.x }
                    }
                    _ => {
                        // FILL
                        if p_rtl && self.autowrap_mode != 0 { far } else { style_ofs.x }
                    }
                };
                let (a, d) = Self::asc_dsc(&t, l, e.font_h);
                ofs.y = (ofs.y as f64 + a) as f32;
                if shadow_color.a != 0.0 && shadow_outline_size > 0 {
                    t.shaped_text_draw_outline_ex(l, ci, ofs + shadow_ofs)
                        .outline_size(shadow_outline_size as i64)
                        .color(shadow_color)
                        .done();
                }
                if shadow_color.a > 0.0 {
                    t.shaped_text_draw_ex(l, ci, ofs + shadow_ofs).color(shadow_color).done();
                }
                if let Some(s) = &self.label_settings {
                    for j in (0..sh_n).rev() {
                        let c = s.get_stacked_shadow_color(j);
                        let o = s.get_stacked_shadow_offset(j);
                        let os = s.get_stacked_shadow_outline_size(j);
                        if os > 0 {
                            t.shaped_text_draw_outline_ex(l, ci, ofs + o).outline_size(os as i64).color(c).done();
                        }
                        t.shaped_text_draw_ex(l, ci, ofs + o).color(c).done();
                    }
                    if so_n > 0 {
                        let mut sz = outline_size;
                        for j in 0..so_n {
                            let x = s.get_stacked_outline_size(j);
                            if x > 0 {
                                sz += x;
                            }
                        }
                        for j in (0..so_n).rev() {
                            let x = s.get_stacked_outline_size(j);
                            if x <= 0 {
                                continue;
                            }
                            let c = s.get_stacked_outline_color(j);
                            if c.a != 0.0 && sz > 0 {
                                t.shaped_text_draw_outline_ex(l, ci, ofs).outline_size(sz as i64).color(c).done();
                            }
                            sz -= x;
                        }
                    }
                }
                if outline_size > 0 && outline_color.a != 0.0 {
                    t.shaped_text_draw_outline_ex(l, ci, ofs)
                        .outline_size(outline_size as i64)
                        .color(outline_color)
                        .done();
                }
                t.shaped_text_draw_ex(l, ci, ofs).color(font_color).done();
                ofs.y = (ofs.y as f64 + (d + line_spacing as f64)) as f32;
            }
            drawn += end;
            ofs.y += e.paragraph_spacing as f32;
        }
        let _ = &mut t;
    }
}

fn overrun_flags(b: i32) -> u64 {
    let trim = TextOverrunFlag::TRIM.ord();
    let word = TextOverrunFlag::TRIM_WORD_ONLY.ord();
    let ell = TextOverrunFlag::ADD_ELLIPSIS.ord();
    let short = TextOverrunFlag::SHORT_STRING_ELLIPSIS.ord();
    match b {
        x if x == OverrunBehavior::TRIM_WORD_ELLIPSIS_FORCE.ord() => trim | word | ell | short,
        x if x == OverrunBehavior::TRIM_ELLIPSIS_FORCE.ord() => trim | ell | short,
        x if x == OverrunBehavior::TRIM_WORD_ELLIPSIS.ord() => trim | word | ell,
        x if x == OverrunBehavior::TRIM_ELLIPSIS.ord() => trim | ell,
        x if x == OverrunBehavior::TRIM_WORD.ord() => trim | word,
        x if x == OverrunBehavior::TRIM_CHAR.ord() => trim,
        _ => 0,
    }
}

/// The line up to which Label justifies (`jst_to_line`).
fn jst_to(t: &Gd<TextServer>, lines: &[Rid], jst: u64) -> i32 {
    let n = lines.len() as i32;
    if n == 1 && jst & JustificationFlag::DO_NOT_SKIP_SINGLE_LINE.ord() != 0 {
        return n;
    }
    let mut to = n;
    if jst & JustificationFlag::SKIP_LAST_LINE.ord() != 0 {
        to = n - 1;
    }
    if jst & JustificationFlag::SKIP_LAST_LINE_WITH_VISIBLE_CHARS.ord() != 0 {
        for i in (0..n).rev() {
            if t.shaped_text_has_visible_chars(lines[i as usize]) {
                to = i;
                break;
            }
        }
    }
    to
}
