//! Native per-element cascade for `UssCascade` (core/uss_cascade.gd).
//!
//! GDScript keeps everything that runs once per document — tree indexing
//! and rule compilation (with its diagnostics) — and hands the compiled
//! tables over in `setup()`. Everything that runs per element per restyle
//! happens here: attribute reads, pseudo-state bits, ancestor bloom, bucket
//! gathering, selector matching, the declaration-level cascade, output
//! Dictionaries and diagnostics. The few semantically fiddly, rarely-missed
//! steps call back into the GDScript implementation (memoized here):
//! `var()` substitution, shorthand expansion and inline-style parsing — so
//! their behaviour is identical by construction.
//!
//! The algorithm mirrors `UssCascade.update()` / `_compute()` line by line;
//! output (computed Dictionaries incl. key order, warnings incl. order)
//! must be identical. bench/equiv.gd checks it against the original
//! resolver.

use std::collections::HashMap;
use std::rc::Rc;

use godot::prelude::*;

const BIT_DISABLED: i32 = 32;
const BIT_ENABLED: i32 = 64;
const INLINE_SPEC: i64 = 1 << 62;
const F_CUSTOM: i32 = 1;
const F_VAR: i32 = 2;

fn state_bit(name: &str) -> i32 {
    match name {
        "hover" => 1,
        "active" => 2,
        "inactive" => 4,
        "focus" => 8,
        "checked" => 16,
        "disabled" => 32,
        "enabled" => 64,
        "selected" => 128,
        _ => 0,
    }
}

/// Two bloom-filter bits for an interned feature (any stable hash works:
/// element bits and selector needs are both computed here).
fn fbits(kind: u64, id: u32) -> u64 {
    let mut h = (id as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ kind.wrapping_mul(0xC2B2_AE3D_27D4_EB4F);
    h ^= h >> 29;
    h = h.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    (1u64 << (h & 63)) | (1u64 << ((h >> 6) & 63))
}
const FK_TYPE: u64 = 1;
const FK_NAME: u64 = 2;
const FK_CLASS: u64 = 3;

struct Compound {
    types: Vec<u32>,
    names: Vec<u32>,
    classes: Vec<u32>,
    mask: i32,
    root: bool,
    child: bool,
}

struct Sel {
    rule: usize,
    spec: i64,
    parts: Vec<Compound>,
    states: VarArray,
    need: u64,
    origins: Option<Rc<Vec<Variant>>>,
    entries: Option<Rc<Vec<Option<Rc<Vec<Variant>>>>>>,
}

/// One declaration (rule or inline).
#[derive(Clone)]
struct Decl {
    prop: GString,
    pid: u32,
    val: GString,
    flags: i32,
    /// Static shorthand expansion (None when the value contains var()).
    exp: Option<Rc<Vec<(u32, Variant)>>>,
}

struct Rule {
    scope_idx: i32,
    scope_lo: i32,
    scope_hi: i32,
    sheet: i64,
    item: i64,
    file: GString,
    decls: Vec<Decl>,
}

struct Inline {
    decls: Vec<Decl>,
    problems: Vec<GString>,
}

/// A for_children entry: computed {value, origin} plus the entry Dictionary.
#[derive(Clone)]
struct Item {
    pid: u32,
    value: Variant,
    origin: Variant,
    #[allow(dead_code)]
    entry: Variant,
}

struct Customs {
    id: i64,
    dict: VarDictionary,
}

#[derive(PartialEq, Clone, Default)]
struct AncKey {
    classes: Vec<u32>,
    name: Option<u32>,
    bits: i32,
}

struct Elem {
    obj: Gd<Object>,
    var: Variant,
    local: u32,
    local_var: Variant,
    local_name: String,
    leaf: bool,
    tag: String,
    line: i64,
    column: i64,
    offset: i64,
}

struct Props {
    names: Vec<GString>,
    keys: Vec<Variant>,
    inherited: Vec<bool>,
    supported: Vec<bool>,
    custom: Vec<bool>,
    lay: Vec<i8>,
    index: HashMap<String, u32>,
}

pub struct Cascade {
    // shared strings
    interned: HashMap<String, u32>,
    props: Props,
    inherited_set: VarDictionary,
    supported_set: VarDictionary,
    implicit: VarDictionary,
    // callbacks into the GDScript implementation
    cb_subst: Callable,
    cb_expand: Callable,
    cb_inline: Callable,
    exp_cache: HashMap<(u32, String), Rc<Vec<(u32, Variant)>>>,
    inline_cache: HashMap<String, Rc<Inline>>,
    subst_memo: HashMap<(i64, String), Option<GString>>,
    // compiled rules
    rules: Vec<Rule>,
    sels: Vec<Sel>,
    b_name: HashMap<u32, Vec<u32>>,
    b_class: HashMap<u32, Vec<u32>>,
    b_type: HashMap<u32, Vec<u32>>,
    b_any: Vec<u32>,
    anc_classes: Vec<bool>, // by interned id (grown on demand)
    anc_names: Vec<bool>,
    anc_states: i32,
    inline_origins: Vec<Variant>,
    // element index
    els: Vec<Elem>,
    parent: Vec<i32>,
    end: Vec<i32>,
    index: HashMap<i64, usize>,
    source_file: GString,
    // per element state
    cls_set: Vec<Vec<u32>>,
    name: Vec<Option<u32>>,
    sig_cls: Vec<Variant>,
    sig_name: Vec<Variant>,
    sig_style: Vec<Variant>,
    sig_en: Vec<Variant>,
    sig_en_false: Vec<bool>,
    sig_bits: Vec<i32>,
    own_none: Vec<u8>,
    eff_dis: Vec<u8>,
    eff_gone: Vec<u8>,
    display_key: Variant,
    none_val: Variant,
    sig_valid: Vec<bool>,
    anc_key: Vec<AncKey>,
    bloom: Vec<u64>,
    own_bloom: Vec<u64>,
    fc: Vec<Rc<Vec<Item>>>,
    fc_dict: Vec<VarDictionary>,
    fc_customs: Vec<Rc<Customs>>,
    warn: Vec<Vec<Variant>>,
    lay_vals: Vec<Vec<Option<GString>>>,
    lay_ver: Vec<u64>,
    computed_once: bool,
    next_cid: i64,
    // scratch
    k_name: Variant,
    k_value: Variant,
    k_origin: Variant,
    k_kind: Variant,
    k_from: Variant,
    v_class: Variant,
    v_name: Variant,
    v_style: Variant,
    v_enabled: Variant,
    v_inherited: Variant,
    sn_attributes: StringName,
    empty_fc: Rc<Vec<Item>>,
    empty_customs: Rc<Customs>,
    pub last_old: VarArray,
}

fn args(v: &[Variant]) -> VarArray {
    let mut a = VarArray::new();
    for x in v {
        a.push(x);
    }
    a
}

fn gs(v: &Variant) -> GString {
    v.try_to::<GString>().unwrap_or_default()
}

impl Cascade {
    fn intern(&mut self, s: &str) -> u32 {
        if let Some(&id) = self.interned.get(s) {
            return id;
        }
        let id = self.interned.len() as u32;
        self.interned.insert(s.to_string(), id);
        id
    }

    fn pid(&mut self, prop: &GString) -> u32 {
        let s = prop.to_string();
        if let Some(&id) = self.props.index.get(&s) {
            return id;
        }
        let id = self.props.names.len() as u32;
        let custom = s.starts_with("--");
        let key = prop.to_variant();
        self.props.inherited.push(custom || self.inherited_set.contains_key(&key));
        self.props.supported.push(custom || self.supported_set.contains_key(&key));
        self.props.custom.push(custom);
        self.props.lay.push(
            crate::layout::LAYOUT_PROPS.iter().position(|p| *p == s.as_str()).map(|x| x as i8).unwrap_or(-1),
        );
        self.props.names.push(prop.clone());
        self.props.keys.push(key);
        self.props.index.insert(s, id);
        id
    }

    fn psa_ids(&mut self, v: &Variant) -> Vec<u32> {
        let a = v.to::<PackedStringArray>();
        a.as_slice().iter().map(|x| self.intern(&x.to_string())).collect()
    }

    fn expand(&mut self, pid: u32, raw: &GString) -> Rc<Vec<(u32, Variant)>> {
        let key = (pid, raw.to_string());
        if let Some(e) = self.exp_cache.get(&key) {
            return e.clone();
        }
        let prop = self.props.names[pid as usize].clone();
        let res = self.cb_expand.callv(&args(&[prop.to_variant(), raw.clone().to_variant()]));
        let arr = res.try_to::<VarArray>().unwrap_or_default();
        let mut out = Vec::with_capacity(arr.len());
        for pair in arr.iter_shared() {
            let pa = pair.to::<VarArray>();
            let lh = gs(&pa.at(0));
            let lid = self.pid(&lh);
            out.push((lid, pa.at(1)));
        }
        let rc = Rc::new(out);
        if self.exp_cache.len() > 16384 {
            self.exp_cache.clear();
        }
        self.exp_cache.insert(key, rc.clone());
        rc
    }

    fn make_decl(&mut self, prop: GString, val: GString, flags: i32, static_exp: &Variant) -> Decl {
        let pid = self.pid(&prop);
        let exp = if flags & F_VAR != 0 || static_exp.is_nil() {
            None
        } else {
            let arr = static_exp.to::<VarArray>();
            let mut out = Vec::with_capacity(arr.len());
            for pair in arr.iter_shared() {
                let pa = pair.to::<VarArray>();
                let lh = gs(&pa.at(0));
                let lid = self.pid(&lh);
                out.push((lid, pa.at(1)));
            }
            Some(Rc::new(out))
        };
        Decl { prop, pid, val, flags, exp }
    }

    fn inline(&mut self, text: &GString) -> Rc<Inline> {
        let key = text.to_string();
        if let Some(i) = self.inline_cache.get(&key) {
            return i.clone();
        }
        let res = self.cb_inline.callv(&args(&[text.clone().to_variant()])).to::<VarArray>();
        let dp = res.at(0).to::<PackedStringArray>();
        let dv = res.at(1).to::<PackedStringArray>();
        let df = res.at(2).to::<PackedInt32Array>();
        let de = res.at(3).to::<VarArray>();
        let probs = res.at(4).to::<VarArray>();
        let mut decls = Vec::with_capacity(dp.len());
        for d in 0..dp.len() {
            let decl = self.make_decl(dp.as_slice()[d].clone(), dv.as_slice()[d].clone(), df.as_slice()[d], &de.at(d));
            decls.push(decl);
        }
        let mut problems = Vec::new();
        let k_message = "message".to_variant();
        for p in probs.iter_shared() {
            let pd = p.to::<VarDictionary>();
            problems.push(gs(&pd.get(&k_message).unwrap_or_default()));
        }
        let rc = Rc::new(Inline { decls, problems });
        if self.inline_cache.len() > 4096 {
            self.inline_cache.clear();
        }
        self.inline_cache.insert(key, rc.clone());
        rc
    }

    fn inline_origin(&mut self, d: usize) -> Variant {
        while self.inline_origins.len() <= d {
            let mut o = VarDictionary::new();
            o.set(&self.k_kind, "inline");
            o.set("decl_index", self.inline_origins.len() as i64);
            self.inline_origins.push(o.to_variant());
        }
        self.inline_origins[d].clone()
    }

    fn origins_for(&mut self, s: usize) -> Rc<Vec<Variant>> {
        if let Some(o) = &self.sels[s].origins {
            return o.clone();
        }
        let r = self.sels[s].rule;
        let states = self.sels[s].states.clone();
        let rule = &self.rules[r];
        let mut out = Vec::with_capacity(rule.decls.len());
        for d in 0..rule.decls.len() {
            let mut o = VarDictionary::new();
            o.set(&self.k_kind, "rule");
            o.set("sheet", rule.sheet);
            o.set("item", rule.item);
            o.set("decl_index", d as i64);
            o.set("file", &rule.file);
            if !states.is_empty() {
                o.set("states", &states.duplicate_shallow());
            }
            out.push(o.to_variant());
        }
        let rc = Rc::new(out);
        self.sels[s].origins = Some(rc.clone());
        rc
    }

    fn entries_for(&mut self, s: usize, origins: &Rc<Vec<Variant>>) -> Rc<Vec<Option<Rc<Vec<Variant>>>>> {
        if let Some(e) = &self.sels[s].entries {
            return e.clone();
        }
        let r = self.sels[s].rule;
        let mut out = Vec::new();
        for (d, decl) in self.rules[r].decls.iter().enumerate() {
            match &decl.exp {
                None => out.push(None),
                Some(pairs) => {
                    let mut lst = Vec::with_capacity(pairs.len());
                    for (_, v) in pairs.iter() {
                        let mut e = VarDictionary::new();
                        e.set(&self.k_value, v);
                        e.set(&self.k_origin, &origins[d]);
                        lst.push(e.to_variant());
                    }
                    out.push(Some(Rc::new(lst)));
                }
            }
        }
        let rc = Rc::new(out);
        self.sels[s].entries = Some(rc.clone());
        rc
    }

    fn diag(&self, i: usize, kind: &str, message: String) -> Variant {
        let e = &self.els[i];
        let mut d = VarDictionary::new();
        d.set("kind", kind);
        d.set("message", message.as_str());
        d.set("file", &self.source_file);
        d.set("offset", e.offset);
        d.set("line", e.line);
        d.set("column", e.column);
        d.to_variant()
    }

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    pub fn setup(cas: &Gd<Object>, cb: &VarDictionary) -> Option<Cascade> {
        let get = |name: &str| cas.get(name);
        let doc = get("doc").try_to::<Gd<Object>>().ok()?;
        let source = gs(&doc.get("source"));
        let path = gs(&doc.get("path"));
        let mut c = Cascade {
            interned: HashMap::new(),
            props: Props { names: vec![], keys: vec![], inherited: vec![], supported: vec![], custom: vec![], lay: vec![], index: HashMap::new() },
            inherited_set: cb.get("inherited")?.try_to().ok()?,
            supported_set: cb.get("supported")?.try_to().ok()?,
            implicit: cb.get("implicit")?.try_to().ok()?,
            cb_subst: cb.get("subst")?.try_to().ok()?,
            cb_expand: cb.get("expand")?.try_to().ok()?,
            cb_inline: cb.get("inline")?.try_to().ok()?,
            exp_cache: HashMap::new(),
            inline_cache: HashMap::new(),
            subst_memo: HashMap::new(),
            rules: vec![],
            sels: vec![],
            b_name: HashMap::new(),
            b_class: HashMap::new(),
            b_type: HashMap::new(),
            b_any: vec![],
            anc_classes: vec![],
            anc_names: vec![],
            anc_states: 0,
            inline_origins: vec![],
            els: vec![],
            parent: vec![],
            end: vec![],
            index: HashMap::new(),
            source_file: path,
            cls_set: vec![],
            name: vec![],
            sig_cls: vec![],
            sig_name: vec![],
            sig_style: vec![],
            sig_en: vec![],
            sig_en_false: vec![],
            sig_bits: vec![],
            own_none: vec![],
            eff_dis: vec![],
            eff_gone: vec![],
            display_key: "display".to_variant(),
            none_val: "none".to_variant(),
            sig_valid: vec![],
            anc_key: vec![],
            bloom: vec![],
            own_bloom: vec![],
            fc: vec![],
            fc_dict: vec![],
            fc_customs: vec![],
            warn: vec![],
            lay_vals: vec![],
            lay_ver: vec![],
            computed_once: false,
            next_cid: 1,
            k_name: "name".to_variant(),
            k_value: "value".to_variant(),
            k_origin: "origin".to_variant(),
            k_kind: "kind".to_variant(),
            k_from: "from".to_variant(),
            v_class: "class".to_variant(),
            v_name: "name".to_variant(),
            v_style: "style".to_variant(),
            v_enabled: "enabled".to_variant(),
            v_inherited: "inherited".to_variant(),
            sn_attributes: StringName::from("attributes"),
            empty_fc: Rc::new(vec![]),
            empty_customs: Rc::new(Customs { id: 0, dict: VarDictionary::new() }),
            last_old: VarArray::new(),
        };

        // Line starts of the UXML source (code-point offsets, like Godot).
        let chars: Vec<char> = source.to_string().chars().collect();
        let mut newlines: Vec<usize> = vec![];
        for (k, ch) in chars.iter().enumerate() {
            if *ch == '\n' {
                newlines.push(k);
            }
        }

        // Element index (preorder, from the GDScript side).
        let els = get("els").to::<VarArray>();
        let parent = get("_parent").to::<PackedInt32Array>();
        let end = get("_end").to::<PackedInt32Array>();
        let n = els.len();
        let sn_local = StringName::from("local");
        let sn_prefix = StringName::from("prefix");
        let sn_children = StringName::from("children");
        let sn_offset = StringName::from("open_tag_start");
        for i in 0..n {
            let var = els.at(i);
            let obj = var.try_to::<Gd<Object>>().ok()?;
            let local = gs(&obj.get(&sn_local)).to_string();
            let prefix = gs(&obj.get(&sn_prefix)).to_string();
            let leaf = obj.get(&sn_children).to::<VarArray>().is_empty();
            let offset = obj.get(&sn_offset).try_to::<i64>().unwrap_or(0);
            // UxmlDiagnostic.line_col
            let limit = (offset.max(0) as usize).min(chars.len());
            let (line, column) = if offset <= 0 || limit == 0 {
                (1i64, 1i64)
            } else {
                let cnt = newlines.partition_point(|&p| p < limit);
                if cnt == 0 {
                    (1, limit as i64 + 1)
                } else {
                    let nl = newlines[cnt - 1];
                    (cnt as i64 + 1, (limit - nl) as i64)
                }
            };
            let tag = if prefix.is_empty() { local.clone() } else { format!("{prefix}:{local}") };
            let lid = c.intern(&local);
            c.index.insert(obj.instance_id().to_i64(), i);
            c.els.push(Elem { obj, var, local: lid, local_var: local.to_variant(), local_name: local.clone(), leaf, tag, line, column, offset });
        }
        c.parent = parent.as_slice().to_vec();
        c.end = end.as_slice().to_vec();
        c.cls_set = vec![vec![]; n];
        c.name = vec![None; n];
        c.sig_cls = vec![Variant::nil(); n];
        c.sig_name = vec![Variant::nil(); n];
        c.sig_style = vec![Variant::nil(); n];
        c.sig_en = vec![Variant::nil(); n];
        c.sig_en_false = vec![false; n];
        c.own_none = vec![0; n];
        c.eff_dis = vec![0; n];
        c.eff_gone = vec![0; n];
        c.sig_bits = vec![0; n];
        c.sig_valid = vec![false; n];
        c.anc_key = vec![AncKey::default(); n];
        c.bloom = vec![0; n];
        c.own_bloom = vec![0; n];
        c.fc = vec![c.empty_fc.clone(); n];
        c.fc_dict = vec![VarDictionary::new(); n];
        c.fc_customs = vec![c.empty_customs.clone(); n];
        c.warn = vec![vec![]; n];
        c.lay_vals = vec![vec![None; crate::layout::LAYOUT_PROPS.len()]; n];
        c.lay_ver = vec![0; n];

        // Compiled rules.
        let r_scope_idx = get("_rule_scope_idx").to::<PackedInt32Array>();
        let r_lo = get("_rule_scope_lo").to::<PackedInt32Array>();
        let r_hi = get("_rule_scope_hi").to::<PackedInt32Array>();
        let r_sheet = get("_rule_sheet").to::<PackedInt32Array>();
        let r_item = get("_rule_item").to::<PackedInt32Array>();
        let r_file = get("_rule_file").to::<PackedStringArray>();
        let r_dprop = get("_rule_dprop").to::<VarArray>();
        let r_dval = get("_rule_dval").to::<VarArray>();
        let r_dflag = get("_rule_dflag").to::<VarArray>();
        let r_dexp = get("_rule_dexp").to::<VarArray>();
        for r in 0..r_sheet.len() {
            let dp = r_dprop.at(r).to::<PackedStringArray>();
            let dv = r_dval.at(r).to::<PackedStringArray>();
            let df = r_dflag.at(r).to::<PackedInt32Array>();
            let de = r_dexp.at(r).to::<VarArray>();
            let mut decls = Vec::with_capacity(dp.len());
            for d in 0..dp.len() {
                let decl = c.make_decl(dp.as_slice()[d].clone(), dv.as_slice()[d].clone(), df.as_slice()[d], &de.at(d));
                decls.push(decl);
            }
            c.rules.push(Rule {
                scope_idx: r_scope_idx.as_slice()[r],
                scope_lo: r_lo.as_slice()[r],
                scope_hi: r_hi.as_slice()[r],
                sheet: r_sheet.as_slice()[r] as i64,
                item: r_item.as_slice()[r] as i64,
                file: r_file.as_slice()[r].clone(),
                decls,
            });
        }
        let s_rule = get("_sel_rule").to::<PackedInt32Array>();
        let s_spec = get("_sel_spec").to::<PackedInt64Array>();
        let s_parts = get("_sel_parts").to::<VarArray>();
        let s_states = get("_sel_states").to::<VarArray>();
        for s in 0..s_rule.len() {
            let parts_v = s_parts.at(s).to::<VarArray>();
            let mut parts = Vec::with_capacity(parts_v.len());
            for p in parts_v.iter_shared() {
                let cp = p.to::<VarArray>();
                parts.push(Compound {
                    types: c.psa_ids(&cp.at(0)),
                    names: c.psa_ids(&cp.at(1)),
                    classes: c.psa_ids(&cp.at(2)),
                    mask: cp.at(3).to::<i64>() as i32,
                    root: cp.at(4).to::<bool>(),
                    child: cp.at(5).to::<bool>(),
                });
            }
            let mut need = 0u64;
            for cp in parts.iter().take(parts.len().saturating_sub(1)) {
                for &x in &cp.types {
                    need |= fbits(FK_TYPE, x);
                }
                for &x in &cp.names {
                    need |= fbits(FK_NAME, x);
                }
                for &x in &cp.classes {
                    need |= fbits(FK_CLASS, x);
                }
            }
            c.sels.push(Sel {
                rule: s_rule.as_slice()[s] as usize,
                spec: s_spec.as_slice()[s],
                parts,
                states: s_states.at(s).to::<VarArray>(),
                need,
                origins: None,
                entries: None,
            });
        }
        for (field, target) in [("_b_name", 0), ("_b_class", 1), ("_b_type", 2)] {
            let d = get(field).to::<VarDictionary>();
            for (k, v) in d.iter_shared() {
                let id = c.intern(&gs(&k).to_string());
                let lst: Vec<u32> = v.to::<PackedInt32Array>().as_slice().iter().map(|&x| x as u32).collect();
                match target {
                    0 => c.b_name.insert(id, lst),
                    1 => c.b_class.insert(id, lst),
                    _ => c.b_type.insert(id, lst),
                };
            }
        }
        c.b_any = get("_b_any").to::<PackedInt32Array>().as_slice().iter().map(|&x| x as u32).collect();
        let ac = get("_anc_classes").to::<VarDictionary>();
        for (k, _) in ac.iter_shared() {
            let id = c.intern(&gs(&k).to_string()) as usize;
            if c.anc_classes.len() <= id {
                c.anc_classes.resize(id + 1, false);
            }
            c.anc_classes[id] = true;
        }
        let an = get("_anc_names").to::<VarDictionary>();
        for (k, _) in an.iter_shared() {
            let id = c.intern(&gs(&k).to_string()) as usize;
            if c.anc_names.len() <= id {
                c.anc_names.resize(id + 1, false);
            }
            c.anc_names[id] = true;
        }
        c.anc_states = get("_anc_states").to::<i64>() as i32;
        Some(c)
    }

    // ---------------------------------------------------------------------
    // Update
    // ---------------------------------------------------------------------

    fn class_set(&mut self, raw: &Variant, local_name: &Variant) -> Vec<u32> {
        let mut out: Vec<u32> = vec![];
        if !raw.is_nil() {
            let text = gs(raw).to_string();
            for part in text.split([' ', '\t', '\n', '\r']) {
                if part.is_empty() {
                    continue;
                }
                let id = self.intern(part);
                if !out.contains(&id) {
                    out.push(id);
                }
            }
        }
        // implicit unity-* classes
        if let Some(arr) = self.implicit.get(local_name) {
            for cls in arr.to::<VarArray>().iter_shared() {
                let id = self.intern(&gs(&cls).to_string());
                if !out.contains(&id) {
                    out.push(id);
                }
            }
        }
        out
    }

    fn own_bits(&self, i: usize) -> u64 {
        let mut b = fbits(FK_TYPE, self.els[i].local);
        if let Some(nm) = self.name[i] {
            b |= fbits(FK_NAME, nm);
        }
        for &c in &self.cls_set[i] {
            b |= fbits(FK_CLASS, c);
        }
        b
    }

    fn anc_key_of(&self, i: usize) -> AncKey {
        let mut cl: Vec<u32> = self.cls_set[i]
            .iter()
            .copied()
            .filter(|&c| self.anc_classes.get(c as usize).copied().unwrap_or(false))
            .collect();
        cl.sort_unstable();
        let name = self.name[i].filter(|&n| self.anc_names.get(n as usize).copied().unwrap_or(false));
        AncKey { classes: cl, name, bits: self.sig_bits[i] & self.anc_states }
    }

    fn idx_of(&self, v: &Variant) -> Option<usize> {
        let o = v.try_to::<Gd<Object>>().ok()?;
        self.index.get(&o.instance_id().to_i64()).copied()
    }

    pub fn update(
        &mut self,
        options: &VarDictionary,
        force: bool,
        key_bits: &PackedInt32Array,
        styles: &mut VarDictionary,
        scan_all: bool,
        dirty: &PackedInt32Array,
    ) -> PackedInt32Array {
        let n = self.els.len();
        let mut global = 0i32;
        if let Some(a) = options.get("active_states") {
            for s in a.to::<VarArray>().iter_shared() {
                global |= state_bit(&gs(&s).to_string());
            }
        }
        let kb = key_bits.as_slice();
        let has_keys = !kb.is_empty();
        let mut dis_ov: HashMap<usize, u8> = HashMap::new();
        if let Some(d) = options.get("disabled_elements") {
            for (k, _) in d.to::<VarDictionary>().iter_shared() {
                if let Some(i) = self.idx_of(&k) {
                    dis_ov.insert(i, 1);
                }
            }
        }
        if let Some(d) = options.get("enabled_elements") {
            for (k, _) in d.to::<VarDictionary>().iter_shared() {
                if let Some(i) = self.idx_of(&k) {
                    dis_ov.insert(i, 2);
                }
            }
        }
        let mut es_bits: HashMap<usize, i32> = HashMap::new();
        if let Some(d) = options.get("element_states") {
            for (k, v) in d.to::<VarDictionary>().iter_shared() {
                if let Some(i) = self.idx_of(&k) {
                    let mut m = 0;
                    if let Ok(arr) = v.try_to::<VarArray>() {
                        for s in arr.iter_shared() {
                            m |= state_bit(&gs(&s).to_string());
                        }
                    } else if let Ok(psa) = v.try_to::<PackedStringArray>() {
                        for s in psa.as_slice() {
                            m |= state_bit(&s.to_string());
                        }
                    }
                    es_bits.insert(i, m);
                }
            }
        }

        let full = force || !self.computed_once;
        let scan_all = scan_all || full;
        let mut reread = vec![false; if scan_all { 0 } else { n }];
        if !scan_all {
            for &d in dirty.as_slice() {
                if d >= 0 && (d as usize) < n {
                    reread[d as usize] = true;
                }
            }
        }
        let mut changed = PackedInt32Array::new();
        self.last_old = VarArray::new();
        let mut inh_dirty = vec![false; n];
        let mut anc_until: i32 = -1;
        for i in 0..n {
            // Cascade inputs: first class/name/style/enabled attribute —
            // re-read only for dirty elements unless scanning everything.
            let mut c = Variant::nil();
            let mut nm = Variant::nil();
            let mut st = Variant::nil();
            let mut en = Variant::nil();
            let (mut hc, mut hn, mut hs, mut he) = (false, false, false, false);
            let attrs = if scan_all || reread[i] {
                self.els[i].obj.get(&self.sn_attributes).to::<VarArray>()
            } else {
                // Only the enabled attribute is needed for state bits.
                he = self.sig_en_false[i];
                VarArray::new()
            };
            for a in attrs.iter_shared() {
                let ad = a.to::<VarDictionary>();
                let an = ad.get(&self.k_name).unwrap_or_default();
                if !hc && an == self.v_class {
                    c = ad.get(&self.k_value).unwrap_or_default();
                    hc = true;
                } else if !hn && an == self.v_name {
                    nm = ad.get(&self.k_value).unwrap_or_default();
                    hn = true;
                } else if !hs && an == self.v_style {
                    st = ad.get(&self.k_value).unwrap_or_default();
                    hs = true;
                } else if !he && an == self.v_enabled {
                    en = ad.get(&self.k_value).unwrap_or_default();
                    he = true;
                }
            }
            let en_false = if scan_all || reread[i] {
                let f = he && gs(&en).to_string() == "false";
                self.sig_en[i] = en.clone();
                self.sig_en_false[i] = f;
                f
            } else {
                he
            };
            let mut own_d: u8 = if en_false { 1 } else { 0 };
            if let Some(&ov) = dis_ov.get(&i) {
                own_d = ov;
            }
            let p = self.parent[i];
            let mut b = global;
            if own_d == 1 || (p >= 0 && (self.sig_bits[p as usize] & BIT_DISABLED) != 0) {
                b |= BIT_DISABLED;
            } else {
                b |= BIT_ENABLED;
            }
            if let Some(&eb) = es_bits.get(&i) {
                b |= eb;
            }
            if has_keys {
                b |= kb[i];
            }
            // A clean (not re-read) element can only change through its
            // state bits: skip the Variant compares entirely.
            let reread_i = scan_all || reread[i];
            let own = full
                || !self.sig_valid[i]
                || b != self.sig_bits[i]
                || (reread_i && (c != self.sig_cls[i] || nm != self.sig_name[i] || st != self.sig_style[i]));
            if own && !reread_i {
                // State-bit change only: attributes (and everything derived
                // from them) are unchanged.
                self.sig_bits[i] = b;
                let ak = self.anc_key_of(i);
                if !full && ak != self.anc_key[i] && self.end[i] > anc_until {
                    anc_until = self.end[i];
                }
                self.anc_key[i] = ak;
            } else if own {
                if full || !self.sig_valid[i] || c != self.sig_cls[i] {
                    let local = self.els[i].local_var.clone();
                    self.cls_set[i] = self.class_set(&c, &local);
                }
                self.name[i] = if nm.is_nil() { None } else { Some(self.intern(&gs(&nm).to_string())) };
                self.sig_cls[i] = c;
                self.sig_name[i] = nm;
                self.sig_style[i] = st;
                self.sig_bits[i] = b;
                self.sig_valid[i] = true;
                self.own_bloom[i] = self.own_bits(i);
                let ak = self.anc_key_of(i);
                if !full && ak != self.anc_key[i] && self.end[i] > anc_until {
                    anc_until = self.end[i];
                }
                self.anc_key[i] = ak;
            }
            self.bloom[i] = if p >= 0 { self.bloom[p as usize] | self.own_bloom[p as usize] } else { 0 };
            if !own && !inh_dirty[i] && (i as i32) >= anc_until {
                continue;
            }
            let el_var = self.els[i].var.clone();
            let old = styles.get(&el_var);
            let old_fc = self.fc_dict[i].clone();
            let new_dict = self.compute(i);
            match old {
                Some(ov) if !full => {
                    let od = ov.to::<VarDictionary>();
                    if od != new_dict {
                        changed.push(i as i32);
                        self.last_old.push(&ov);
                        styles.set(&el_var, &new_dict);
                    } else if od.keys_array() == new_dict.keys_array() {
                        // Equal in the same key order: keep the old object
                        // (identity-keyed caches downstream stay valid).
                    } else {
                        styles.set(&el_var, &new_dict);
                    }
                }
                Some(ov) => {
                    changed.push(i as i32);
                    self.last_old.push(&ov);
                    styles.set(&el_var, &new_dict);
                }
                None => {
                    changed.push(i as i32);
                    self.last_old.push(&Variant::nil());
                    styles.set(&el_var, &new_dict);
                }
            }
            if full || old_fc != self.fc_dict[i] {
                let mut ch = i + 1;
                let e = self.end[i] as usize;
                while ch < e {
                    inh_dirty[ch] = true;
                    ch = self.end[ch] as usize;
                }
            }
        }
        self.computed_once = true;
        changed
    }

    // ---------------------------------------------------------------------
    // Matching
    // ---------------------------------------------------------------------

    fn match_compound(&self, cp: &Compound, i: usize, scope_idx: i32) -> bool {
        for &t in &cp.types {
            if self.els[i].local != t {
                return false;
            }
        }
        for &x in &cp.names {
            if self.name[i] != Some(x) {
                return false;
            }
        }
        if !cp.classes.is_empty() {
            let set = &self.cls_set[i];
            for x in &cp.classes {
                if !set.contains(x) {
                    return false;
                }
            }
        }
        if cp.mask != 0 && (self.sig_bits[i] & cp.mask) != cp.mask {
            return false;
        }
        if cp.root && (scope_idx < 0 || i as i32 != scope_idx) {
            return false;
        }
        true
    }

    fn match_from(&self, parts: &[Compound], k: usize, i: usize, scope_idx: i32) -> bool {
        let cp = &parts[k];
        if !self.match_compound(cp, i, scope_idx) {
            return false;
        }
        if k == 0 {
            return true;
        }
        let mut p = self.parent[i];
        if cp.child {
            return p >= 0 && self.match_from(parts, k - 1, p as usize, scope_idx);
        }
        while p >= 0 {
            if self.match_from(parts, k - 1, p as usize, scope_idx) {
                return true;
            }
            p = self.parent[p as usize];
        }
        false
    }

    // ---------------------------------------------------------------------
    // Per-element computation (mirrors UssCascade._compute)
    // ---------------------------------------------------------------------

    fn compute(&mut self, i: usize) -> VarDictionary {
        let p = self.parent[i];
        let mut warns: Vec<Variant> = vec![];

        // Candidate selectors from the buckets this element can hit.
        let mut cand: Vec<u32> = vec![];
        if let Some(nm) = self.name[i] {
            if let Some(l) = self.b_name.get(&nm) {
                cand.extend_from_slice(l);
            }
        }
        for c in &self.cls_set[i] {
            if let Some(l) = self.b_class.get(c) {
                cand.extend_from_slice(l);
            }
        }
        if let Some(l) = self.b_type.get(&self.els[i].local) {
            cand.extend_from_slice(l);
        }
        cand.extend_from_slice(&self.b_any);
        cand.sort_unstable();

        let bloom = self.bloom[i];
        // candidates: (decl, origin, spec, shared entries)
        let mut c_decl: Vec<Decl> = vec![];
        let mut c_origin: Vec<Variant> = vec![];
        let mut c_spec: Vec<i64> = vec![];
        let mut c_ent: Vec<Option<Rc<Vec<Variant>>>> = vec![];

        let nc = cand.len();
        let mut k = 0;
        while k < nc {
            let r = self.sels[cand[k] as usize].rule;
            let mut k_end = k + 1;
            while k_end < nc && self.sels[cand[k_end] as usize].rule == r {
                k_end += 1;
            }
            let (lo, hi, scope_idx) = {
                let rule = &self.rules[r];
                (rule.scope_lo, rule.scope_hi, rule.scope_idx)
            };
            if lo != -2 && ((i as i32) < lo || (i as i32) >= hi) {
                k = k_end;
                continue;
            }
            let mut best_sel: i64 = -1;
            let mut best_spec: i64 = -1;
            for &ss in &cand[k..k_end] {
                let sel = &self.sels[ss as usize];
                if sel.need != 0 && (bloom & sel.need) != sel.need {
                    continue;
                }
                if !self.match_from(&sel.parts, sel.parts.len() - 1, i, scope_idx) {
                    continue;
                }
                if best_sel < 0 || sel.spec > best_spec {
                    best_sel = ss as i64;
                    best_spec = sel.spec;
                }
            }
            k = k_end;
            if best_sel < 0 {
                continue;
            }
            let bs = best_sel as usize;
            let origins = self.origins_for(bs);
            let ents = self.entries_for(bs, &origins);
            let nd = self.rules[r].decls.len();
            for d in 0..nd {
                c_decl.push(self.rules[r].decls[d].clone());
                c_origin.push(origins[d].clone());
                c_spec.push(best_spec);
                c_ent.push(ents[d].clone());
            }
        }

        let st = self.sig_style[i].clone();
        if !st.is_nil() {
            let inl = self.inline(&gs(&st));
            for (d, decl) in inl.decls.iter().enumerate() {
                c_decl.push(decl.clone());
                let o = self.inline_origin(d);
                c_origin.push(o);
                c_spec.push(INLINE_SPEC);
                c_ent.push(None);
            }
            for msg in &inl.problems {
                let m = format!("style attribute of <{}>: {}", self.els[i].tag, msg);
                warns.push(self.diag(i, "malformed", m));
            }
        }

        let ncand = c_decl.len();
        // Custom properties: inherited values, then the winning declarations.
        let cpair = if p >= 0 { self.fc_customs[p as usize].clone() } else { self.empty_customs.clone() };
        let mut customs = cpair.dict.clone();
        let mut cid = cpair.id;
        let any_custom = c_decl.iter().any(|d| d.flags & F_CUSTOM != 0);
        if any_custom {
            let mut cw: Vec<(u32, usize)> = vec![];
            for j in 0..ncand {
                if c_decl[j].flags & F_CUSTOM == 0 {
                    continue;
                }
                let pid = c_decl[j].pid;
                match cw.iter_mut().find(|(q, _)| *q == pid) {
                    None => cw.push((pid, j)),
                    Some(slot) => {
                        if c_spec[j] >= c_spec[slot.1] {
                            slot.1 = j;
                        }
                    }
                }
            }
            customs = customs.duplicate_shallow();
            for (pid, j) in &cw {
                customs.set(&self.props.keys[*pid as usize], &c_decl[*j].val);
            }
            cid = -1;
        }

        // Substitute, expand, and pick the winner per longhand.
        struct Best {
            pid: u32,
            val: Variant,
            origin: Variant,
            failed: bool,
            spec: i64,
            ent: Option<Variant>,
        }
        let mut best: Vec<Best> = vec![];
        let mut best_ix: HashMap<u32, usize> = HashMap::new();
        for j in 0..ncand {
            let flags = c_decl[j].flags;
            let pid = c_decl[j].pid;
            let mut failed = false;
            let raw: GString;
            let pairs: Rc<Vec<(u32, Variant)>>;
            let mut ents: Option<Rc<Vec<Variant>>> = None;
            if flags & F_VAR != 0 {
                let val = c_decl[j].val.clone();
                let sub: Option<GString> = if flags & F_CUSTOM != 0 {
                    let r = self.cb_subst.callv(&args(&[val.to_variant(), customs.to_variant(), c_decl[j].prop.to_variant()]));
                    r.try_to::<GString>().ok()
                } else if cid > 0 {
                    let key = (cid, val.to_string());
                    match self.subst_memo.get(&key) {
                        Some(v) => v.clone(),
                        None => {
                            let r = self.cb_subst.callv(&args(&[val.clone().to_variant(), customs.clone().to_variant(), GString::new().to_variant()]));
                            let v = r.try_to::<GString>().ok();
                            if self.subst_memo.len() > 65536 {
                                self.subst_memo.clear();
                            }
                            self.subst_memo.insert(key, v.clone());
                            v
                        }
                    }
                } else {
                    let r = self.cb_subst.callv(&args(&[val.clone().to_variant(), customs.clone().to_variant(), GString::new().to_variant()]));
                    r.try_to::<GString>().ok()
                };
                match sub {
                    Some(s) => raw = s,
                    None => {
                        failed = true;
                        raw = val;
                    }
                }
                pairs = self.expand(pid, &raw);
            } else {
                raw = c_decl[j].val.clone();
                pairs = c_decl[j].exp.clone().unwrap_or_else(|| Rc::new(vec![]));
                ents = c_ent[j].clone();
            }
            if pairs.is_empty() {
                let m = format!("{}: {} -- wrong number of values; declaration dropped", c_decl[j].prop, raw);
                warns.push(self.diag(i, "invalid-shorthand", m));
                continue;
            }
            let sp = c_spec[j];
            for (pk, (lh, v)) in pairs.iter().enumerate() {
                let ent = ents.as_ref().map(|e| e[pk].clone());
                match best_ix.get(lh) {
                    None => {
                        best_ix.insert(*lh, best.len());
                        best.push(Best { pid: *lh, val: v.clone(), origin: c_origin[j].clone(), failed, spec: sp, ent });
                    }
                    Some(&slot) => {
                        if sp >= best[slot].spec {
                            let b = &mut best[slot];
                            b.val = v.clone();
                            b.origin = c_origin[j].clone();
                            b.failed = failed;
                            b.spec = sp;
                            b.ent = ent;
                        }
                    }
                }
            }
        }

        let (mut computed, mut comp): (VarDictionary, Vec<Item>) = if p >= 0 {
            (self.fc_dict[p as usize].duplicate_shallow(), (*self.fc[p as usize]).clone())
        } else {
            (VarDictionary::new(), vec![])
        };
        for b in &best {
            let pidx = b.pid as usize;
            if b.failed {
                let m = format!("{}: var() reference could not be resolved; declaration dropped", self.props.names[pidx]);
                warns.push(self.diag(i, "unresolved-var", m));
                continue;
            }
            let entry = match &b.ent {
                Some(e) => e.clone(),
                None => {
                    let mut e = VarDictionary::new();
                    e.set(&self.k_value, &b.val);
                    e.set(&self.k_origin, &b.origin);
                    e.to_variant()
                }
            };
            computed.set(&self.props.keys[pidx], &entry);
            let item = Item { pid: b.pid, value: b.val.clone(), origin: b.origin.clone(), entry };
            match comp.iter_mut().find(|it| it.pid == b.pid) {
                Some(it) => *it = item,
                None => comp.push(item),
            }
            if !self.props.supported[pidx] {
                let m = format!(
                    "\"{}\" is not a supported USS property; the value is kept but has no effect",
                    self.props.names[pidx]
                );
                warns.push(self.diag(i, "unsupported-property", m));
            }
        }

        self.warn[i] = warns;
        // Layout-relevant values for the native flex pass (versioned).
        let mut lv: Vec<Option<GString>> = vec![None; crate::layout::LAYOUT_PROPS.len()];
        for it in &comp {
            let li = self.props.lay[it.pid as usize];
            if li >= 0 {
                lv[li as usize] = it.value.try_to::<GString>().ok();
            }
        }
        if lv != self.lay_vals[i] {
            self.lay_vals[i] = lv;
            self.lay_ver[i] += 1;
        }
        // display:none on the element itself (for effective_flags).
        self.own_none[i] = match computed.get(&self.display_key) {
            Some(e) => {
                let v = e.try_to::<VarDictionary>().ok().and_then(|d| d.get(&self.k_value)).unwrap_or_default();
                if v == self.none_val { 1 } else { 0 }
            }
            None => 0,
        };
        if self.els[i].leaf {
            self.fc[i] = self.empty_fc.clone();
            self.fc_dict[i] = VarDictionary::new();
            self.fc_customs[i] = cpair;
            return computed;
        }
        let node = self.els[i].var.clone();
        let mut fc_list: Vec<Item> = Vec::with_capacity(comp.len());
        let mut fc_dict = VarDictionary::new();
        for it in &comp {
            if !self.props.inherited[it.pid as usize] {
                continue;
            }
            let mut wrap = VarDictionary::new();
            wrap.set(&self.k_kind, &self.v_inherited);
            wrap.set(&self.k_from, &node);
            wrap.set(&self.k_origin, &it.origin);
            let wrap_v = wrap.to_variant();
            let mut e = VarDictionary::new();
            e.set(&self.k_value, &it.value);
            e.set(&self.k_origin, &wrap_v);
            let ev = e.to_variant();
            fc_dict.set(&self.props.keys[it.pid as usize], &ev);
            fc_list.push(Item { pid: it.pid, value: it.value.clone(), origin: wrap_v, entry: ev });
        }
        if !any_custom {
            self.fc_customs[i] = cpair;
        } else {
            let mut fcc = VarDictionary::new();
            for it in &fc_list {
                if self.props.custom[it.pid as usize] {
                    fcc.set(&self.props.keys[it.pid as usize], &it.value);
                }
            }
            self.fc_customs[i] = Rc::new(Customs { id: self.next_cid, dict: fcc });
            self.next_cid += 1;
        }
        self.fc[i] = Rc::new(fc_list);
        self.fc_dict[i] = fc_dict;
        computed
    }

    pub fn len(&self) -> usize {
        self.els.len()
    }

    /// Direct children (preorder indices) of element i.
    pub fn children(&self, i: usize) -> Vec<usize> {
        let mut out = vec![];
        let mut ch = i + 1;
        let e = self.end[i] as usize;
        while ch < e {
            out.push(ch);
            ch = self.end[ch] as usize;
        }
        out
    }

    pub fn non_visual(&self, i: usize) -> bool {
        self.els[i].local_name == "UXML" || self.els[i].local_name == "Style"
    }

    pub fn is_scroll_view(&self, i: usize) -> bool {
        self.els[i].local_name == "ScrollView"
    }

    pub fn element_var(&self, i: usize) -> Variant {
        self.els[i].var.clone()
    }

    pub fn file(&self) -> GString {
        self.source_file.clone()
    }

    pub fn location(&self, i: usize) -> (i64, i64, i64) {
        let e = &self.els[i];
        (e.offset, e.line, e.column)
    }

    pub fn layout_values(&self, i: usize) -> &[Option<GString>] {
        &self.lay_vals[i]
    }

    pub fn layout_version(&self, i: usize) -> u64 {
        self.lay_ver[i]
    }

    pub fn element_warnings(&self) -> VarArray {
        let mut out = VarArray::new();
        for w in &self.warn {
            for d in w {
                out.push(d);
            }
        }
        out
    }

    /// Effective disabled / display:none (self or ancestor) per element;
    /// returns the indices whose flags flipped since the last call.
    pub fn effective_flags(&mut self) -> (PackedInt32Array, PackedByteArray, PackedByteArray) {
        let n = self.els.len();
        let mut flipped = PackedInt32Array::new();
        for i in 0..n {
            let d = if self.sig_bits[i] & BIT_DISABLED != 0 { 1 } else { 0 };
            let p = self.parent[i];
            let g = if self.own_none[i] == 1 || (p >= 0 && self.eff_gone[p as usize] == 1) { 1 } else { 0 };
            if d != self.eff_dis[i] || g != self.eff_gone[i] {
                self.eff_dis[i] = d;
                self.eff_gone[i] = g;
                flipped.push(i as i32);
            }
        }
        (flipped, PackedByteArray::from(self.eff_dis.as_slice()), PackedByteArray::from(self.eff_gone.as_slice()))
    }

    pub fn disabled_flags(&self) -> PackedByteArray {
        let mut out = PackedByteArray::new();
        out.resize(self.els.len());
        let s = out.as_mut_slice();
        for (i, b) in self.sig_bits.iter().enumerate() {
            s[i] = if b & BIT_DISABLED != 0 { 1 } else { 0 };
        }
        out
    }
}

// -------------------------------------------------------------------------
// Godot class
// -------------------------------------------------------------------------

/// Native backend of `UssCascade`. Created by the GDScript cascade after it
/// compiled its rules; see core/uss_cascade.gd.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct UxmlNativeCascade {
    base: Base<RefCounted>,
    inner: Option<Cascade>,
    layout_in: Option<crate::layout::LayoutIn>,
    recs: crate::layout::RecCache,
}

#[godot_api]
impl UxmlNativeCascade {
    /// Reads the compiled tables of a GDScript `UssCascade`. `callbacks`:
    /// subst(value, customs, seed_prop) / expand(prop, raw) / inline(text)
    /// Callables, and the INHERITED / SUPPORTED / IMPLICIT_CLASSES tables.
    /// Returns false (GDScript then stays on its own path) if anything is
    /// not in the expected shape.
    #[func]
    fn setup(&mut self, cascade: Gd<Object>, callbacks: VarDictionary) -> bool {
        self.inner = Cascade::setup(&cascade, &callbacks);
        self.inner.is_some()
    }

    #[func]
    fn update(
        &mut self,
        options: VarDictionary,
        force: bool,
        key_bits: PackedInt32Array,
        mut styles: VarDictionary,
        scan_all: bool,
        dirty: PackedInt32Array,
    ) -> PackedInt32Array {
        match self.inner.as_mut() {
            Some(c) => c.update(&options, force, &key_bits, &mut styles, scan_all, &dirty),
            None => PackedInt32Array::new(),
        }
    }

    /// The runtime controls per preorder index (null for non-visual), and
    /// whether each is a UxmlBox (measured by natural_size). Once per load.
    #[func]
    fn set_controls(&mut self, controls: VarArray, boxed: PackedByteArray) {
        let mut ctl = vec![];
        let mut labels = vec![];
        for v in controls.iter_shared() {
            let c = v.try_to::<Gd<godot::classes::Control>>().ok();
            labels.push(c.as_ref().and_then(|c| c.clone().try_cast::<godot::classes::Label>().ok()));
            ctl.push(c);
        }
        self.layout_in = Some(crate::layout::LayoutIn {
            controls: ctl,
            boxed: boxed.as_slice().iter().map(|&b| b != 0).collect(),
            labels,
        });
    }

    /// Native flex pass: [rects, content_sizes, insets] Dictionaries keyed
    /// by element, exactly as UxmlFlexLayout.compute returns them.
    /// Diagnostics are deduplicated through `warned` and appended to
    /// `warnings` (both caller-owned, shared across passes).
    #[func]
    fn layout(&mut self, host: Vector2, scroll_bar_width: f64, warned: VarDictionary, warnings: VarArray) -> VarArray {
        let (Some(c), Some(io)) = (self.inner.as_ref(), self.layout_in.as_ref()) else {
            return VarArray::new();
        };
        self.recs.refresh(c);
        let out = crate::layout::Pass::new(c, io, &self.recs.recs, scroll_bar_width, warned, warnings).run(host);
        args(&[out.rects.to_variant(), out.content.to_variant(), out.insets.to_variant()])
    }

    #[func]
    fn last_old(&self) -> VarArray {
        self.inner.as_ref().map(|c| c.last_old.clone()).unwrap_or_default()
    }

    #[func]
    fn element_warnings(&self) -> VarArray {
        self.inner.as_ref().map(|c| c.element_warnings()).unwrap_or_default()
    }

    /// [flipped indices, disabled flags, gone flags] — see Cascade::effective_flags.
    #[func]
    fn effective_flags(&mut self) -> VarArray {
        match self.inner.as_mut() {
            Some(c) => {
                let (f, d, g) = c.effective_flags();
                args(&[f.to_variant(), d.to_variant(), g.to_variant()])
            }
            None => VarArray::new(),
        }
    }

    #[func]
    fn disabled_flags(&self) -> PackedByteArray {
        self.inner.as_ref().map(|c| c.disabled_flags()).unwrap_or_default()
    }
}
