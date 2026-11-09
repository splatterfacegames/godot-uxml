//! Runtime v2 text of a Button element: Godot 4.7.1's Button text
//! (`scene/gui/button.cpp`: `_shape`, `get_minimum_size_for_text_and_icon`
//! and the text half of `NOTIFICATION_DRAW`) without a Control. The text is
//! a TextParagraph shaped as Button shapes its `text_buf` (mandatory breaks
//! with the end-edge trim, the line spacing of the theme, left to right,
//! no overrun), measured as a Button measures it (the paragraph's size, at
//! least one line of the font) and drawn at the offset Button draws it:
//! the content box after the stylebox margins, the paragraph as wide as
//! that box (rounded up), centred vertically.
//!
//! The margins come from the caller: the element's resolved border and
//! padding, fitted into a box that is too small for the text as
//! `UxmlStyleApplier.fit_button` fits a Button's stylebox margins (see
//! `fit`).
use godot::classes::text_server::{Direction, LineBreakFlag, OverrunBehavior};
use godot::classes::TextParagraph;
use godot::global::HorizontalAlignment;
use godot::prelude::*;

use crate::v2text::TextStyle;

/// BREAK_TRIM_END_EDGE_SPACES: Button's `autowrap_flags_trim`.
const TRIM_END: u64 = 128;

pub struct ButtonText {
    pub text: GString,
    pub st: TextStyle,
    para: Gd<TextParagraph>,
    /// The paragraph's size and the font's height (Button's minimum text
    /// size before the stylebox).
    size: Vector2,
    font_h: f32,
    locale: GString,
}

impl ButtonText {
    pub fn new(text: GString, st: TextStyle, locale: GString) -> Self {
        let mut b = ButtonText {
            text,
            st,
            para: TextParagraph::new_gd(),
            size: Vector2::ZERO,
            font_h: 0.0,
            locale,
        };
        b.shape();
        b
    }

    /// Whether this block can serve `text` with `st` without shaping again.
    pub fn same_shape(&self, text: &GString, st: &TextStyle) -> bool {
        self.text == *text && self.st.font == st.font && self.st.size == st.size && self.st.line_spacing == st.line_spacing
    }

    fn shape(&mut self) {
        let p = &mut self.para;
        p.clear();
        self.font_h = self.st.font.get_height_ex().font_size(self.st.size).done();
        if self.st.size == 0 {
            self.size = Vector2::ZERO;
            return;
        }
        p.set_break_flags(LineBreakFlag::from_ord(LineBreakFlag::MANDATORY.ord() | TRIM_END));
        p.set_line_spacing(self.st.line_spacing as f32);
        p.set_direction(Direction::LTR);
        p.add_string_ex(&self.text, &self.st.font, self.st.size).language(&self.locale).done();
        p.set_text_overrun_behavior(OverrunBehavior::NO_TRIMMING);
        self.size = p.get_size();
    }

    /// The text's minimum size (Button's minimum size less its stylebox):
    /// the paragraph, at least one line of the font; nothing for no text.
    pub fn min_size(&self, clip: bool) -> Vector2 {
        if self.text.is_empty() {
            return Vector2::ZERO;
        }
        let mut s = self.size;
        if clip {
            s.x = 0.0;
        }
        s.y = s.y.max(self.font_h);
        s
    }

    /// The full text size (the layout measures a clipped Button's text
    /// unclipped, as `_measure_leaf` turns clip_text off to measure).
    pub fn measure(&self) -> Vector2 {
        self.min_size(false)
    }

    /// UxmlStyleApplier.fit_button: the stylebox margins (left, top, right,
    /// bottom) of a Button of `want` with the resolved insets `m`, and the
    /// size Godot then gives the Button (never below its minimum size).
    pub fn fit(&self, want: Vector2, m: [f32; 4], clip: bool) -> ([f32; 4], Vector2) {
        let text = self.min_size(clip);
        let mut o = m;
        if want.y < m[1] + m[3] + text.y - 0.01 {
            let top = (m[1] + (want.y - m[1] - m[3] - text.y) * 0.5).clamp(0.0, m[1].max(0.0));
            o[1] = top;
            o[3] = (want.y - text.y - top).clamp(0.0, m[3].max(0.0));
        }
        if !clip && want.x < m[0] + m[2] + text.x - 0.01 {
            let free = want.x - m[0] - m[2] - text.x;
            let left = match self.st.halign {
                1 => m[0] + free * 0.5,
                2 => m[0] + free,
                _ => m[0],
            }
            .clamp(0.0, m[0].max(0.0));
            o[0] = left;
            o[2] = (want.x - text.x - left).clamp(0.0, m[2].max(0.0));
        }
        let size = Vector2::new(want.x.max(o[0] + o[2] + text.x), want.y.max(o[1] + o[3] + text.y));
        (o, size)
    }

    /// The text of a Button of `size` with stylebox margins `m`, recorded
    /// into `ci` (Button's NOTIFICATION_DRAW, no icon).
    pub fn draw(&mut self, ci: Rid, size: Vector2, m: [f32; 4]) {
        if self.text.is_empty() {
            return;
        }
        let remained = Vector2::new(size.x - (m[0] + m[2]), size.y - (m[1] + m[3]));
        let align = match self.st.halign {
            1 => HorizontalAlignment::CENTER,
            2 => HorizontalAlignment::RIGHT,
            _ => HorizontalAlignment::LEFT,
        };
        let p = &mut self.para;
        p.set_alignment(align);
        let tbw = remained.x.max(1.0).ceil();
        p.set_width(tbw);
        let mut ofs = Vector2::ZERO;
        if self.st.halign == 1 {
            ofs.x = (remained.x - tbw) / 2.0;
        }
        ofs.x += m[0];
        ofs.y = (remained.y - p.get_size().y) / 2.0 + m[1];
        if self.st.outline_size > 0 && self.st.outline_color.a > 0.0 {
            p.draw_outline_ex(ci, ofs).outline_size(self.st.outline_size).color(self.st.outline_color).done();
        }
        p.draw_ex(ci, ofs).color(self.st.color).done();
    }
}
