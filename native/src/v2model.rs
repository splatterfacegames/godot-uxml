//! Runtime v2's element table (phase 5, docs/design.md "The model native").
//!
//! The UXML parse fills this table directly (the native scan of parse.rs),
//! with no UxmlElement object per element. A `UxmlElement` becomes a handle
//! made on request (`UxmlDocumentModel.handle`): its fields are filled from
//! the row (`fill`), its children when they are first read. The native
//! cascade and the v2 runtime read the rows (local names, attributes, the
//! tree) without going through the engine.
//!
//! The rows are kept in preorder: a structural change (the part trees of
//! the controls, built on handles by UxmlParts) is written back with
//! `add_row` / `set_children` and `finalize` puts the rows in preorder again
//! (it returns the new index of every old row, for the handles).
use std::collections::HashMap;

use godot::prelude::*;

#[derive(Clone, Default)]
pub struct Attr {
    pub name: String,
    pub value: String,
    pub offset: i32,
}

#[derive(Clone, Default)]
pub struct Row {
    pub id: i32,
    pub prefix: String,
    pub local: String,
    pub attrs: Vec<Attr>,
    pub ots: i32,
    pub ote: i32,
    pub send: i32,
    pub parent: i32,
    pub children: Vec<u32>,
    /// The control that owns this part (-1: authored).
    pub part_of: i32,
    pub role: String,
    /// Unity's VisualElement.parent of an author child moved into a
    /// control's content container (the control), else -1.
    pub logical: i32,
    /// The instance id of the row's handle (0: none made).
    pub hid: i64,
}

impl Row {
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.iter().find(|a| a.name == name).map(|a| a.value.as_str())
    }
}

#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct UxmlNativeModel {
    base: Base<RefCounted>,
    pub rows: Vec<Row>,
    /// Handle instance id -> row.
    hmap: HashMap<i64, u32>,
    synth: bool,
    w_msg: PackedStringArray,
    w_start: PackedInt32Array,
    w_end: PackedInt32Array,
    /// (row, attribute) of the values that need entity decoding or
    /// whitespace normalization (decoded by UxmlParser.decode_entities).
    raw: Vec<(u32, u32)>,
    /// Bumped by every change of the rows (structure or attributes).
    pub version: u64,
}

fn gs(s: &str) -> GString {
    GString::from(s)
}

fn var_str(v: &Variant) -> String {
    match v.try_to::<GString>() {
        Ok(g) => g.to_string(),
        Err(_) => match v.try_to::<StringName>() {
            Ok(n) => n.to_string(),
            Err(_) => v.to_string(),
        },
    }
}

impl UxmlNativeModel {
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn row(&self, i: usize) -> &Row {
        &self.rows[i]
    }

    /// The subtree end (exclusive) of every row (preorder).
    pub fn ends(&self) -> Vec<i32> {
        let n = self.rows.len();
        let mut end: Vec<i32> = (0..n as i32).map(|i| i + 1).collect();
        let mut i = n;
        while i > 1 {
            i -= 1;
            let p = self.rows[i].parent;
            if p >= 0 && end[i] > end[p as usize] {
                end[p as usize] = end[i];
            }
        }
        end
    }

    fn attrs_to_var(&self, i: usize) -> VarArray {
        let mut out = VarArray::new();
        let kn = "name".to_variant();
        let kv = "value".to_variant();
        let ko = "offset".to_variant();
        for a in &self.rows[i].attrs {
            let mut d = VarDictionary::new();
            d.set(&kn, &gs(&a.name).to_variant());
            d.set(&kv, &gs(&a.value).to_variant());
            d.set(&ko, &a.offset.to_variant());
            out.push(&d.to_variant());
        }
        out
    }

    fn attrs_from_var(arr: &VarArray) -> Vec<Attr> {
        let kn = "name".to_variant();
        let kv = "value".to_variant();
        let ko = "offset".to_variant();
        let mut out = Vec::with_capacity(arr.len());
        for a in arr.iter_shared() {
            let Ok(d) = a.try_to::<VarDictionary>() else { continue };
            out.push(Attr {
                name: var_str(&d.get(&kn).unwrap_or_default()),
                value: var_str(&d.get(&kv).unwrap_or_default()),
                offset: d.get(&ko).and_then(|v| v.try_to::<i64>().ok()).unwrap_or(0) as i32,
            });
        }
        out
    }
}

#[godot_api]
impl UxmlNativeModel {
    /// Scans UXML `source` into a table (the native scan of
    /// UxmlParser._parse_native). A document without a root element gets a
    /// synthesized empty root (`synth_root()`).
    #[func]
    fn parse(source: GString) -> Gd<UxmlNativeModel> {
        let chars: Vec<char> = source.to_string().chars().collect();
        let (u, synth) = crate::parse::scan_chars(&chars);
        let n = u.local.len();
        let mut rows: Vec<Row> = Vec::with_capacity(n.max(1));
        for k in 0..n {
            rows.push(Row {
                id: u.id[k],
                prefix: u.prefix[k].clone(),
                local: u.local[k].clone(),
                attrs: vec![],
                ots: u.open_start[k],
                ote: u.open_end[k],
                send: u.source_end[k],
                parent: u.parent[k],
                children: vec![],
                part_of: -1,
                role: String::new(),
                logical: -1,
                hid: 0,
            });
        }
        for k in 0..n {
            let p = u.parent[k];
            if p >= 0 {
                rows[p as usize].children.push(k as u32);
            }
        }
        let mut raw = vec![];
        for a in 0..u.attr_el.len() {
            let e = u.attr_el[a] as usize;
            if u.attr_raw[a] {
                raw.push((e as u32, rows[e].attrs.len() as u32));
            }
            rows[e].attrs.push(Attr { name: u.attr_name[a].clone(), value: u.attr_value[a].clone(), offset: u.attr_offset[a] });
        }
        if synth {
            // UxmlParser: a root of its own (id 0), the kept elements dropped
            // (there are none without a root element).
            rows.clear();
            raw.clear();
            rows.push(Row { id: 0, parent: -1, part_of: -1, logical: -1, ..Default::default() });
        }
        let mut w_msg = PackedStringArray::new();
        for m in &u.w_msg {
            w_msg.push(&gs(m));
        }
        Gd::from_init_fn(|base| UxmlNativeModel {
            base,
            rows,
            hmap: HashMap::new(),
            synth,
            w_msg,
            w_start: PackedInt32Array::from(u.w_start.as_slice()),
            w_end: PackedInt32Array::from(u.w_end.as_slice()),
            raw,
            version: 0,
        })
    }

    #[func]
    fn synth_root(&self) -> bool {
        self.synth
    }

    /// The scan's problems: {w_msg, w_start, w_end}.
    #[func]
    fn scan_warnings(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        d.set("w_msg", &self.w_msg);
        d.set("w_start", &self.w_start);
        d.set("w_end", &self.w_end);
        d
    }

    /// The raw attribute values as [row, k, value, ...] for decoding.
    #[func]
    fn raw_values(&self) -> VarArray {
        let mut out = VarArray::new();
        for &(r, k) in &self.raw {
            out.push(&(r as i64).to_variant());
            out.push(&(k as i64).to_variant());
            out.push(&gs(&self.rows[r as usize].attrs[k as usize].value).to_variant());
        }
        out
    }

    #[func]
    fn set_attr_value(&mut self, row: i32, k: i32, value: GString) {
        if let Some(a) = self.rows.get_mut(row as usize).and_then(|r| r.attrs.get_mut(k as usize)) {
            a.value = value.to_string();
            self.version += 1;
        }
    }

    #[func]
    fn size(&self) -> i32 {
        self.rows.len() as i32
    }

    /// The fields of a handle of row i: [id, prefix, local, attributes,
    /// open_tag_start, open_tag_end, source_end, part_of row, part_role,
    /// child count, logical parent row].
    #[func]
    fn fill(&self, i: i32) -> VarArray {
        let mut out = VarArray::new();
        let Some(r) = self.rows.get(i as usize) else { return out };
        out.push(&r.id.to_variant());
        out.push(&gs(&r.prefix).to_variant());
        out.push(&gs(&r.local).to_variant());
        out.push(&self.attrs_to_var(i as usize).to_variant());
        out.push(&r.ots.to_variant());
        out.push(&r.ote.to_variant());
        out.push(&r.send.to_variant());
        out.push(&r.part_of.to_variant());
        out.push(&gs(&r.role).to_variant());
        out.push(&(r.children.len() as i64).to_variant());
        out.push(&r.logical.to_variant());
        out
    }

    /// Row i is a part of control row `owner` with `role` (-1: authored).
    #[func]
    fn set_part(&mut self, i: i32, owner: i32, role: GString) {
        if let Some(r) = self.rows.get_mut(i as usize) {
            r.part_of = owner;
            r.role = role.to_string();
            self.version += 1;
        }
    }

    #[func]
    fn children(&self, i: i32) -> PackedInt32Array {
        let Some(r) = self.rows.get(i as usize) else { return PackedInt32Array::new() };
        let v: Vec<i32> = r.children.iter().map(|&c| c as i32).collect();
        PackedInt32Array::from(v.as_slice())
    }

    #[func]
    fn parent(&self, i: i32) -> i32 {
        self.rows.get(i as usize).map(|r| r.parent).unwrap_or(-1)
    }

    #[func]
    fn local(&self, i: i32) -> GString {
        self.rows.get(i as usize).map(|r| gs(&r.local)).unwrap_or_default()
    }

    #[func]
    fn part_of(&self, i: i32) -> i32 {
        self.rows.get(i as usize).map(|r| r.part_of).unwrap_or(-1)
    }

    #[func]
    fn part_role(&self, i: i32) -> GString {
        self.rows.get(i as usize).map(|r| gs(&r.role)).unwrap_or_default()
    }

    #[func]
    fn logical_parent(&self, i: i32) -> i32 {
        self.rows.get(i as usize).map(|r| r.logical).unwrap_or(-1)
    }

    /// The first value of attribute `name` of row i, or null.
    #[func]
    fn attr(&self, i: i32, name: GString) -> Variant {
        let n = name.to_string();
        match self.rows.get(i as usize).and_then(|r| r.attr(&n)) {
            Some(v) => gs(v).to_variant(),
            None => Variant::nil(),
        }
    }

    /// The attributes of row i as UxmlElement.attributes has them.
    #[func]
    fn attributes(&self, i: i32) -> VarArray {
        if (i as usize) >= self.rows.len() {
            return VarArray::new();
        }
        self.attrs_to_var(i as usize)
    }

    /// Replaces the attributes of row i (an edit of its handle).
    #[func]
    fn set_attributes(&mut self, i: i32, attrs: VarArray) {
        if (i as usize) < self.rows.len() {
            self.rows[i as usize].attrs = Self::attrs_from_var(&attrs);
            self.version += 1;
        }
    }

    /// Binds the handle `id` (an instance id) to row i.
    #[func]
    fn bind_handle(&mut self, i: i32, id: i64) {
        if let Some(r) = self.rows.get_mut(i as usize) {
            if r.hid != 0 {
                self.hmap.remove(&r.hid);
            }
            r.hid = id;
            self.hmap.insert(id, i as u32);
        }
    }

    /// The row of the handle with instance id `id`, or -1.
    #[func]
    fn row_of(&self, id: i64) -> i32 {
        self.hmap.get(&id).map(|&r| r as i32).unwrap_or(-1)
    }

    pub fn row_of_id(&self, id: i64) -> Option<usize> {
        self.hmap.get(&id).map(|&r| r as usize)
    }

    /// The rows whose local name is in `names`, in preorder (`parts`: parts
    /// included).
    #[func]
    fn rows_named(&self, names: PackedStringArray, parts: bool) -> PackedInt32Array {
        let set: Vec<String> = names.as_slice().iter().map(|s| s.to_string()).collect();
        let mut out = vec![];
        for (i, r) in self.rows.iter().enumerate() {
            if (parts || r.part_of < 0) && set.iter().any(|s| *s == r.local) {
                out.push(i as i32);
            }
        }
        PackedInt32Array::from(out.as_slice())
    }

    /// Whether any row has one of the local names.
    #[func]
    fn has_local(&self, names: PackedStringArray) -> bool {
        let set: Vec<String> = names.as_slice().iter().map(|s| s.to_string()).collect();
        self.rows.iter().any(|r| set.iter().any(|s| *s == r.local))
    }

    /// The distinct local names, in order of first appearance.
    #[func]
    fn locals(&self) -> PackedStringArray {
        let mut seen: Vec<&str> = vec![];
        for r in &self.rows {
            if !seen.contains(&r.local.as_str()) {
                seen.push(&r.local);
            }
        }
        let mut out = PackedStringArray::new();
        for s in seen {
            out.push(&gs(s));
        }
        out
    }

    /// `<Style>` references in document order, as UxmlLoader._collect_style_refs
    /// walks them: [style row, scope row (its parent), src (null: none)].
    #[func]
    fn style_refs(&self) -> VarArray {
        let mut out = VarArray::new();
        for (i, r) in self.rows.iter().enumerate() {
            if i == 0 || r.local != "Style" {
                continue;
            }
            let mut e = VarArray::new();
            e.push(&(i as i64).to_variant());
            e.push(&(r.parent as i64).to_variant());
            match r.attr("src") {
                Some(v) => e.push(&gs(v).to_variant()),
                None => e.push(&Variant::nil()),
            }
            out.push(&e.to_variant());
        }
        out
    }

    /// The events of UxmlLoader._report_unsupported_tags in its order:
    /// [kind, row, attribute index] with kind 0 an attribute outside
    /// `known_attrs` (first of each name), 1 a tag of `feature_tags` (every
    /// element), 2 a tag outside `known_tags` and `feature_tags` (first of
    /// each tag). Rows whose tag is in `skip_tags` are skipped.
    #[func]
    fn unsupported(&self, known_attrs: PackedStringArray, known_tags: PackedStringArray, feature_tags: PackedStringArray, skip_tags: PackedStringArray) -> VarArray {
        let ka: Vec<String> = known_attrs.as_slice().iter().map(|s| s.to_string()).collect();
        let kt: Vec<String> = known_tags.as_slice().iter().map(|s| s.to_string()).collect();
        let ft: Vec<String> = feature_tags.as_slice().iter().map(|s| s.to_string()).collect();
        let st: Vec<String> = skip_tags.as_slice().iter().map(|s| s.to_string()).collect();
        let mut seen_a: Vec<&str> = vec![];
        let mut seen_t: Vec<&str> = vec![];
        let mut out = VarArray::new();
        let push = |out: &mut VarArray, k: i64, r: usize, a: i64| {
            let mut e = VarArray::new();
            e.push(&k.to_variant());
            e.push(&(r as i64).to_variant());
            e.push(&a.to_variant());
            out.push(&e.to_variant());
        };
        for (i, r) in self.rows.iter().enumerate() {
            if st.iter().any(|s| *s == r.local) {
                continue;
            }
            for (k, a) in r.attrs.iter().enumerate() {
                if a.name.contains(':') || ka.iter().any(|s| *s == a.name) {
                    continue;
                }
                if seen_a.contains(&a.name.as_str()) {
                    continue;
                }
                seen_a.push(&a.name);
                push(&mut out, 0, i, k as i64);
            }
            if kt.iter().any(|s| *s == r.local) {
                continue;
            }
            if ft.iter().any(|s| *s == r.local) {
                push(&mut out, 1, i, -1);
                continue;
            }
            if seen_t.contains(&r.local.as_str()) {
                continue;
            }
            seen_t.push(&r.local);
            push(&mut out, 2, i, -1);
        }
        out
    }

    /// A new row (a part built by UxmlParts): returns its index. It is
    /// placed in the tree by `set_children` of its parent.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn add_row(&mut self, id: i32, prefix: GString, local: GString, attrs: VarArray, spans: PackedInt32Array, part_of: i32, role: GString) -> i32 {
        let s = spans.as_slice();
        let sp = |k: usize| s.get(k).copied().unwrap_or(0);
        self.rows.push(Row {
            id,
            prefix: prefix.to_string(),
            local: local.to_string(),
            attrs: Self::attrs_from_var(&attrs),
            ots: sp(0),
            ote: sp(1),
            send: sp(2),
            parent: -1,
            children: vec![],
            part_of,
            role: role.to_string(),
            logical: -1,
            hid: 0,
        });
        self.version += 1;
        (self.rows.len() - 1) as i32
    }

    /// Writes built part trees back in one call (UxmlParts._sync_built).
    /// `spec` is a flat Array of entries [row, id, prefix, local, attributes,
    /// spans (PackedInt32Array), part_of, role, parent, logical, handle id]:
    /// `row` -1 for a new row (else the existing row, whose attributes are
    /// replaced and whose subtree is kept unless it is a parent of later
    /// entries), `part_of` and `logical` a row or -2 - k for the new row of
    /// entry k, `parent` the index of the parent entry (-1: a top entry,
    /// whose children are the entries naming it). Returns the row of each
    /// entry.
    #[func]
    fn sync_entries(&mut self, spec: VarArray) -> PackedInt32Array {
        let n = spec.len();
        let mut rows_of: Vec<i32> = Vec::with_capacity(n);
        let mut parents: Vec<i32> = Vec::with_capacity(n);
        let mut late: Vec<(usize, i32, i32, i32)> = vec![];
        let mut has_kids = vec![false; n];
        for k in 0..n {
            let e = spec.at(k).to::<VarArray>();
            let row = e.at(0).to::<i64>() as i32;
            let attrs = Self::attrs_from_var(&e.at(4).to::<VarArray>());
            let parent = e.at(8).to::<i64>() as i32;
            let part_of = e.at(6).to::<i64>() as i32;
            let logical = e.at(9).to::<i64>() as i32;
            let hid = e.at(10).to::<i64>();
            let r = if row >= 0 {
                self.rows[row as usize].attrs = attrs;
                row
            } else {
                let sp = e.at(5).to::<PackedInt32Array>();
                let s = sp.as_slice();
                let g = |q: usize| s.get(q).copied().unwrap_or(0);
                self.rows.push(Row {
                    id: e.at(1).to::<i64>() as i32,
                    prefix: var_str(&e.at(2)),
                    local: var_str(&e.at(3)),
                    attrs,
                    ots: g(0),
                    ote: g(1),
                    send: g(2),
                    parent: -1,
                    children: vec![],
                    part_of: -1,
                    role: var_str(&e.at(7)),
                    logical: -1,
                    hid: 0,
                });
                (self.rows.len() - 1) as i32
            };
            if hid != 0 && self.rows[r as usize].hid != hid {
                if self.rows[r as usize].hid != 0 {
                    self.hmap.remove(&self.rows[r as usize].hid);
                }
                self.rows[r as usize].hid = hid;
                self.hmap.insert(hid, r as u32);
            }
            late.push((r as usize, part_of, logical, row));
            rows_of.push(r);
            parents.push(parent);
            if parent >= 0 {
                has_kids[parent as usize] = true;
            }
        }
        let res = |v: i32, rows_of: &Vec<i32>| -> i32 {
            if v <= -2 {
                rows_of.get((-2 - v) as usize).copied().unwrap_or(-1)
            } else {
                v
            }
        };
        for &(r, po, lp, row) in &late {
            if row < 0 {
                self.rows[r].part_of = res(po, &rows_of);
            }
            if lp != -1 {
                self.rows[r].logical = res(lp, &rows_of);
            }
        }
        // Children: of every entry that is a parent of later entries.
        let mut kids: Vec<Vec<u32>> = vec![vec![]; n];
        for k in 0..n {
            if parents[k] >= 0 {
                kids[parents[k] as usize].push(rows_of[k] as u32);
            }
        }
        for k in 0..n {
            let explicit = spec.at(k).to::<VarArray>().len() > 11;
            if !has_kids[k] && !explicit {
                continue;
            }
            let r = rows_of[k] as usize;
            for &c in &kids[k] {
                self.rows[c as usize].parent = r as i32;
            }
            self.rows[r].children = std::mem::take(&mut kids[k]);
        }
        self.version += 1;
        PackedInt32Array::from(rows_of.as_slice())
    }

    /// The children of row i (rows), in order; their parent is set.
    #[func]
    fn set_children(&mut self, i: i32, kids: PackedInt32Array) {
        let i = i as usize;
        if i >= self.rows.len() {
            return;
        }
        let ks: Vec<u32> = kids.as_slice().iter().map(|&k| k as u32).collect();
        for &k in &ks {
            if let Some(r) = self.rows.get_mut(k as usize) {
                r.parent = i as i32;
            }
        }
        self.rows[i].children = ks;
        self.version += 1;
    }

    #[func]
    fn set_logical_parent(&mut self, i: i32, p: i32) {
        if let Some(r) = self.rows.get_mut(i as usize) {
            r.logical = p;
        }
    }

    /// Puts the rows in preorder again after structural changes; rows no
    /// longer in the tree are dropped. Returns the new index of every old
    /// row (-1: dropped).
    #[func]
    fn finalize(&mut self) -> PackedInt32Array {
        let n = self.rows.len();
        let mut order: Vec<u32> = Vec::with_capacity(n);
        let mut stack: Vec<u32> = vec![0];
        while let Some(i) = stack.pop() {
            order.push(i);
            for &c in self.rows[i as usize].children.iter().rev() {
                stack.push(c);
            }
        }
        let mut map = vec![-1i32; n];
        for (k, &o) in order.iter().enumerate() {
            map[o as usize] = k as i32;
        }
        let identity = order.len() == n && order.iter().enumerate().all(|(k, &o)| k as u32 == o);
        if !identity {
            let old = std::mem::take(&mut self.rows);
            let mut rows: Vec<Row> = Vec::with_capacity(order.len());
            for &o in &order {
                let mut r = old[o as usize].clone();
                r.parent = if r.parent >= 0 { map[r.parent as usize] } else { -1 };
                r.part_of = if r.part_of >= 0 { map[r.part_of as usize] } else { -1 };
                r.logical = if r.logical >= 0 { map[r.logical as usize] } else { -1 };
                r.children = r.children.iter().map(|&c| map[c as usize] as u32).collect();
                rows.push(r);
            }
            self.rows = rows;
            self.hmap.clear();
            for (k, r) in self.rows.iter().enumerate() {
                if r.hid != 0 {
                    self.hmap.insert(r.hid, k as u32);
                }
            }
            self.raw = self
                .raw
                .iter()
                .filter_map(|&(r, a)| if map[r as usize] >= 0 { Some((map[r as usize] as u32, a)) } else { None })
                .collect();
            self.version += 1;
        }
        PackedInt32Array::from(map.as_slice())
    }

    /// The tree as UssCascade._index_tree records it (preorder): parent,
    /// sel_parent (the logical parent of moved author children), end,
    /// local, prefix, open tag start and end.
    #[func]
    fn tree_arrays(&self) -> VarDictionary {
        let n = self.rows.len();
        let mut parent = Vec::with_capacity(n);
        let mut selp = Vec::with_capacity(n);
        let mut local = PackedStringArray::new();
        let mut prefix = PackedStringArray::new();
        let mut ots = Vec::with_capacity(n);
        let mut ote = Vec::with_capacity(n);
        for r in &self.rows {
            parent.push(r.parent);
            selp.push(if r.logical >= 0 { r.logical } else { r.parent });
            local.push(&gs(&r.local));
            prefix.push(&gs(&r.prefix));
            ots.push(r.ots);
            ote.push(r.ote);
        }
        let mut d = VarDictionary::new();
        d.set("parent", &PackedInt32Array::from(parent.as_slice()));
        d.set("sel_parent", &PackedInt32Array::from(selp.as_slice()));
        d.set("end", &PackedInt32Array::from(self.ends().as_slice()));
        d.set("local", &local);
        d.set("prefix", &prefix);
        d.set("ots", &PackedInt32Array::from(ots.as_slice()));
        d.set("ote", &PackedInt32Array::from(ote.as_slice()));
        d
    }

    /// The rows whose `enabled` attribute is "false" (any case), not parts.
    #[func]
    fn disabled_rows(&self) -> PackedInt32Array {
        let mut out = vec![];
        for (i, r) in self.rows.iter().enumerate() {
            if r.part_of >= 0 {
                continue;
            }
            if let Some(v) = r.attr("enabled") {
                if v.to_lowercase() == "false" {
                    out.push(i as i32);
                }
            }
        }
        PackedInt32Array::from(out.as_slice())
    }

    /// The first row (preorder) runtime v2 does not cover by its tags and
    /// attributes (UxmlRuntimeV2Glue.uncovered): [row, kind, attribute]
    /// with kind 1 a part tag outside `part_tags`, 2 an element tag outside
    /// `tags`, 3 an attribute outside `common` and the tag's list in
    /// `attrs` (tags with an empty or no list are not checked); [] if none.
    #[func]
    fn first_uncovered(&self, tags: PackedStringArray, part_tags: PackedStringArray, attrs: VarDictionary, common: PackedStringArray) -> VarArray {
        let tg: Vec<String> = tags.as_slice().iter().map(|s| s.to_string()).collect();
        let pt: Vec<String> = part_tags.as_slice().iter().map(|s| s.to_string()).collect();
        let cm: Vec<String> = common.as_slice().iter().map(|s| s.to_string()).collect();
        let mut allowed: HashMap<String, Vec<String>> = HashMap::new();
        for (k, v) in attrs.iter_shared() {
            let list: Vec<String> = v.try_to::<PackedStringArray>().map(|a| a.as_slice().iter().map(|s| s.to_string()).collect()).unwrap_or_default();
            allowed.insert(var_str(&k), list);
        }
        let mut out = VarArray::new();
        let hit = |row: usize, kind: i64, a: &str| {
            let mut e = VarArray::new();
            e.push(&(row as i64).to_variant());
            e.push(&kind.to_variant());
            e.push(&gs(a).to_variant());
            e
        };
        for (i, r) in self.rows.iter().enumerate() {
            if r.part_of >= 0 {
                if !pt.iter().any(|s| *s == r.local) {
                    out = hit(i, 1, "");
                    return out;
                }
                continue;
            }
            if !tg.iter().any(|s| *s == r.local) {
                out = hit(i, 2, "");
                return out;
            }
            let Some(list) = allowed.get(&r.local) else { continue };
            if list.is_empty() {
                continue;
            }
            for a in &r.attrs {
                if !cm.iter().any(|s| *s == a.name) && !list.iter().any(|s| *s == a.name) {
                    out = hit(i, 3, &a.name);
                    return out;
                }
            }
        }
        out
    }

    /// The rows of the elements with a `tabindex` attribute (parts
    /// included) and the first `name` of each element that is not a part,
    /// as UxmlRuntimeV2Glue._index reads them: {tabindex: bool, names:
    /// PackedStringArray (one per row, "" for none or a part), named:
    /// PackedByteArray (1: has a name)}.
    #[func]
    fn index_info(&self) -> VarDictionary {
        let mut tab = false;
        let mut names = PackedStringArray::new();
        let mut named = vec![0u8; self.rows.len()];
        for (i, r) in self.rows.iter().enumerate() {
            let mut nm: Option<&str> = None;
            for a in &r.attrs {
                if a.name == "tabindex" {
                    tab = true;
                } else if a.name == "name" && nm.is_none() {
                    nm = Some(&a.value);
                }
            }
            if r.part_of >= 0 {
                names.push(&GString::new());
                continue;
            }
            match nm {
                Some(v) => {
                    names.push(&gs(v));
                    named[i] = 1;
                }
                None => names.push(&GString::new()),
            }
        }
        let mut d = VarDictionary::new();
        d.set("tabindex", tab);
        d.set("names", &names);
        d.set("named", &PackedByteArray::from(named.as_slice()));
        d
    }

    /// Whether any row has an attribute `name`.
    #[func]
    fn any_attr(&self, name: GString) -> bool {
        let n = name.to_string();
        self.rows.iter().any(|r| r.attrs.iter().any(|a| a.name == n))
    }

    /// The rows whose local name is not in `names` (`parts`: parts included).
    #[func]
    fn rows_except(&self, names: PackedStringArray, parts: bool) -> PackedInt32Array {
        let set: Vec<String> = names.as_slice().iter().map(|s| s.to_string()).collect();
        let mut out = vec![];
        for (i, r) in self.rows.iter().enumerate() {
            if (parts || r.part_of < 0) && !set.iter().any(|s| *s == r.local) {
                out.push(i as i32);
            }
        }
        PackedInt32Array::from(out.as_slice())
    }

    /// The kinds UxmlRuntimeV2Glue._index gives the elements (the core's
    /// K_* and flags): parts by `part_kinds` (local -> kind), K_EDIT for
    /// the `editor` role, F_UNPICKED for the roles of `unpicked`; other
    /// elements by `control_kinds`; F_PART on the rows of `pooled`.
    #[func]
    fn v2_kinds(&self, part_kinds: VarDictionary, unpicked: VarDictionary, control_kinds: VarDictionary, pooled: PackedInt32Array) -> PackedByteArray {
        const K_EDIT: u8 = 5;
        const F_ATTRS_OK: u8 = 0x80;
        const F_PART: u8 = 0x20;
        const F_UNPICKED: u8 = 0x10;
        let map = |d: &VarDictionary| -> HashMap<String, u8> {
            d.iter_shared().map(|(k, v)| (var_str(&k), v.try_to::<i64>().unwrap_or(0) as u8)).collect()
        };
        let pk = map(&part_kinds);
        let ck = map(&control_kinds);
        let un: Vec<String> = unpicked.keys_array().iter_shared().map(|k| var_str(&k)).collect();
        let mut out = vec![0u8; self.rows.len()];
        for (i, r) in self.rows.iter().enumerate() {
            if r.part_of >= 0 {
                let mut k = pk.get(&r.local).copied().unwrap_or(0);
                if r.role == "editor" {
                    k = K_EDIT;
                }
                if un.iter().any(|s| *s == r.role) {
                    k |= F_UNPICKED;
                }
                out[i] = k | F_ATTRS_OK | F_PART;
                continue;
            }
            let c = ck.get(&r.local).copied().unwrap_or(0);
            if c != 0 {
                out[i] = c | F_ATTRS_OK;
            }
        }
        for &p in pooled.as_slice() {
            if let Some(k) = out.get_mut(p as usize) {
                *k |= F_PART;
            }
        }
        PackedByteArray::from(out.as_slice())
    }

    /// The document's names as UxmlRuntimeV2Glue._index keeps them: the
    /// first element of each `name` (its first `name` attribute), parts and
    /// the rows of `pooled` excluded. {name: row}.
    #[func]
    fn name_index(&self, pooled: PackedInt32Array) -> VarDictionary {
        let mut skip = vec![false; self.rows.len()];
        for &p in pooled.as_slice() {
            if let Some(x) = skip.get_mut(p as usize) {
                *x = true;
            }
        }
        let mut seen: HashMap<&str, ()> = HashMap::new();
        let mut d = VarDictionary::new();
        for (i, r) in self.rows.iter().enumerate() {
            if r.part_of >= 0 || skip[i] {
                continue;
            }
            if let Some(v) = r.attr("name") {
                if seen.insert(v, ()).is_none() {
                    d.set(&gs(v).to_variant(), &(i as i64).to_variant());
                }
            }
        }
        d
    }

    /// The rows that can get an interaction Control or an editor
    /// (UxmlRuntimeV2Glue._make_proxies): the Toggle, RadioButton, content
    /// and editor parts, the elements of `control_tags`, and the
    /// VisualElements and TemplateContainers with focusable="true".
    #[func]
    fn proxy_rows(&self, control_tags: PackedStringArray) -> PackedInt32Array {
        let ct: Vec<String> = control_tags.as_slice().iter().map(|s| s.to_string()).collect();
        let mut out = vec![];
        for (i, r) in self.rows.iter().enumerate() {
            let hit = if r.part_of >= 0 {
                r.local == "Toggle" || r.local == "RadioButton" || r.role == "content" || r.role == "editor"
            } else if ct.iter().any(|s| *s == r.local) {
                true
            } else {
                (r.local == "VisualElement" || r.local == "TemplateContainer") && r.attr("focusable") == Some("true")
            };
            if hit {
                out.push(i as i32);
            }
        }
        PackedInt32Array::from(out.as_slice())
    }

    /// The number of `Foldout` ancestors of row i (parts included).
    #[func]
    fn foldout_depth(&self, i: i32) -> i32 {
        let mut d = 0;
        let mut p = self.rows.get(i as usize).map(|r| r.parent).unwrap_or(-1);
        while p >= 0 {
            if self.rows[p as usize].local == "Foldout" {
                d += 1;
            }
            p = self.rows[p as usize].parent;
        }
        d
    }
}
