//! Runtime v2 text: the text of a Label element, shaped once and broken
//! into lines at the width the layout asks for.
//!
//! The measure and the draw are those of Godot 4.7.1's Label
//! (`scene/gui/label.cpp`: `_shape`, `_update_visible`, `get_layout_data`,
//! `get_minimum_size` and the draw of `NOTIFICATION_DRAW`), ported to
//! TextServer calls in `perf/core-text-wip` (`UxmlText`, pixel-exact in 144
//! of 144 cases against a Label), here without a Control: the paragraphs
//! are shaped once for (text, font, size), the line breaks are cached per
//! width, and the draw records into a canvas item of the core. The
//! stylebox of a Label is the element's box: its content margins (border
//! and padding) are passed in.
use std::cell::RefCell;

use godot::classes::text_server::{Direction, JustificationFlag, LineBreakFlag, TextOverrunFlag};
use godot::classes::{Font, TextServer, TextServerManager};
use godot::prelude::*;

thread_local! {
    static TS: RefCell<Option<Gd<TextServer>>> = const { RefCell::new(None) };
}

pub fn ts() -> Gd<TextServer> {
    TS.with(|t| {
        let mut t = t.borrow_mut();
        if t.is_none() {
            *t = TextServerManager::singleton().get_primary_interface();
        }
        t.clone().expect("text server")
    })
}

pub fn clear_cache() {
    TS.with(|t| *t.borrow_mut() = None);
}

/// BREAK_TRIM_START_EDGE_SPACES | BREAK_TRIM_END_EDGE_SPACES (Label's default).
pub const DEFAULT_TRIM: i32 = 64 | 128;
/// WORD_BOUND | KASHIDA | SKIP_LAST_LINE | DO_NOT_SKIP_SINGLE_LINE.
const JST_DEFAULT: u64 = 2 | 1 | 32 | 128;
pub const AUTOWRAP_OFF: i32 = 0;
pub const AUTOWRAP_WORD_SMART: i32 = 3;

/// What a text is shaped and drawn with.
#[derive(Clone, PartialEq)]
pub struct TextStyle {
    pub font: Gd<Font>,
    pub size: i32,
    pub line_spacing: i32,
    pub paragraph_spacing: i32,
    pub autowrap: i32,
    pub trim: i32,
    pub halign: i32,
    pub valign: i32,
    pub color: Color,
    pub outline_size: i32,
    pub outline_color: Color,
    pub shadow_color: Color,
    pub shadow_ofs: Vector2,
    pub shadow_outline_size: i32,
    /// Unity's line height on a scaled panel: [the font's line height,
    /// Unity's in points] (UxmlStyleApplier._set_line_fix); None at one
    /// pixel per point.
    pub line_fix: Option<(f64, f64)>,
}

struct Para {
    rid: Rid,
    lines: Vec<Rid>,
}

pub struct TextBlock {
    pub text: GString,
    pub st: TextStyle,
    paras: Vec<Para>,
    font_h: i32,
    /// The width the lines are broken at (-1: not yet).
    width: i32,
    total_lines: usize,
    /// The text's minimum size at `width` (Label's `minsize`, without the
    /// box), and per width already asked for.
    minsize: Vector2,
    memo: Vec<(i32, Vector2)>,
    maxc: Option<f64>,
}

impl Drop for TextBlock {
    fn drop(&mut self) {
        self.free();
    }
}

impl TextBlock {
    pub fn new(text: GString, st: TextStyle) -> Self {
        let font_h = st.font.get_height_ex().font_size(st.size).done() as i32;
        let mut b = TextBlock {
            text,
            st,
            paras: vec![],
            font_h,
            width: -1,
            total_lines: 0,
            minsize: Vector2::ZERO,
            memo: vec![],
            maxc: None,
        };
        b.shape_paras();
        b
    }

    /// Whether this block can serve `text` drawn with `st` without shaping
    /// again (only the colours, alignments or outline differ).
    pub fn same_shape(&self, text: &GString, st: &TextStyle) -> bool {
        self.text == *text
            && self.st.font == st.font
            && self.st.size == st.size
            && self.st.autowrap == st.autowrap
            && self.st.trim == st.trim
            && self.st.line_spacing == st.line_spacing
            && self.st.paragraph_spacing == st.paragraph_spacing
            && self.st.line_fix == st.line_fix
    }

    fn free(&mut self) {
        if self.paras.is_empty() {
            return;
        }
        let mut t = ts();
        for p in self.paras.drain(..) {
            for l in p.lines {
                if l != p.rid {
                    t.free_rid(l);
                }
            }
            t.free_rid(p.rid);
        }
    }

    fn shape_paras(&mut self) {
        let _p = crate::prof::scope("v2.shape");
        let mut t = ts();
        let lang = godot::classes::TranslationServer::singleton().get_locale();
        let rids = self.st.font.get_rids();
        let feats = self.st.font.get_opentype_features();
        let s = self.text.to_string();
        for part in s.split('\n') {
            let rid = t.create_shaped_text();
            t.shaped_text_set_direction_ex(rid).direction(Direction::LTR).done();
            let txt = GString::from(format!("{}\u{200B}", part).as_str());
            t.shaped_text_add_string_ex(rid, &txt, &rids, self.st.size as i64)
                .opentype_features(&feats)
                .language(&lang)
                .done();
            self.paras.push(Para { rid, lines: vec![] });
        }
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

    /// Breaks the lines at `width` (Label's `_shape` with a width of
    /// `size.x - style_min.x`), when the breaks follow the width.
    fn break_at(&mut self, width: i32) {
        let width = if self.st.autowrap == AUTOWRAP_OFF { 0 } else { width };
        if self.width == width {
            return;
        }
        let _p = crate::prof::scope("v2.break");
        let mut t = ts();
        let mut flags = LineBreakFlag::MANDATORY.ord();
        match self.st.autowrap {
            3 => flags = LineBreakFlag::WORD_BOUND.ord() | LineBreakFlag::ADAPTIVE.ord() | LineBreakFlag::MANDATORY.ord(),
            2 => flags = LineBreakFlag::WORD_BOUND.ord() | LineBreakFlag::MANDATORY.ord(),
            1 => flags = LineBreakFlag::GRAPHEME_BOUND.ord() | LineBreakFlag::MANDATORY.ord(),
            _ => {}
        }
        flags |= self.st.trim as u64;
        // FILL fits each line to the width: lines are substrings then.
        let fast = self.st.halign != 3;
        let mut total = 0;
        for p in self.paras.iter_mut() {
            for &l in &p.lines {
                if l != p.rid {
                    t.free_rid(l);
                }
            }
            p.lines.clear();
            let lb = t
                .shaped_text_get_line_breaks_ex(p.rid, width as f64)
                .start(0)
                .break_flags(LineBreakFlag::from_ord(flags))
                .done();
            let lb = lb.as_slice();
            let range = t.shaped_text_get_range(p.rid);
            if fast && lb.len() == 2 && lb[0] as i64 == range.x as i64 && lb[1] as i64 == range.y as i64 {
                // One line over the whole paragraph: the paragraph itself
                // (Label takes a substring of the same range).
                p.lines.push(p.rid);
            } else {
                let mut i = 0;
                while i + 1 < lb.len() {
                    p.lines.push(t.shaped_text_substr(p.rid, lb[i] as i64, (lb[i + 1] - lb[i]) as i64));
                    i += 2;
                }
            }
            total += p.lines.len();
        }
        self.total_lines = total;
        self.width = width;
        // Label's overrun pass: no overrun, no fill, every line visible:
        // only the trim of the (absent) ellipsis, which changes nothing.
        let fill = self.st.halign == 3;
        if fill {
            for p in self.paras.iter() {
                let n = p.lines.len() as i32;
                let to = jst_to(&t, &p.lines, JST_DEFAULT);
                for i in 0..n {
                    let l = p.lines[i as usize];
                    if i < to {
                        t.shaped_text_fit_to_width_ex(l, width as f64)
                            .justification_flags(JustificationFlag::from_ord(JST_DEFAULT))
                            .done();
                        if self.st.autowrap == AUTOWRAP_OFF {
                            t.shaped_text_set_custom_ellipsis(l, 0x2026);
                            t.shaped_text_overrun_trim_to_width_ex(l)
                                .width(width as f64)
                                .overrun_trim_flags(TextOverrunFlag::from_ord(TextOverrunFlag::JUSTIFICATION_AWARE.ord()))
                                .done();
                            t.shaped_text_fit_to_width_ex(l, width as f64)
                                .justification_flags(JustificationFlag::from_ord(
                                    JST_DEFAULT | JustificationFlag::CONSTRAIN_ELLIPSIS.ord(),
                                ))
                                .done();
                        }
                    }
                }
            }
        }
        // minsize (Label::_shape and _update_visible).
        let mut minw: f32 = 0.0;
        for p in &self.paras {
            if self.st.autowrap == AUTOWRAP_OFF {
                for &l in &p.lines {
                    let w = t.shaped_text_get_size(l).x;
                    if minw < w {
                        minw = w;
                    }
                }
            }
        }
        let mut h: f32 = 0.0;
        for p in &self.paras {
            for &l in &p.lines {
                let (a, d) = Self::asc_dsc(&t, l, self.font_h);
                h = (h as f64 + (a + d + self.st.line_spacing as f64)) as f32;
            }
            h += self.st.paragraph_spacing as f32;
        }
        if h > 0.0 {
            h -= (self.st.line_spacing + self.st.paragraph_spacing) as f32;
        }
        if self.text.is_empty() {
            minw = 1.0;
            h = self.line_height_max(&t) as f32;
        }
        self.minsize = Vector2::new(minw, h);
    }

    fn line_height_max(&self, t: &Gd<TextServer>) -> i32 {
        if self.total_lines > 0 {
            let mut h = self.font_h as f32;
            for p in &self.paras {
                for &l in &p.lines {
                    h = h.max(t.shaped_text_get_size(l).y);
                }
            }
            h as i32
        } else {
            self.font_h
        }
    }

    /// Label.get_minimum_size() less the stylebox, the lines broken at
    /// `width` (the content width): the text's own minimum size.
    pub fn min_size(&mut self, width: i32) -> Vector2 {
        let key = if self.st.autowrap == AUTOWRAP_OFF { 0 } else { width };
        if let Some(&(_, v)) = self.memo.iter().find(|(w, _)| *w == key) {
            return v;
        }
        self.break_at(width);
        let mut min = self.minsize;
        min.y = min.y.max(self.font_h as f32);
        if self.st.autowrap != AUTOWRAP_OFF {
            min.x = 1.0;
        }
        if self.memo.len() > 16 {
            self.memo.clear();
        }
        self.memo.push((key, min));
        min
    }

    /// UxmlStyleApplier.label_max_content less the stylebox: the longest
    /// paragraph as one line.
    pub fn max_content(&mut self) -> f64 {
        if let Some(v) = self.maxc {
            return v;
        }
        let w = if self.text.is_empty() {
            0.0
        } else {
            self.st
                .font
                .get_multiline_string_size_ex(&self.text)
                .alignment(godot::global::HorizontalAlignment::LEFT)
                .width(-1.0)
                .font_size(self.st.size)
                .done()
                .x as f64
        };
        self.maxc = Some(w);
        w
    }

    /// The draw of a Label of `size` with content margins `m` (left, top,
    /// right, bottom) into canvas item `ci` at `pos`.
    pub fn draw(&mut self, ci: Rid, pos: Vector2, size: Vector2, m: [f32; 4], os: f32) {
        let _p = crate::prof::scope("v2.draw_text");
        let width = (size.x - (m[0] + m[2])) as i32;
        self.break_at(width.max(if self.st.autowrap == AUTOWRAP_OFF { 0 } else { 1 }));
        let t = ts();
        let e_ls = self.st.line_spacing;
        let e_ps = self.st.paragraph_spacing;
        let style_h = m[1] + m[3];
        let limit = (size.y - style_h + e_ls as f32).ceil();
        let mut total_h: f32 = 0.0;
        let mut vis = 0usize;
        for p in &self.paras {
            for &l in &p.lines {
                let (a, d) = Self::asc_dsc(&t, l, self.font_h);
                total_h = (total_h as f64 + (a + d + e_ls as f64)) as f32;
                if total_h > limit {
                    break;
                }
                vis += 1;
            }
            total_h += e_ps as f32;
        }
        let last = self.total_lines.min(vis);
        total_h = 0.0;
        let mut k = 0usize;
        'outer: for p in &self.paras {
            if k >= last {
                break;
            }
            for &l in &p.lines {
                if k >= last {
                    total_h += e_ps as f32;
                    break 'outer;
                }
                let (a, d) = Self::asc_dsc(&t, l, self.font_h);
                total_h = (total_h as f64 + (a + d + e_ls as f64)) as f32;
                k += 1;
            }
            total_h += e_ps as f32;
        }
        total_h += m[1] + m[3];
        let mut vbegin: i32 = 0;
        let mut vsep: i32 = 0;
        if vis > 0 {
            let content = total_h - e_ls as f32 - e_ps as f32;
            match self.st.valign {
                1 => vbegin = ((size.y - content) / 2.0) as i32,
                2 => vbegin = (size.y - content) as i32,
                3 => {
                    if vis > 1 {
                        vsep = ((size.y - content) / (vis as f32 - 1.0)) as i32;
                    }
                }
                _ => {}
            }
        }
        let style_ofs = Vector2::new(m[0], m[1]);
        let margin_r = m[2];
        let mut ofs = Vector2::new(0.0, style_ofs.y + vbegin as f32);
        let line_spacing = e_ls + vsep;
        let st = &self.st;
        let mut drawn = 0usize;
        for p in &self.paras {
            if drawn >= last {
                break;
            }
            let end = p.lines.len().min(last - drawn);
            for &l in &p.lines[..end] {
                let lsize = t.shaped_text_get_size(l);
                let far = (size.x - margin_r - lsize.x) as i32 as f32;
                ofs.x = match st.halign {
                    1 => ((size.x - lsize.x) as i32 / 2) as f32,
                    2 => far,
                    _ => style_ofs.x,
                };
                let (a, d) = Self::asc_dsc(&t, l, self.font_h);
                ofs.y = (ofs.y as f64 + a) as f32;
                let at = pos + ofs;
                if st.shadow_color.a != 0.0 && st.shadow_outline_size > 0 {
                    t.shaped_text_draw_outline_ex(l, ci, at + st.shadow_ofs)
                        .outline_size(st.shadow_outline_size as i64)
                        .color(st.shadow_color)
                        .oversampling(os)
                        .done();
                }
                if st.shadow_color.a > 0.0 {
                    t.shaped_text_draw_ex(l, ci, at + st.shadow_ofs).color(st.shadow_color).oversampling(os).done();
                }
                if st.outline_size > 0 && st.outline_color.a != 0.0 {
                    t.shaped_text_draw_outline_ex(l, ci, at)
                        .outline_size(st.outline_size as i64)
                        .color(st.outline_color)
                        .oversampling(os)
                        .done();
                }
                t.shaped_text_draw_ex(l, ci, at).color(st.color).oversampling(os).done();
                ofs.y = (ofs.y as f64 + (d + line_spacing as f64)) as f32;
            }
            drawn += end;
            ofs.y += e_ps as f32;
        }
    }
}

/// The line up to which Label justifies (`jst_to_line`).
fn jst_to(_t: &Gd<TextServer>, lines: &[Rid], jst: u64) -> i32 {
    let n = lines.len() as i32;
    if n == 1 && jst & JustificationFlag::DO_NOT_SKIP_SINGLE_LINE.ord() != 0 {
        return n;
    }
    let mut to = n;
    if jst & JustificationFlag::SKIP_LAST_LINE.ord() != 0 {
        to = n - 1;
    }
    to
}
