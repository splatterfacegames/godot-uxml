//! Native UXML / USS scanners — line-by-line ports of core/uxml_parser.gd
//! and core/uss_parser.gd over code points (Godot String indices), so every
//! offset, span and message is identical. They return plain data; the
//! GDScript parsers build UxmlElement objects and diagnostics from it with
//! their own code (bench/equiv_parse.gd compares both paths, including on
//! fuzzed input). Attribute values containing '&' or a literal tab or line
//! break are handed back raw with a flag: entity decoding and attribute
//! whitespace normalization stay in GDScript (decode_entities), so numeric
//! overflow behaviour is Godot's own.

use godot::prelude::*;

type S = [char];

fn find(s: &S, pat: &str, from: usize) -> Option<usize> {
    // The patterns are short ASCII literals: compared in place (no
    // allocation per call).
    let p = pat.as_bytes();
    if p.is_empty() || from > s.len() || !pat.is_ascii() {
        if !pat.is_ascii() {
            let pc: Vec<char> = pat.chars().collect();
            let mut i = from;
            while i + pc.len() <= s.len() {
                if s[i..i + pc.len()] == pc[..] {
                    return Some(i);
                }
                i += 1;
            }
        }
        return None;
    }
    let first = p[0] as char;
    let mut i = from;
    while i + p.len() <= s.len() {
        if s[i] == first && p[1..].iter().enumerate().all(|(k, &b)| s[i + 1 + k] == b as char) {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn sub(s: &S, from: usize, to: usize) -> String {
    let a = from.min(s.len());
    let b = to.min(s.len()).max(a);
    s[a..b].iter().collect()
}

fn starts(s: &S, at: usize, pat: &str) -> bool {
    let n = pat.chars().count();
    at + n <= s.len() && pat.chars().enumerate().all(|(k, c)| s[at + k] == c)
}

/// Godot String::strip_edges (code <= 32 at both ends).
fn strip(s: &str) -> String {
    s.trim_matches(|c: char| (c as u32) <= 32).to_string()
}

fn gd(s: &str) -> GString {
    GString::from(s)
}

// =========================================================================
// UXML
// =========================================================================

pub(crate) struct Uxml<'a> {
    pub(crate) s: &'a S,
    pub(crate) pos: usize,
    pub(crate) next_id: i32,
    // kept elements
    pub(crate) local: Vec<String>,
    pub(crate) prefix: Vec<String>,
    pub(crate) parent: Vec<i32>,
    pub(crate) id: Vec<i32>,
    pub(crate) open_start: Vec<i32>,
    pub(crate) open_end: Vec<i32>,
    pub(crate) source_end: Vec<i32>,
    pub(crate) attr_el: Vec<i32>,
    pub(crate) attr_name: Vec<String>,
    pub(crate) attr_value: Vec<String>,
    pub(crate) attr_raw: Vec<bool>,
    pub(crate) attr_offset: Vec<i32>,
    pub(crate) w_msg: Vec<String>,
    pub(crate) w_start: Vec<i32>,
    pub(crate) w_end: Vec<i32>,
}

fn uxml_name_start(c: i64) -> bool {
    (65..=90).contains(&c) || (97..=122).contains(&c) || c == 95
}

impl<'a> Uxml<'a> {
    fn ch(&self, at: usize) -> i64 {
        if at < self.s.len() { self.s[at] as i64 } else { -1 }
    }

    fn warn(&mut self, m: String, start: usize, end: usize) {
        self.w_msg.push(m);
        self.w_start.push(start as i32);
        self.w_end.push(end as i32);
    }

    fn skip_space(&mut self) {
        while self.pos < self.s.len() {
            let c = self.s[self.pos];
            if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
                return;
            }
            self.pos += 1;
        }
    }

    fn name_end(&self, mut i: usize) -> usize {
        while i < self.s.len() {
            let c = self.s[i] as u32;
            if !((97..=122).contains(&c) || (65..=90).contains(&c) || (48..=58).contains(&c) || c == 95 || c == 46 || c == 45) {
                return i;
            }
            i += 1;
        }
        i
    }

    fn seek_tag(&mut self) {
        loop {
            let Some(lt) = find(self.s, "<", self.pos) else {
                self.pos = self.s.len();
                return;
            };
            let next = self.ch(lt + 1);
            if next == 33 {
                if starts(self.s, lt, "<!--") {
                    self.pos = find(self.s, "-->", lt + 4).map(|e| e + 3).unwrap_or(self.s.len());
                } else if starts(self.s, lt, "<![CDATA[") {
                    self.pos = find(self.s, "]]>", lt + 9).map(|e| e + 3).unwrap_or(self.s.len());
                } else {
                    self.pos = find(self.s, ">", lt).map(|e| e + 1).unwrap_or(self.s.len());
                }
                continue;
            }
            if next == 63 {
                self.pos = find(self.s, "?>", lt + 2).map(|e| e + 2).unwrap_or(self.s.len());
                continue;
            }
            self.pos = lt;
            return;
        }
    }

    fn read_name(&mut self) -> (String, String) {
        let start = self.pos;
        self.pos = self.name_end(self.pos);
        let raw = sub(self.s, start, self.pos);
        match raw.find(':') {
            None => (String::new(), raw),
            Some(k) => (raw[..k].to_string(), raw[k + 1..].to_string()),
        }
    }

    /// (name, value, raw-needs-decode, offset)
    fn read_attribute(&mut self) -> Option<(String, String, bool, usize)> {
        let start = self.pos;
        self.pos = self.name_end(self.pos);
        if self.pos == start {
            return None;
        }
        let name = sub(self.s, start, self.pos);
        let after = self.pos;
        self.skip_space();
        if self.ch(self.pos) != 61 {
            self.pos = after;
            self.warn(format!("attribute \"{name}\" has no value"), start, after);
            return Some((name, String::new(), false, start));
        }
        self.pos += 1;
        self.skip_space();
        let q = self.ch(self.pos);
        if q != 34 && q != 39 {
            let p = self.pos;
            self.warn(format!("attribute \"{name}\" has an unquoted value"), start, p);
            return Some((name, String::new(), false, start));
        }
        self.pos += 1;
        let vs = self.pos;
        let qs = if q == 34 { "\"" } else { "'" };
        match find(self.s, qs, self.pos) {
            None => {
                let l = self.s.len();
                self.warn(format!("attribute \"{name}\" has an unterminated value"), start, l);
                self.pos = l;
                let v = sub(self.s, vs, l);
                let raw = v.contains(|c| c == '&' || c == '\n' || c == '\r' || c == '\t');
                Some((name, v, raw, start))
            }
            Some(close) => {
                self.pos = close + 1;
                let v = sub(self.s, vs, close);
                let raw = v.contains(|c| c == '&' || c == '\n' || c == '\r' || c == '\t');
                Some((name, v, raw, start))
            }
        }
    }

    fn parse_element(&mut self, parent: i32, keep: bool) {
        let tag_start = self.pos;
        self.pos += 1;
        let (prefix, local) = self.read_name();
        let id = self.next_id;
        self.next_id += 1;
        let idx = self.local.len() as i32;
        if keep {
            self.local.push(local.clone());
            self.prefix.push(prefix.clone());
            self.parent.push(parent);
            self.id.push(id);
            self.open_start.push(tag_start as i32);
            self.open_end.push(0);
            self.source_end.push(0);
        }
        let tag = if prefix.is_empty() { local.clone() } else { format!("{prefix}:{local}") };
        let mut seen: Vec<String> = vec![];
        let mut self_closing = false;
        loop {
            self.skip_space();
            let c = self.ch(self.pos);
            if c < 0 {
                let l = self.s.len();
                self.warn("unterminated open tag".into(), tag_start, l);
                break;
            }
            if c == 62 {
                self.pos += 1;
                break;
            }
            if c == 47 && self.ch(self.pos + 1) == 62 {
                self.pos += 2;
                self_closing = true;
                break;
            }
            let Some((name, value, raw, offset)) = self.read_attribute() else {
                self.pos += 1;
                continue;
            };
            if seen.contains(&name) {
                let p = self.pos;
                self.warn(format!("duplicate attribute \"{name}\""), offset, p);
            }
            seen.push(name.clone());
            if keep {
                self.attr_el.push(idx);
                self.attr_name.push(name);
                self.attr_value.push(value);
                self.attr_raw.push(raw);
                self.attr_offset.push(offset as i32);
            }
        }
        if keep {
            self.open_end[idx as usize] = self.pos as i32;
        }
        if self_closing {
            if keep {
                self.source_end[idx as usize] = self.pos as i32;
            }
            return;
        }
        loop {
            self.seek_tag();
            if self.pos >= self.s.len() {
                let l = self.s.len();
                self.warn(format!("unterminated element <{tag}>"), tag_start, l);
                break;
            }
            let next = self.ch(self.pos + 1);
            if next == 47 {
                break;
            }
            if !uxml_name_start(next) {
                self.pos += 1;
                continue;
            }
            self.parse_element(if keep { idx } else { -1 }, keep);
        }
        if starts(self.s, self.pos, "</") {
            let close_start = self.pos;
            self.pos += 2;
            let (cp, cl) = self.read_name();
            let close_text = if cp.is_empty() { cl } else { format!("{cp}:{cl}") };
            self.skip_space();
            let gt = find(self.s, ">", self.pos);
            let end = gt.map(|g| g + 1).unwrap_or(self.s.len());
            if gt.is_none() {
                self.warn("unterminated end tag".into(), close_start, end);
            } else if close_text != tag {
                self.warn(format!("closing tag \"</{close_text}>\" does not match open tag \"<{tag}>\""), close_start, end);
            }
            self.pos = end;
        }
        if keep {
            self.source_end[idx as usize] = self.pos as i32;
        }
    }

    fn run(&mut self) -> bool {
        self.seek_tag();
        let mut synth = false;
        if self.pos < self.s.len() && uxml_name_start(self.ch(self.pos + 1)) {
            self.parse_element(-1, true);
        } else {
            self.warn("no root element".into(), 0, 0);
            synth = true;
            self.next_id += 1; // root.id = _alloc_id()
        }
        loop {
            self.seek_tag();
            if self.pos >= self.s.len() {
                break;
            }
            let next = self.ch(self.pos + 1);
            if next == 47 {
                let end = find(self.s, ">", self.pos).map(|g| g + 1).unwrap_or(self.s.len());
                let p = self.pos;
                self.warn("closing tag after the document root element".into(), p, end);
                self.pos = end;
            } else if uxml_name_start(next) {
                let p = self.pos;
                self.warn("element after the document root element".into(), p, p + 1);
                self.parse_element(-1, false);
            } else {
                self.pos += 1;
            }
        }
        synth
    }
}

/// Runs the UXML scanner over `chars` (code points): the kept elements in
/// preorder, their attributes and the problems. The second value: the root
/// was synthesized (no root element).
pub(crate) fn scan_chars(chars: &[char]) -> (Uxml<'_>, bool) {
    let mut u = Uxml {
        s: chars,
        pos: 0,
        next_id: 0,
        local: vec![],
        prefix: vec![],
        parent: vec![],
        id: vec![],
        open_start: vec![],
        open_end: vec![],
        source_end: vec![],
        attr_el: vec![],
        attr_name: vec![],
        attr_value: vec![],
        attr_raw: vec![],
        attr_offset: vec![],
        w_msg: vec![],
        w_start: vec![],
        w_end: vec![],
    };
    let synth = u.run();
    (u, synth)
}

pub fn scan_uxml(source: &GString) -> VarDictionary {
    let chars: Vec<char> = source.to_string().chars().collect();
    let (u, synth) = scan_chars(&chars);
    let psa = |v: &Vec<String>| {
        let mut a = PackedStringArray::new();
        for x in v {
            a.push(&gd(x));
        }
        a
    };
    let pia = |v: &Vec<i32>| PackedInt32Array::from(v.as_slice());
    let mut d = VarDictionary::new();
    d.set("synth_root", synth);
    d.set("local", &psa(&u.local));
    d.set("prefix", &psa(&u.prefix));
    d.set("parent", &pia(&u.parent));
    d.set("id", &pia(&u.id));
    d.set("open_start", &pia(&u.open_start));
    d.set("open_end", &pia(&u.open_end));
    d.set("source_end", &pia(&u.source_end));
    d.set("attr_el", &pia(&u.attr_el));
    d.set("attr_name", &psa(&u.attr_name));
    d.set("attr_value", &psa(&u.attr_value));
    let raw: Vec<u8> = u.attr_raw.iter().map(|&b| b as u8).collect();
    d.set("attr_raw", &PackedByteArray::from(raw.as_slice()));
    d.set("attr_offset", &pia(&u.attr_offset));
    d.set("w_msg", &psa(&u.w_msg));
    d.set("w_start", &pia(&u.w_start));
    d.set("w_end", &pia(&u.w_end));
    d
}

// =========================================================================
// USS
// =========================================================================

struct Uss<'a> {
    s: &'a S,
    pos: usize,
    w: Vec<(String, usize, usize)>,
}

fn uss_space(c: i64) -> bool {
    c == 32 || c == 9 || c == 10 || c == 13 || c == 12
}

fn uss_ident(c: i64) -> bool {
    (65..=90).contains(&c) || (97..=122).contains(&c) || (48..=57).contains(&c) || c == 95 || c == 45
}

fn find_quote_close(s: &S, i: usize) -> Option<usize> {
    let q = s[i];
    let mut j = i + 1;
    while j < s.len() {
        let c = s[j];
        if c == '\\' {
            j += 2;
            continue;
        }
        if c == q {
            return Some(j + 1);
        }
        j += 1;
    }
    None
}

fn span(start: usize, end: usize) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("start", start as i64);
    d.set("end", end as i64);
    d
}

fn simple(kind: &str) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("kind", kind);
    d
}

impl<'a> Uss<'a> {
    fn len(&self) -> usize {
        self.s.len()
    }

    fn ch(&self, at: usize) -> i64 {
        if at < self.s.len() { self.s[at] as i64 } else { -1 }
    }

    fn scan_to(&self, from: usize, stops: &[char], limit: Option<usize>) -> usize {
        let n = self.len();
        let lim = match limit {
            Some(l) if l <= n => l,
            _ => n,
        };
        let mut i = from;
        let mut depth = 0i32;
        while i < lim {
            let c = self.s[i];
            if c == '"' || c == '\'' {
                i = find_quote_close(self.s, i).unwrap_or(n);
                continue;
            }
            if c == '/' && i + 1 < n && self.s[i + 1] == '*' {
                i = find(self.s, "*/", i + 2).map(|e| e + 2).unwrap_or(n);
                continue;
            }
            if c == '(' || c == '[' {
                depth += 1;
            } else if c == ')' || c == ']' {
                if depth > 0 {
                    depth -= 1;
                }
            } else if depth == 0 && stops.contains(&c) {
                return i;
            }
            i += 1;
        }
        if lim == n { n } else { lim }
    }

    fn trim_bounds(&self, start: usize, end: usize) -> (usize, usize) {
        let (mut s, mut e) = (start, end);
        while s < e && uss_space(self.s[s] as i64) {
            s += 1;
        }
        while e > s && uss_space(self.s[e - 1] as i64) {
            e -= 1;
        }
        (s, e)
    }

    fn skip_trivia(&mut self) {
        loop {
            while uss_space(self.ch(self.pos)) {
                self.pos += 1;
            }
            if starts(self.s, self.pos, "/*") {
                self.pos = find(self.s, "*/", self.pos + 2).map(|e| e + 2).unwrap_or(self.len());
                continue;
            }
            return;
        }
    }

    fn end_of_block(&self, from: usize) -> usize {
        let n = self.len();
        let mut i = from + 1;
        let mut depth = 1;
        while i < n {
            let c = self.s[i];
            if c == '"' || c == '\'' {
                i = find_quote_close(self.s, i).unwrap_or(n);
                continue;
            }
            if c == '/' && self.ch(i + 1) == 42 {
                i = find(self.s, "*/", i + 2).map(|e| e + 2).unwrap_or(n);
                continue;
            }
            if c == '{' {
                depth += 1;
            } else if c == '}' {
                depth -= 1;
                if depth == 0 {
                    return i + 1;
                }
            }
            i += 1;
        }
        n
    }

    fn read_ident(&self, i: usize) -> usize {
        let mut j = i;
        while j < self.len() && uss_ident(self.s[j] as i64) {
            j += 1;
        }
        j
    }

    fn end_of_bracket(&self, i: usize) -> usize {
        let n = self.len();
        let open = self.s[i];
        let close_c = if open == '(' { ')' } else { ']' };
        let mut j = i + 1;
        let mut depth = 1;
        while j < n {
            let c = self.s[j];
            if c == '"' || c == '\'' {
                j = find_quote_close(self.s, j).unwrap_or(n);
                continue;
            }
            if c == open {
                depth += 1;
            } else if c == close_c {
                depth -= 1;
                if depth == 0 {
                    return j + 1;
                }
            }
            j += 1;
        }
        n
    }

    fn read_compound(&self, i: usize, limit: usize) -> (VarArray, usize) {
        let mut out = VarArray::new();
        let mut j = i;
        while j < limit {
            let c = self.s[j];
            let ci = c as i64;
            if uss_space(ci) || c == '>' || c == '+' || c == '~' || c == ',' {
                break;
            }
            if c == '*' {
                out.push(&simple("universal").to_variant());
                j += 1;
            } else if c == '.' || c == '#' {
                let end = self.read_ident(j + 1);
                let mut d = simple(if c == '.' { "class" } else { "name" });
                d.set("name", &gd(&sub(self.s, j + 1, end)));
                out.push(&d.to_variant());
                j = end;
            } else if c == '[' {
                let end = self.end_of_bracket(j).min(limit);
                let mut d = simple("unknown");
                d.set("text", &gd(&sub(self.s, j, end)));
                out.push(&d.to_variant());
                j = end;
            } else if c == ':' {
                if self.ch(j + 1) == 58 {
                    let end = self.read_ident(j + 2);
                    let mut d = simple("unknown");
                    d.set("text", &gd(&sub(self.s, j, end)));
                    out.push(&d.to_variant());
                    j = end;
                } else {
                    let name_end = self.read_ident(j + 1);
                    if self.ch(name_end) == 40 {
                        let end = self.end_of_bracket(name_end).min(limit);
                        let mut d = simple("unknown");
                        d.set("text", &gd(&sub(self.s, j, end)));
                        out.push(&d.to_variant());
                        j = end;
                    } else {
                        let mut d = simple("pseudo");
                        d.set("name", &gd(&sub(self.s, j + 1, name_end)));
                        out.push(&d.to_variant());
                        j = name_end;
                    }
                }
            } else if uss_ident(ci) {
                let end = self.read_ident(j);
                let mut d = simple("type");
                d.set("name", &gd(&sub(self.s, j, end)));
                out.push(&d.to_variant());
                j = end;
            } else {
                let mut d = simple("unknown");
                d.set("text", &gd(&sub(self.s, j, j + 1)));
                out.push(&d.to_variant());
                j += 1;
            }
        }
        (out, j)
    }

    fn parse_selector(&self, start: usize, end: usize) -> VarDictionary {
        let (ss, se) = self.trim_bounds(start, end);
        let mut parts = VarArray::new();
        let mut combinator = "descendant";
        let mut poison = String::new();
        let mut i = ss;
        while i < se {
            let c = self.s[i];
            if uss_space(c as i64) {
                i += 1;
                continue;
            }
            if c == '>' {
                if parts.is_empty() || combinator == "child" {
                    poison.push('>');
                } else {
                    combinator = "child";
                }
                i += 1;
                continue;
            }
            if c == '+' || c == '~' {
                poison.push(c);
                i += 1;
                continue;
            }
            let (mut simples, next) = self.read_compound(i, se);
            if next == i {
                i += 1;
                continue;
            }
            if !poison.is_empty() {
                let mut d = simple("unknown");
                d.set("text", &gd(&poison));
                simples.push_front(&d.to_variant());
                poison.clear();
            }
            let mut part = VarDictionary::new();
            part.set("combinator", combinator);
            part.set("simple", &simples);
            parts.push(&part.to_variant());
            combinator = "descendant";
            i = next;
        }
        if !poison.is_empty() || combinator == "child" {
            let text = if !poison.is_empty() { poison.clone() } else { ">".to_string() };
            let mut d = simple("unknown");
            d.set("text", &gd(&text));
            let mut arr = VarArray::new();
            arr.push(&d.to_variant());
            let mut part = VarDictionary::new();
            part.set("combinator", "descendant");
            part.set("simple", &arr);
            parts.push(&part.to_variant());
        }
        let mut out = VarDictionary::new();
        out.set("parts", &parts);
        out.set("span", &span(ss, se));
        out
    }

    fn parse_selector_group(&self, start: usize, end: usize) -> VarArray {
        let mut sels = VarArray::new();
        let mut from = start;
        loop {
            let comma = self.scan_to(from, &[','], Some(end)).min(end);
            sels.push(&self.parse_selector(from, comma).to_variant());
            if comma >= end {
                break;
            }
            from = comma + 1;
        }
        sels
    }

    /// UssParser._strip_comments; problems as (message, start, end).
    fn strip_comments(text: &S, problems: &mut Vec<(String, usize, usize)>, base: usize) -> String {
        if find(text, "/*", 0).is_none() {
            return strip(&text.iter().collect::<String>());
        }
        let mut out = String::new();
        let mut i = 0;
        while i < text.len() {
            let c = text[i];
            if c == '"' || c == '\'' {
                match find_quote_close(text, i) {
                    None => {
                        let rest: String = text[i..].iter().collect();
                        return strip(&(out + &rest));
                    }
                    Some(close) => {
                        out.extend(text[i..close].iter());
                        i = close;
                        continue;
                    }
                }
            }
            if c == '/' && i + 1 < text.len() && text[i + 1] == '*' {
                match find(text, "*/", i + 2) {
                    None => {
                        problems.push(("unterminated comment in declaration".into(), base + i, base + text.len()));
                        return strip(&out);
                    }
                    Some(close) => {
                        out.push(' ');
                        i = close + 2;
                        continue;
                    }
                }
            }
            out.push(c);
            i += 1;
        }
        strip(&out)
    }

    fn parse_declaration_list(&self, start: usize, end: usize, problems: &mut Vec<(String, usize, usize)>) -> VarArray {
        let mut decls = VarArray::new();
        let mut pos = start;
        while pos < end {
            while pos < end && (uss_space(self.ch(pos)) || starts(self.s, pos, "/*")) {
                if starts(self.s, pos, "/*") {
                    pos = find(self.s, "*/", pos + 2).map(|c| c + 2).unwrap_or(end);
                } else {
                    pos += 1;
                }
            }
            if pos >= end {
                break;
            }
            if self.ch(pos) == 59 {
                pos += 1;
                continue;
            }
            let from = pos;
            let colon = self.scan_to(from, &[':', ';', '}'], None);
            if colon >= end || self.ch(colon) != 58 {
                let to = colon.min(end);
                problems.push(("declaration without a value".into(), from, to));
                pos = to + 1;
                continue;
            }
            let stop = self.scan_to(colon + 1, &[';', '}'], Some(end)).min(end);
            let (vs, ve) = self.trim_bounds(colon + 1, stop);
            let property = strip(&sub(self.s, from, colon));
            let value = Self::strip_comments(&self.s[vs.min(self.len())..ve.min(self.len()).max(vs.min(self.len()))], problems, vs);
            let mut d = VarDictionary::new();
            d.set("property", &gd(&property));
            d.set("value", &gd(&value));
            d.set("span", &span(from, ve));
            decls.push(&d.to_variant());
            pos = stop + 1;
        }
        decls
    }

    fn first_quoted(text: &S) -> Option<String> {
        for i in 0..text.len() {
            let c = text[i];
            if c == '"' || c == '\'' {
                let close = find_quote_close(text, i)?;
                return Some(sub(text, i + 1, close - 1));
            }
        }
        None
    }

    fn parse_at_rule(&mut self) -> VarDictionary {
        let start = self.pos;
        let name_end = self.read_ident(self.pos + 1);
        let at_name = sub(self.s, self.pos + 1, name_end);
        let brace = self.scan_to(name_end, &['{', ';'], None);
        if brace < self.len() && self.ch(brace) == 123 {
            let end = self.end_of_block(brace);
            self.pos = end;
            let mut d = VarDictionary::new();
            d.set("kind", "unknown");
            d.set("at_rule", &gd(&at_name));
            d.set("span", &span(start, end));
            return d;
        }
        let end = if brace < self.len() { brace + 1 } else { self.len() };
        self.pos = end;
        if at_name == "import" {
            let text: Vec<char> = self.s[name_end.min(self.len())..end.min(self.len()).max(name_end.min(self.len()))].to_vec();
            match Self::first_quoted(&text) {
                None => {
                    self.w.push(("@import without a quoted path".into(), start, end));
                    let mut d = VarDictionary::new();
                    d.set("kind", "unknown");
                    d.set("span", &span(start, end));
                    return d;
                }
                Some(q) => {
                    let mut d = VarDictionary::new();
                    d.set("kind", "import");
                    d.set("url", &gd(&q));
                    d.set("span", &span(start, end));
                    d.set("resolved_sheet", -1i64);
                    return d;
                }
            }
        }
        let mut d = VarDictionary::new();
        d.set("kind", "unknown");
        d.set("at_rule", &gd(&at_name));
        d.set("span", &span(start, end));
        d
    }

    fn parse_rule(&mut self) -> VarDictionary {
        let start = self.pos;
        let n = self.len();
        let brace = self.scan_to(start, &['{'], None);
        if brace >= n {
            self.w.push(("rule without a block".into(), start, n));
            self.pos = n;
            let mut d = VarDictionary::new();
            d.set("kind", "unknown");
            d.set("span", &span(start, n));
            return d;
        }
        let (ss, se) = self.trim_bounds(start, brace);
        let block_end = self.end_of_block(brace);
        if block_end > n || self.ch(block_end.wrapping_sub(1)) != 125 {
            self.w.push(("unterminated rule block".into(), start, block_end));
        }
        let mut problems = vec![];
        let sels = self.parse_selector_group(ss, se);
        let decls = self.parse_declaration_list(brace + 1, block_end - 1, &mut problems);
        let mut rule = VarDictionary::new();
        rule.set("selectors", &sels);
        rule.set("declarations", &decls);
        rule.set("span", &span(ss, block_end));
        rule.set("selector_span", &span(ss, se));
        for p in problems {
            self.w.push(p);
        }
        self.pos = block_end;
        let mut d = VarDictionary::new();
        d.set("kind", "rule");
        d.set("rule", &rule);
        d
    }
}

/// [items Array, warnings Array of [message, start, end]] — UssParser.parse.
pub fn parse_uss(source: &GString) -> VarArray {
    let chars: Vec<char> = source.to_string().chars().collect();
    let mut p = Uss { s: &chars, pos: 0, w: vec![] };
    let mut items = VarArray::new();
    loop {
        p.skip_trivia();
        if p.pos >= p.len() {
            break;
        }
        let it = if p.ch(p.pos) == 64 { p.parse_at_rule() } else { p.parse_rule() };
        items.push(&it.to_variant());
    }
    let mut warns = VarArray::new();
    for (m, s, e) in &p.w {
        let mut a = VarArray::new();
        a.push(&gd(m).to_variant());
        a.push(&(*s as i64).to_variant());
        a.push(&(*e as i64).to_variant());
        warns.push(&a.to_variant());
    }
    let mut out = VarArray::new();
    out.push(&items.to_variant());
    out.push(&warns.to_variant());
    out
}

/// Native parse entry points (static).
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct UxmlNativeParser {
    base: Base<RefCounted>,
}

#[godot_api]
impl UxmlNativeParser {
    #[func]
    fn scan_uxml(source: GString) -> VarDictionary {
        scan_uxml(&source)
    }

    #[func]
    fn parse_uss(source: GString) -> VarArray {
        parse_uss(&source)
    }
}
