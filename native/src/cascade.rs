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
/// `all: initial` outranks every other declaration (uss_cascade.gd ALL_SPEC).
const ALL_SPEC: i64 = (1 << 62) | (1 << 61);
const F_CUSTOM: i32 = 1;
const F_VAR: i32 = 2;
const F_ALL: i32 = 4;
const BIT_ACTIVE: i32 = 2;
const BIT_INACTIVE: i32 = 4;

/// The `severity` of a diagnostic of `kind` (UxmlDiagnostic.severity_of).
pub fn severity_of(kind: &str) -> &'static str {
    match kind {
        "malformed" | "import-unresolved" | "import-cycle" | "missing-file" | "path-outside-root"
        | "malformed-reference" | "template-not-declared" | "template-cycle"
        | "template-depth-exceeded" => "error",
        "version-dependent" => "info",
        _ => "warning",
    }
}

fn state_bit(name: &str) -> i32 {
    match name {
        "hover" => 1,
        "active" => 2,
        "inactive" => 4,
        "focus" => 8,
        "checked" => 16,
        "disabled" => 32,
        "enabled" => 64,
        // Unity: `:selected` is `:checked` (uss_cascade.gd STATE_BITS).
        "selected" => 16,
        _ => 0,
    }
}

/// "12px" / "12" -> 12 (UssValues.parse_length "px"), else None.
fn px_of(v: &str) -> Option<f64> {
    let t = v.trim();
    let n = t.strip_suffix("px").unwrap_or(t);
    if n.is_empty() || n.ends_with('.') && n.len() == 1 {
        return None;
    }
    n.parse::<f64>().ok().filter(|x| x.is_finite())
}

/// "150%" -> 150, else None.
fn pct_of(v: &str) -> Option<f64> {
    v.trim().strip_suffix('%').and_then(|n| n.parse::<f64>().ok()).filter(|x| x.is_finite())
}

/// UssValues.fmt_number: four decimals, trailing zeros dropped.
fn fmt_number(v: f64) -> String {
    let t = format!("{:.4}", v);
    let t = t.trim_end_matches('0').trim_end_matches('.').to_string();
    if t == "-0" || t.is_empty() { "0".to_string() } else { t }
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

#[derive(Clone)]
struct Compound {
    types: Vec<u32>,
    names: Vec<u32>,
    classes: Vec<u32>,
    mask: i32,
    root: bool,
    child: bool,
}

#[derive(Clone)]
struct Sel {
    rule: usize,
    spec: i64,
    parts: Rc<Vec<Compound>>,
    states: VarArray,
    need: u64,
    origins: Option<Rc<Vec<Variant>>>,
    entries: Option<Rc<Vec<Option<Rc<Vec<Variant>>>>>>,
    /// Theme block selectors: the origins and entries shared with every
    /// cascade that has the block at the same sheet index (Block::shared).
    slot: Option<Rc<std::cell::RefCell<Option<SelShared>>>>,
}

/// A selector's origin Dictionaries and shared {value, origin} entries
/// (origins_for, entries_for).
type SelShared = (Rc<Vec<Variant>>, Rc<Vec<Option<Rc<Vec<Variant>>>>>);
type Slots = Rc<Vec<Rc<std::cell::RefCell<Option<SelShared>>>>>;

/// One declaration (rule or inline).
#[derive(Clone)]
struct Decl {
    prop: GString,
    pid: u32,
    val: GString,
    flags: i32,
    /// Static shorthand expansion (None when the value contains var()).
    exp: Option<Rc<Vec<Pair>>>,
}

#[derive(Clone)]
struct Rule {
    scope_idx: i32,
    scope_lo: i32,
    scope_hi: i32,
    sheet: i64,
    item: i64,
    file: GString,
    decls: Rc<Vec<Decl>>,
}

/// The converted rules and selectors of one theme block (see
/// `UssCascade._blocks`): rule `sheet`/`file` and selector `rule` are
/// patched per cascade (selector `rule` is relative to the block here).
/// Interned ids refer to the shared base tables (`BASE`).
struct Block {
    rules: Vec<Rule>,
    sels: Vec<Sel>,
    /// Per (sheet index, file): the origins and entries of each selector,
    /// built by the first cascade that needs them. They depend only on the
    /// rule (sheet, item, file, declarations) and the selector's states,
    /// and are read-only once built, as within one cascade.
    shared: std::cell::RefCell<HashMap<(i64, String), Slots>>,
}

/// Interned strings and properties that every cascade starts from, and the
/// theme blocks converted against them. Theme sheets are shared by every
/// load (UxmlTheme), so their rules are converted once per block; a cascade
/// clones the base tables and interns its document's own strings on top.
/// The ids only need to be consistent within a cascade: nothing depends on
/// their order.
#[derive(Default)]
struct BaseTables {
    interned: HashMap<String, u32>,
    props: Props,
    blocks: HashMap<i64, Rc<Block>>,
}

thread_local! {
    static BASE: std::cell::RefCell<BaseTables> = std::cell::RefCell::new(BaseTables::default());
}

/// Drops the converted theme blocks (they hold Godot strings; called before
/// the engine shuts down).
pub fn clear_cache() {
    BASE.with(|b| *b.borrow_mut() = BaseTables::default());
}

struct Inline {
    decls: Rc<Vec<Decl>>,
    problems: Vec<GString>,
}

/// A for_children entry: computed {value, origin} plus the entry Dictionary.
#[derive(Clone)]
pub struct Item {
    pub pid: u32,
    /// Shared (Rc): the wrap of an inherited item keeps the value without an
    /// engine copy of the Variant.
    pub value: Rc<Variant>,
    pub origin: Variant,
    /// Table mode (runtime v2): the element whose declaration this is; the
    /// origin is that declaration's own and the `{kind: inherited}` wraps of
    /// the output are made on request (`Cascade::style_dict`). -1 otherwise.
    pub decl: i32,
}

/// An expanded longhand: (property id, value, KW_INITIAL / KW_UNSET / 0).
/// The keyword is found once, where the pair is made: a Variant comparison
/// is an engine call.
type Pair = (u32, Variant, u8);
const KW_INITIAL: u8 = 1;
const KW_UNSET: u8 = 2;
/// A percentage (ends with `%`): a font-size of the element is then computed
/// from the inherited size.
const KW_PCT: u8 = 4;

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
    end: i64,
}

#[derive(Clone, Default)]
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
    exp_cache: HashMap<(u32, String), Rc<Vec<Pair>>>,
    /// {value, origin} entries of substituted (var()) declarations of rules,
    /// by (expansion, longhand, origins of the selector, declaration): one
    /// entry per value and origin, shared by the elements, as the entries of
    /// static declarations are (entries_for). The key's Rcs are kept in the
    /// value, so their addresses stay theirs.
    var_ent: HashMap<(usize, usize, usize, usize), (Rc<Vec<Pair>>, Rc<Vec<Variant>>, Variant)>,
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
    /// Non-rightmost compounds that test a state: (types, names, classes,
    /// mask). Mirrors UssCascade._anc_state_reqs / _anc_state_mask.
    anc_state_reqs: Vec<(Vec<u32>, Vec<u32>, Vec<u32>, i32)>,
    inline_origins: Vec<Variant>,
    // element index
    els: Vec<Elem>,
    parent: Vec<i32>,
    /// Selector parent per element: the logical parent Unity's combinators
    /// walk (VisualElement.parent). An author child that a control keeps
    /// in its content container has the control as selector parent.
    sel_parent: Vec<i32>,
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
    none_val: Variant,
    sig_valid: Vec<bool>,
    anc_key: Vec<AncKey>,
    bloom: Vec<u64>,
    own_bloom: Vec<u64>,
    fc: Vec<Rc<Vec<Rc<Item>>>>,
    fc_dict: Vec<VarDictionary>,
    fc_customs: Vec<Rc<Customs>>,
    warn: Vec<Vec<Variant>>,
    lay_vals: Vec<Vec<Option<GString>>>,
    lay_ver: Vec<u64>,
    computed_once: bool,
    /// The theme blocks of the rule tables (id, first rule, rules, first
    /// selector, selectors), as setup converted them.
    block_ranges: Vec<(i64, usize, usize, usize, usize)>,
    /// The state inputs of the last update (see update).
    prev_es: HashMap<usize, i32>,
    prev_dis: HashMap<usize, u8>,
    prev_global: i32,
    prev_kb: Vec<i32>,
    next_cid: i64,
    // computed overrides (USS transitions): index -> {prop: entry}; the
    // pre-override result per overridden index; indices to recompute
    ov: HashMap<usize, VarDictionary>,
    tgt: HashMap<usize, VarDictionary>,
    ov_force: Vec<usize>,
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
    v_initial: Variant,
    v_unset: Variant,
    sn_attributes: StringName,
    empty_fc: Rc<Vec<Rc<Item>>>,
    empty_customs: Rc<Customs>,
    pub last_old: VarArray,
    /// Runtime v2: the output is the computed items per element
    /// (`out_items`), not Dictionaries; see `set_table_mode`.
    pub table: bool,
    pub out_items: Vec<Rc<Vec<Rc<Item>>>>,
    /// Table mode: one value per (expansion, longhand); the expansion is
    /// kept so its address stays its own.
    val_rc: HashMap<(usize, usize), (Rc<Vec<Pair>>, Rc<Variant>)>,
}

/// Two item lists with the same properties, values and origins, in order.
fn same_items(a: &Rc<Vec<Rc<Item>>>, b: &Rc<Vec<Rc<Item>>>) -> bool {
    if Rc::ptr_eq(a, b) {
        return true;
    }
    a.len() == b.len()
        && a.iter().zip(b.iter()).all(|(x, y)| {
            Rc::ptr_eq(x, y) || (x.pid == y.pid && x.decl == y.decl && (Rc::ptr_eq(&x.value, &y.value) || *x.value == *y.value) && x.origin == y.origin)
        })
}

/// The compiled rule tables of the GDScript cascade (read in setup).
struct Tables {
    r_scope_idx: PackedInt32Array,
    r_lo: PackedInt32Array,
    r_hi: PackedInt32Array,
    r_sheet: PackedInt32Array,
    r_item: PackedInt32Array,
    r_file: PackedStringArray,
    r_dprop: VarArray,
    r_dval: VarArray,
    r_dflag: VarArray,
    r_dexp: VarArray,
    s_rule: PackedInt32Array,
    s_spec: PackedInt64Array,
    s_parts: VarArray,
    s_states: VarArray,
}

impl Tables {
    /// Rule `r` with the given declarations.
    fn rule_shell(&self, r: usize, decls: Rc<Vec<Decl>>) -> Rule {
        Rule {
            scope_idx: self.r_scope_idx.as_slice()[r],
            scope_lo: self.r_lo.as_slice()[r],
            scope_hi: self.r_hi.as_slice()[r],
            sheet: self.r_sheet.as_slice()[r] as i64,
            item: self.r_item.as_slice()[r] as i64,
            file: self.r_file.as_slice()[r].clone(),
            decls,
        }
    }
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

    fn expand(&mut self, pid: u32, raw: &GString) -> Rc<Vec<Pair>> {
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
            let v = pa.at(1);
            let kw = self.kw(&v);
            out.push((lid, v, kw));
        }
        let rc = Rc::new(out);
        if self.exp_cache.len() > 16384 {
            self.exp_cache.clear();
        }
        self.exp_cache.insert(key, rc.clone());
        rc
    }

    fn kw(&self, v: &Variant) -> u8 {
        if *v == self.v_initial {
            KW_INITIAL
        } else if *v == self.v_unset {
            KW_UNSET
        } else if gs(v).to_string().trim_end().ends_with('%') {
            KW_PCT
        } else {
            0
        }
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
                let v = pa.at(1);
                let kw = self.kw(&v);
                out.push((lid, v, kw));
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
        let rc = Rc::new(Inline { decls: Rc::new(decls), problems });
        if self.inline_cache.len() > 4096 {
            self.inline_cache.clear();
        }
        self.inline_cache.insert(key, rc.clone());
        rc
    }

    fn ensure_inline_origin(&mut self, d: usize) {
        while self.inline_origins.len() <= d {
            let mut o = VarDictionary::new();
            o.set(&self.k_kind, "inline");
            o.set("decl_index", self.inline_origins.len() as i64);
            self.inline_origins.push(o.to_variant());
        }
    }

    fn origins_for(&mut self, s: usize) -> Rc<Vec<Variant>> {
        if let Some(o) = &self.sels[s].origins {
            return o.clone();
        }
        let shared = self.sels[s].slot.as_ref().and_then(|sl| sl.borrow().clone());
        if let Some((o, e)) = shared {
            self.sels[s].origins = Some(o.clone());
            self.sels[s].entries = Some(e);
            return o;
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
                    for (_, v, _) in pairs.iter() {
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
        if let Some(sl) = &self.sels[s].slot {
            *sl.borrow_mut() = Some((origins.clone(), rc.clone()));
        }
        rc
    }

    fn diag(&self, i: usize, kind: &str, message: String) -> Variant {
        let e = &self.els[i];
        let mut d = VarDictionary::new();
        d.set("kind", kind);
        d.set("severity", severity_of(kind));
        d.set("message", message.as_str());
        d.set("file", &self.source_file);
        d.set("offset", e.offset);
        d.set("line", e.line);
        d.set("column", e.column);
        d.set("end_offset", e.end);
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
            var_ent: HashMap::new(),
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
            anc_state_reqs: vec![],
            inline_origins: vec![],
            els: vec![],
            parent: vec![],
            sel_parent: vec![],
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
            block_ranges: vec![],
            prev_es: HashMap::new(),
            prev_dis: HashMap::new(),
            prev_global: 0,
            prev_kb: vec![],
            next_cid: 1,
            ov: HashMap::new(),
            tgt: HashMap::new(),
            ov_force: vec![],
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
            v_initial: GString::from("initial").to_variant(),
            v_unset: GString::from("unset").to_variant(),
            sn_attributes: StringName::from("attributes"),
            empty_fc: Rc::new(vec![]),
            empty_customs: Rc::new(Customs { id: 0, dict: VarDictionary::new() }),
            last_old: VarArray::new(),
            table: false,
            out_items: vec![],
            val_rc: HashMap::new(),
        };

        // The GDScript rule tables, and the theme blocks among them:
        // (block id, first rule, rule count, first selector, selector count).
        let t = Tables {
            r_scope_idx: get("_rule_scope_idx").to::<PackedInt32Array>(),
            r_lo: get("_rule_scope_lo").to::<PackedInt32Array>(),
            r_hi: get("_rule_scope_hi").to::<PackedInt32Array>(),
            r_sheet: get("_rule_sheet").to::<PackedInt32Array>(),
            r_item: get("_rule_item").to::<PackedInt32Array>(),
            r_file: get("_rule_file").to::<PackedStringArray>(),
            r_dprop: get("_rule_dprop").to::<VarArray>(),
            r_dval: get("_rule_dval").to::<VarArray>(),
            r_dflag: get("_rule_dflag").to::<VarArray>(),
            r_dexp: get("_rule_dexp").to::<VarArray>(),
            s_rule: get("_sel_rule").to::<PackedInt32Array>(),
            s_spec: get("_sel_spec").to::<PackedInt64Array>(),
            s_parts: get("_sel_parts").to::<VarArray>(),
            s_states: get("_sel_states").to::<VarArray>(),
        };
        let mut blocks: Vec<(i64, usize, usize, usize, usize)> = vec![];
        if let Ok(arr) = get("_blocks").try_to::<VarArray>() {
            for bv in arr.iter_shared() {
                let a = bv.try_to::<VarArray>().ok()?;
                let n = |k: usize| a.at(k).try_to::<i64>().unwrap_or(0);
                let blk = (n(0), n(1) as usize, n(2) as usize, n(3) as usize, n(4) as usize);
                if blk.1 + blk.2 > t.r_sheet.len() || blk.3 + blk.4 > t.s_rule.len() {
                    return None;
                }
                blocks.push(blk);
            }
        }
        // Convert the blocks the base does not have yet against the base
        // tables (before anything of this document is interned), then start
        // this cascade from a copy of the base tables.
        let mut cached: Vec<Rc<Block>> = Vec::with_capacity(blocks.len());
        BASE.with(|cell| {
            let mut base = cell.borrow_mut();
            if blocks.iter().any(|b| !base.blocks.contains_key(&b.0)) {
                if base.blocks.len() > 64 {
                    *base = BaseTables::default();
                }
                std::mem::swap(&mut c.interned, &mut base.interned);
                std::mem::swap(&mut c.props, &mut base.props);
                for &(id, r0, nr, s0, ns) in &blocks {
                    if base.blocks.contains_key(&id) {
                        continue;
                    }
                    let rules: Vec<Rule> = (r0..r0 + nr).map(|r| c.convert_rule(&t, r)).collect();
                    let sels: Vec<Sel> = (s0..s0 + ns).map(|s| c.convert_sel(&t, s)).collect();
                    base.blocks.insert(id, Rc::new(Block { rules, sels, shared: Default::default() }));
                }
                std::mem::swap(&mut c.interned, &mut base.interned);
                std::mem::swap(&mut c.props, &mut base.props);
            }
            c.interned = base.interned.clone();
            c.props = base.props.clone();
            for b in &blocks {
                cached.push(base.blocks[&b.0].clone());
            }
        });

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
        let sel_parent = get("_sel_parent").to::<PackedInt32Array>();
        let end = get("_end").to::<PackedInt32Array>();
        let n = els.len();
        let sn_local = StringName::from("local");
        let sn_prefix = StringName::from("prefix");
        let sn_children = StringName::from("children");
        let sn_offset = StringName::from("open_tag_start");
        let sn_end = StringName::from("open_tag_end");
        for i in 0..n {
            let var = els.at(i);
            let obj = var.try_to::<Gd<Object>>().ok()?;
            let local = gs(&obj.get(&sn_local)).to_string();
            let prefix = gs(&obj.get(&sn_prefix)).to_string();
            let leaf = obj.get(&sn_children).to::<VarArray>().is_empty();
            let offset = obj.get(&sn_offset).try_to::<i64>().unwrap_or(0);
            let end = obj.get(&sn_end).try_to::<i64>().unwrap_or(offset);
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
            c.els.push(Elem { obj, var, local: lid, local_var: local.to_variant(), local_name: local.clone(), leaf, tag, line, column, offset, end });
        }
        c.parent = parent.as_slice().to_vec();
        c.sel_parent = sel_parent.as_slice().to_vec();
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
        c.out_items = vec![c.empty_fc.clone(); n];
        c.fc_customs = vec![c.empty_customs.clone(); n];
        c.warn = vec![vec![]; n];
        c.lay_vals = vec![vec![None; crate::layout::LAYOUT_PROPS.len()]; n];
        c.lay_ver = vec![0; n];

        // Compiled rules. Theme blocks come from the base cache; the
        // per-cascade fields (scope, sheet, item, file, selector rule and
        // specificity) are read from the GDScript tables for every rule.
        let mut b = 0usize;
        let mut r = 0usize;
        let nr = t.r_sheet.len();
        while r < nr {
            if b < blocks.len() && blocks[b].1 == r {
                let (_, r0, cnt, _, _) = blocks[b];
                for k in 0..cnt {
                    let decls = cached[b].rules[k].decls.clone();
                    c.rules.push(t.rule_shell(r0 + k, decls));
                }
                r += cnt;
                b += 1;
                continue;
            }
            let rule = c.convert_rule(&t, r);
            c.rules.push(rule);
            r += 1;
        }
        let mut b = 0usize;
        let mut s = 0usize;
        let ns = t.s_rule.len();
        while s < ns {
            if b < blocks.len() && blocks[b].3 == s {
                let (_, r0, _, s0, cnt) = blocks[b];
                let key = (t.r_sheet.as_slice()[r0] as i64, t.r_file.as_slice()[r0].to_string());
                let slots = cached[b]
                    .shared
                    .borrow_mut()
                    .entry(key)
                    .or_insert_with(|| Rc::new((0..cnt).map(|_| Rc::new(std::cell::RefCell::new(None))).collect()))
                    .clone();
                for k in 0..cnt {
                    let mut sel = cached[b].sels[k].clone();
                    sel.rule = t.s_rule.as_slice()[s0 + k] as usize;
                    sel.spec = t.s_spec.as_slice()[s0 + k];
                    sel.slot = Some(slots[k].clone());
                    c.sels.push(sel);
                }
                s += cnt;
                b += 1;
                continue;
            }
            let sel = c.convert_sel(&t, s);
            c.sels.push(sel);
            s += 1;
        }
        c.block_ranges = blocks.clone();
        c.index_sels();
        Some(c)
    }

    /// Buckets and ancestor features of the compiled selectors.
    fn index_sels(&mut self) {
        // Buckets and ancestor features, from the selectors (the derivation
        // of UssCascade._compile_rule / _add_rule: bucket by the rightmost
        // compound's first name, else class, else type; ancestor classes,
        // names and states from the other compounds).
        for si in 0..self.sels.len() {
            let sel = self.sels[si].clone();
            let right = &sel.parts[sel.parts.len() - 1];
            let si = si as u32;
            if let Some(&k) = right.names.first() {
                self.b_name.entry(k).or_default().push(si);
            } else if let Some(&k) = right.classes.first() {
                self.b_class.entry(k).or_default().push(si);
            } else if let Some(&k) = right.types.first() {
                self.b_type.entry(k).or_default().push(si);
            } else {
                self.b_any.push(si);
            }
            for cp in sel.parts.iter().take(sel.parts.len() - 1) {
                for &x in &cp.classes {
                    let x = x as usize;
                    if self.anc_classes.len() <= x {
                        self.anc_classes.resize(x + 1, false);
                    }
                    self.anc_classes[x] = true;
                }
                for &x in &cp.names {
                    let x = x as usize;
                    if self.anc_names.len() <= x {
                        self.anc_names.resize(x + 1, false);
                    }
                    self.anc_names[x] = true;
                }
                self.anc_states |= cp.mask;
            }
        }
        let mut reqs: Vec<(Vec<u32>, Vec<u32>, Vec<u32>, i32)> = vec![];
        for sel in self.sels.iter() {
            for cp in sel.parts.iter().take(sel.parts.len().saturating_sub(1)) {
                if cp.mask == 0 {
                    continue;
                }
                let r = (cp.types.clone(), cp.names.clone(), cp.classes.clone(), cp.mask);
                if !reqs.contains(&r) {
                    reqs.push(r);
                }
            }
        }
        self.anc_state_reqs = reqs;
    }

    fn convert_rule(&mut self, t: &Tables, r: usize) -> Rule {
        let dp = t.r_dprop.at(r).to::<PackedStringArray>();
        let dv = t.r_dval.at(r).to::<PackedStringArray>();
        let df = t.r_dflag.at(r).to::<PackedInt32Array>();
        let de = t.r_dexp.at(r).to::<VarArray>();
        let mut decls = Vec::with_capacity(dp.len());
        for d in 0..dp.len() {
            let decl = self.make_decl(dp.as_slice()[d].clone(), dv.as_slice()[d].clone(), df.as_slice()[d], &de.at(d));
            decls.push(decl);
        }
        t.rule_shell(r, Rc::new(decls))
    }

    fn convert_sel(&mut self, t: &Tables, s: usize) -> Sel {
        let parts_v = t.s_parts.at(s).to::<VarArray>();
        let mut parts = Vec::with_capacity(parts_v.len());
        for p in parts_v.iter_shared() {
            let cp = p.to::<VarArray>();
            parts.push(Compound {
                types: self.psa_ids(&cp.at(0)),
                names: self.psa_ids(&cp.at(1)),
                classes: self.psa_ids(&cp.at(2)),
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
        Sel {
            rule: t.s_rule.as_slice()[s] as usize,
            spec: t.s_spec.as_slice()[s],
            parts: Rc::new(parts),
            states: t.s_states.at(s).to::<VarArray>(),
            need,
            origins: None,
            entries: None,
            slot: None,
        }
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
        let mut m = 0i32;
        for r in &self.anc_state_reqs {
            if m & r.3 == r.3 {
                continue;
            }
            if r.0.iter().all(|&t| t == self.els[i].local)
                && r.1.iter().all(|&n| self.name[i] == Some(n))
                && r.2.iter().all(|c| self.cls_set[i].contains(c))
            {
                m |= r.3;
            }
        }
        AncKey { classes: cl, name, bits: self.sig_bits[i] & m }
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
        only_forced: bool,
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
        let mut forced = vec![false; if self.ov_force.is_empty() { 0 } else { n }];
        for &f in &self.ov_force {
            if f < n {
                forced[f] = true;
            }
        }
        let has_forced = !self.ov_force.is_empty();
        // Only overrides changed (UssCascade.update `only_forced`): visit
        // just the subtrees of the elements whose overrides changed. Only the
        // inputs of some elements changed (attributes, states, disabled
        // overrides): visit their subtrees (UssCascade.update).
        let mut use_order = only_forced && self.computed_once && !force;
        let mut order: Vec<usize> = vec![];
        let mut touch: Vec<usize> = vec![];
        if !use_order && !full && !scan_all && global == self.prev_global && kb == self.prev_kb.as_slice() {
            use_order = true;
            for &d in dirty.as_slice() {
                if d >= 0 {
                    touch.push(d as usize);
                }
            }
            for (&i, &b) in &es_bits {
                if self.prev_es.get(&i).copied().unwrap_or(0) != b {
                    touch.push(i);
                }
            }
            for &i in self.prev_es.keys() {
                if !es_bits.contains_key(&i) {
                    touch.push(i);
                }
            }
            for (&i, &b) in &dis_ov {
                if self.prev_dis.get(&i).copied().unwrap_or(0) != b {
                    touch.push(i);
                }
            }
            for &i in self.prev_dis.keys() {
                if !dis_ov.contains_key(&i) {
                    touch.push(i);
                }
            }
        }
        self.prev_global = global;
        self.prev_kb = kb.to_vec();
        if use_order {
            let mut fs = self.ov_force.clone();
            fs.extend(touch);
            fs.sort_unstable();
            fs.dedup();
            let mut hi = 0usize;
            for f in fs {
                if f >= n || f < hi {
                    continue;
                }
                hi = self.end[f] as usize;
                order.extend(f..hi);
            }
        }
        self.ov_force.clear();
        let mut inh_dirty = vec![false; n];
        let mut anc_until: i32 = -1;
        let total = if use_order { order.len() } else { n };
        for k in 0..total {
            let i = if use_order { order[k] } else { k };
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
            if b & BIT_ACTIVE == 0 {
                b |= BIT_INACTIVE;
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
            if !own && !inh_dirty[i] && (i as i32) >= anc_until && !(has_forced && forced[i]) {
                continue;
            }
            if self.table {
                let old_items = self.out_items[i].clone();
                let old_fc = self.fc[i].clone();
                let pc = crate::prof::scope("cu.compute");
                let _ = self.compute(i);
                drop(pc);
                if full || !same_items(&old_items, &self.out_items[i]) {
                    changed.push(i as i32);
                }
                if full || !same_items(&old_fc, &self.fc[i]) {
                    let mut ch = i + 1;
                    let e = self.end[i] as usize;
                    while ch < e {
                        inh_dirty[ch] = true;
                        ch = self.end[ch] as usize;
                    }
                }
                continue;
            }
            let el_var = self.els[i].var.clone();
            let old = styles.get(&el_var);
            let old_fc = self.fc_dict[i].clone();
            let old_t = if self.tgt.is_empty() { None } else { self.tgt.get(&i).cloned() };
            let pc = crate::prof::scope("cu.compute");
            let new_dict = self.compute(i);
            drop(pc);
            let _pc2 = crate::prof::scope("cu.store");
            match old {
                Some(ov) if !full => {
                    let od = ov.to::<VarDictionary>();
                    if od != new_dict {
                        changed.push(i as i32);
                        self.last_old.push(&ov);
                        styles.set(&el_var, &new_dict);
                    } else if old_t.is_some() && old_t.as_ref() != self.tgt.get(&i) {
                        // Overridden element whose own cascade result changed
                        // under an unchanged override (transition retarget).
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
        self.prev_es = es_bits;
        self.prev_dis = dis_ov;
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
        let mut p = self.sel_parent[i];
        if cp.child {
            return p >= 0 && self.match_from(parts, k - 1, p as usize, scope_idx);
        }
        while p >= 0 {
            if self.match_from(parts, k - 1, p as usize, scope_idx) {
                return true;
            }
            p = self.sel_parent[p as usize];
        }
        false
    }

    // ---------------------------------------------------------------------
    // Per-element computation (mirrors UssCascade._compute)
    // ---------------------------------------------------------------------

    fn compute(&mut self, i: usize) -> VarDictionary {
        let p = self.parent[i];
        let mut warns: Vec<Variant> = vec![];
        let s_match = crate::prof::scope("c.match");

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
        // Candidates: (declaration list and index, origins (None: the
        // inline origin of the index), spec, shared entries). The lists and
        // origins are shared (Rc): a declaration is not copied per element.
        let mut c_decls: Vec<Rc<Vec<Decl>>> = vec![];
        let mut c_d: Vec<usize> = vec![];
        let mut c_org: Vec<Option<Rc<Vec<Variant>>>> = vec![];
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
            let decls = self.rules[r].decls.clone();
            for d in 0..decls.len() {
                c_decls.push(decls.clone());
                c_d.push(d);
                c_org.push(Some(origins.clone()));
                c_spec.push(best_spec);
                c_ent.push(ents[d].clone());
            }
        }

        drop(s_match);
        let s_inl = crate::prof::scope("c.inline");
        let st = self.sig_style[i].clone();
        if !st.is_nil() {
            let inl = self.inline(&gs(&st));
            for d in 0..inl.decls.len() {
                c_decls.push(inl.decls.clone());
                c_d.push(d);
                self.ensure_inline_origin(d);
                c_org.push(None);
                c_spec.push(INLINE_SPEC);
                c_ent.push(None);
            }
            for msg in &inl.problems {
                let m = format!("style attribute of <{}>: {}", self.els[i].tag, msg);
                warns.push(self.diag(i, "malformed", m));
            }
        }

        drop(s_inl);
        let s_sub = crate::prof::scope("c.subst");
        let ncand = c_d.len();
        // Custom properties: inherited values, then the winning declarations.
        let cpair = if p >= 0 { self.fc_customs[p as usize].clone() } else { self.empty_customs.clone() };
        let mut customs = cpair.dict.clone();
        let mut cid = cpair.id;
        let any_custom = (0..ncand).any(|j| c_decls[j][c_d[j]].flags & F_CUSTOM != 0);
        if any_custom {
            let mut cw: Vec<(u32, usize)> = vec![];
            for j in 0..ncand {
                let decl = &c_decls[j][c_d[j]];
                if decl.flags & F_CUSTOM == 0 {
                    continue;
                }
                let pid = decl.pid;
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
                customs.set(&self.props.keys[*pid as usize], &c_decls[*j][c_d[*j]].val);
            }
            cid = -1;
        }

        // Substitute, expand, and pick the winner per longhand: candidate
        // `j`, pair `pk` of its expansion (`c_pairs[j]`).
        struct Best {
            pid: u32,
            j: usize,
            pk: usize,
            failed: bool,
            spec: i64,
        }
        let mut best: Vec<Best> = vec![];
        let mut best_ix: HashMap<u32, usize> = HashMap::new();
        let mut c_pairs: Vec<Option<Rc<Vec<Pair>>>> = vec![None; ncand];
        let mut c_shared = vec![false; ncand];
        for j in 0..ncand {
            let decl = &c_decls[j][c_d[j]];
            let flags = decl.flags;
            let pid = decl.pid;
            let mut failed = false;
            let pairs: Rc<Vec<Pair>>;
            if flags & F_VAR != 0 {
                let val = decl.val.clone();
                let sub: Option<GString> = if flags & F_CUSTOM != 0 {
                    let r = self.cb_subst.callv(&args(&[val.to_variant(), customs.to_variant(), decl.prop.to_variant()]));
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
                let raw = match sub {
                    Some(s) => s,
                    None => {
                        failed = true;
                        val
                    }
                };
                pairs = self.expand(pid, &raw);
                if pairs.is_empty() {
                    let m = format!("{}: {} -- wrong number of values; declaration dropped", decl.prop, raw);
                    warns.push(self.diag(i, "invalid-shorthand", m));
                    continue;
                }
            } else {
                pairs = decl.exp.clone().unwrap_or_else(|| Rc::new(vec![]));
                if pairs.is_empty() {
                    let m = format!("{}: {} -- wrong number of values; declaration dropped", decl.prop, decl.val);
                    warns.push(self.diag(i, "invalid-shorthand", m));
                    continue;
                }
                c_shared[j] = true;
            }
            let sp = if flags & F_ALL != 0 { ALL_SPEC } else { c_spec[j] };
            for (pk, (lh, _, _)) in pairs.iter().enumerate() {
                match best_ix.get(lh) {
                    None => {
                        best_ix.insert(*lh, best.len());
                        best.push(Best { pid: *lh, j, pk, failed, spec: sp });
                    }
                    Some(&slot) => {
                        if sp >= best[slot].spec {
                            let b = &mut best[slot];
                            b.j = j;
                            b.pk = pk;
                            b.failed = failed;
                            b.spec = sp;
                        }
                    }
                }
            }
            c_pairs[j] = Some(pairs);
        }

        drop(s_sub);
        let _s_build = crate::prof::scope("c.build");
        let fpid = self.props.index.get("font-size").copied();
        let mut own_pct = false;
        let table = self.table;
        let (mut computed, mut comp): (VarDictionary, Vec<Rc<Item>>) = if p >= 0 {
            (
                if table { VarDictionary::new() } else { self.fc_dict[p as usize].duplicate_shallow() },
                (*self.fc[p as usize]).clone(),
            )
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
            let pair = &c_pairs[b.j].as_ref().unwrap()[b.pk];
            let val = &pair.1;
            let kw = pair.2;
            if Some(b.pid) == fpid {
                own_pct = kw & KW_PCT != 0;
            }
            let origin = match &c_org[b.j] {
                Some(o) => &o[c_d[b.j]],
                None => &self.inline_origins[c_d[b.j]],
            };
            // A static declaration of a rule shares its {value, origin}
            // entries (entries_for); others get a new one.
            let shared = if table {
                Some(Variant::nil())
            } else if c_shared[b.j] {
                c_ent[b.j].as_ref().map(|e| e[b.pk].clone())
            } else {
                None
            };
            let entry = match shared {
                Some(e) => e,
                None => {
                    let key = c_org[b.j].as_ref().map(|o| {
                        (Rc::as_ptr(c_pairs[b.j].as_ref().unwrap()) as usize, b.pk, Rc::as_ptr(o) as usize, c_d[b.j])
                    });
                    match key.and_then(|k| self.var_ent.get(&k).map(|e| e.2.clone())) {
                        Some(e) => e,
                        None => {
                            let mut e = VarDictionary::new();
                            e.set(&self.k_value, val);
                            e.set(&self.k_origin, origin);
                            let ev = e.to_variant();
                            if let (Some(k), Some(o)) = (key, c_org[b.j].as_ref()) {
                                if self.var_ent.len() > 65536 {
                                    self.var_ent.clear();
                                }
                                self.var_ent.insert(k, (c_pairs[b.j].clone().unwrap(), o.clone(), ev.clone()));
                            }
                            ev
                        }
                    }
                }
            };
            if !self.props.supported[pidx] {
                let m = format!(
                    "\"{}\" is not a supported USS property; the value is kept but has no effect",
                    self.props.names[pidx]
                );
                warns.push(self.diag(i, "unsupported-property", m));
            }
            // `initial` (also what `all: initial` expands to): the property
            // is dropped, inherited value included (uss_cascade.gd _compute).
            if kw == KW_INITIAL {
                if !table {
                    computed.remove(&self.props.keys[pidx]);
                }
                comp.retain(|it| it.pid != b.pid);
                continue;
            }
            // `unset`: an inherited property keeps the inherited value, any
            // other one takes its initial value.
            if kw == KW_UNSET {
                if !self.props.inherited[pidx] {
                    if !table {
                        computed.remove(&self.props.keys[pidx]);
                    }
                    comp.retain(|it| it.pid != b.pid);
                }
                continue;
            }
            if !table {
                computed.set(&self.props.keys[pidx], &entry);
            }
            // Table mode: the value of a shared expansion is shared by the
            // elements it reaches (runtime v2 keys its records on it).
            let value = if table {
                let pr = c_pairs[b.j].clone().unwrap();
                let k = (Rc::as_ptr(&pr) as usize, b.pk);
                match self.val_rc.get(&k) {
                    Some((_, v)) => v.clone(),
                    None => {
                        let v = Rc::new(val.clone());
                        if self.val_rc.len() > 65536 {
                            self.val_rc.clear();
                        }
                        self.val_rc.insert(k, (pr, v.clone()));
                        v
                    }
                }
            } else {
                Rc::new(val.clone())
            };
            let item = Rc::new(Item { pid: b.pid, value, origin: origin.clone(), decl: i as i32 });
            match comp.iter_mut().find(|it| it.pid == b.pid) {
                Some(it) => *it = item,
                None => comp.push(item),
            }
        }

        // font-size: a percentage of the inherited size, computed here as
        // Unity computes it (uss_cascade.gd _font_percent).
        // Only the element's own winner can be a percentage (the inherited
        // size is computed): the check reads no Dictionary otherwise.
        if let (Some(fpid), true, true) = (fpid, own_pct, table) {
            let own = comp.iter().find(|it| it.pid == fpid).map(|it| gs(&it.value).to_string());
            if let Some(own) = own {
                if own.trim_end().ends_with('%') && p >= 0 {
                    let pv = self.fc[p as usize].iter().find(|it| it.pid == fpid).map(|it| gs(&it.value).to_string());
                    if let (Some(base), Some(pct)) = (pv.as_deref().and_then(px_of), pct_of(&own)) {
                        let val = GString::from(format!("{}px", fmt_number(base * pct / 100.0)).as_str()).to_variant();
                        if let Some(it) = comp.iter_mut().find(|it| it.pid == fpid) {
                            let origin = it.origin.clone();
                            let decl = it.decl;
                            *it = Rc::new(Item { pid: fpid, value: Rc::new(val), origin, decl });
                        }
                    }
                }
            }
        }
        if let (Some(fpid), true, false) = (fpid, own_pct, table) {
            let fkey = self.props.keys[fpid as usize].clone();
            if let Some(e) = computed.get(&fkey) {
                let ed = e.try_to::<VarDictionary>().unwrap_or_default();
                let own = gs(&ed.get(&self.k_value).unwrap_or_default()).to_string();
                if own.trim_end().ends_with('%') && p >= 0 {
                    let pe = self.fc_dict[p as usize].get(&fkey);
                    let pv = pe
                        .and_then(|x| x.try_to::<VarDictionary>().ok())
                        .map(|d| gs(&d.get(&self.k_value).unwrap_or_default()).to_string());
                    if let (Some(base), Some(pct)) = (pv.as_deref().and_then(px_of), pct_of(&own)) {
                        let val = GString::from(format!("{}px", fmt_number(base * pct / 100.0)).as_str()).to_variant();
                        let origin = ed.get(&self.k_origin).unwrap_or_default();
                        let mut ne = VarDictionary::new();
                        ne.set(&self.k_value, &val);
                        ne.set(&self.k_origin, &origin);
                        let nev = ne.to_variant();
                        computed.set(&fkey, &nev);
                        let item = Rc::new(Item { pid: fpid, value: Rc::new(val), origin, decl: i as i32 });
                        match comp.iter_mut().find(|it| it.pid == fpid) {
                            Some(it) => *it = item,
                            None => comp.push(item),
                        }
                    }
                }
            }
        }

        self.warn[i] = warns;
        // Computed overrides (transitions) replace the cascade result last,
        // so inheritance, layout values and the output all see them.
        if !self.ov.is_empty() && !table {
            if let Some(ov) = self.ov.get(&i).cloned() {
                self.tgt.insert(i, computed.clone());
                computed = computed.duplicate_shallow();
                for (k, e) in ov.iter_shared() {
                    computed.set(&k, &e);
                    let pid = self.pid(&gs(&k));
                    let ed = e.try_to::<VarDictionary>().unwrap_or_default();
                    let item = Rc::new(Item {
                        pid,
                        value: Rc::new(ed.get(&self.k_value).unwrap_or_default()),
                        origin: ed.get(&self.k_origin).unwrap_or_default(),
                        decl: i as i32,
                    });
                    match comp.iter_mut().find(|it| it.pid == pid) {
                        Some(it) => *it = item,
                        None => comp.push(item),
                    }
                }
            } else if !self.tgt.is_empty() {
                self.tgt.remove(&i);
            }
        } else if !self.tgt.is_empty() {
            self.tgt.remove(&i);
        }
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
        let dpid = self.props.index.get("display").copied();
        self.own_none[i] = match comp.iter().find(|it| Some(it.pid) == dpid) {
            Some(it) => {
                if *it.value == self.none_val { 1 } else { 0 }
            }
            None => 0,
        };
        if table {
            self.out_items[i] = Rc::new(comp.clone());
        }
        if self.els[i].leaf {
            self.fc[i] = self.empty_fc.clone();
            self.fc_dict[i] = VarDictionary::new();
            self.fc_customs[i] = cpair;
            return computed;
        }
        let node = self.els[i].var.clone();
        let mut fc_list: Vec<Rc<Item>> = Vec::with_capacity(comp.len());
        let mut fc_dict = VarDictionary::new();
        for it in &comp {
            if !self.props.inherited[it.pid as usize] {
                continue;
            }
            if table {
                // The item itself: its origin and declaring element are kept,
                // the wrap is made on request (style_dict).
                fc_list.push(it.clone());
                continue;
            }
            let mut wrap = VarDictionary::new();
            wrap.set(&self.k_kind, &self.v_inherited);
            wrap.set(&self.k_from, &node);
            wrap.set(&self.k_origin, &it.origin);
            let wrap_v = wrap.to_variant();
            let mut e = VarDictionary::new();
            e.set(&self.k_value, &*it.value);
            e.set(&self.k_origin, &wrap_v);
            let ev = e.to_variant();
            fc_dict.set(&self.props.keys[it.pid as usize], &ev);
            fc_list.push(Rc::new(Item { pid: it.pid, value: it.value.clone(), origin: wrap_v, decl: -1 }));
        }
        if !any_custom {
            self.fc_customs[i] = cpair;
        } else {
            let mut fcc = VarDictionary::new();
            for it in &fc_list {
                if self.props.custom[it.pid as usize] {
                    fcc.set(&self.props.keys[it.pid as usize], &*it.value);
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

    /// Table mode (runtime v2): `update` keeps the computed items per
    /// element in `out_items` and builds no Dictionaries.
    pub fn set_table(&mut self, on: bool) {
        self.table = on;
    }

    /// The name of property id `pid`.
    pub fn prop_name(&self, pid: u32) -> &GString {
        &self.props.names[pid as usize]
    }

    /// The id of a property (None when no rule or element uses it).
    pub fn prop_id(&self, name: &str) -> Option<u32> {
        self.props.index.get(name).copied()
    }

    pub fn prop_count(&self) -> usize {
        self.props.names.len()
    }

    /// The computed items of element i (table mode).
    pub fn items(&self, i: usize) -> &Rc<Vec<Rc<Item>>> {
        &self.out_items[i]
    }

    /// The origin of an item of element `e` as the Dictionary output has
    /// it: the declaration's own origin, wrapped in `{kind: inherited, from,
    /// origin}` per inheritance step (table mode).
    pub fn origin_of(&self, e: usize, it: &Item) -> Variant {
        if it.decl < 0 || it.decl as usize == e {
            return it.origin.clone();
        }
        let p = self.parent[e];
        if p < 0 {
            return it.origin.clone();
        }
        let inner = self.origin_of(p as usize, it);
        let mut wrap = VarDictionary::new();
        wrap.set(&self.k_kind, &self.v_inherited);
        wrap.set(&self.k_from, &self.els[p as usize].var);
        wrap.set(&self.k_origin, &inner);
        wrap.to_variant()
    }

    /// The computed style Dictionary of element i ({prop: {value, origin}},
    /// in the order of the Dictionary output), built from the items (table
    /// mode).
    pub fn style_dict(&self, i: usize) -> VarDictionary {
        let mut d = VarDictionary::new();
        for it in self.out_items[i].iter() {
            let mut e = VarDictionary::new();
            e.set(&self.k_value, &*it.value);
            e.set(&self.k_origin, &self.origin_of(i, it));
            d.set(&self.props.keys[it.pid as usize], &e);
        }
        d
    }

    /// The entries `{value}` of `props` in element i's computed style (those
    /// it has): the values style_dict gives, without the origins and the
    /// other properties (a layout hook reading a few lengths).
    pub fn style_values(&self, i: usize, props: &PackedStringArray) -> VarDictionary {
        let mut d = VarDictionary::new();
        let want: Vec<u32> = props.as_slice().iter().filter_map(|p| self.props.index.get(&p.to_string()).copied()).collect();
        if want.is_empty() {
            return d;
        }
        for it in self.out_items[i].iter() {
            if want.contains(&it.pid) {
                let mut e = VarDictionary::new();
                e.set(&self.k_value, &*it.value);
                d.set(&self.props.keys[it.pid as usize], &e);
            }
        }
        d
    }

    /// Computed overrides for element i (empty clears them); see
    /// UssCascade.set_override.
    pub fn set_override(&mut self, i: usize, entries: VarDictionary) {
        if i >= self.els.len() {
            return;
        }
        if entries.is_empty() {
            if self.ov.remove(&i).is_none() {
                return;
            }
        } else {
            self.ov.insert(i, entries);
        }
        self.ov_force.push(i);
    }

    pub fn target_style(&self, i: usize) -> Option<VarDictionary> {
        self.tgt.get(&i).cloned()
    }

    /// New declarations for rule `r` (UssCascade.patch_rules).
    pub fn patch_rule(&mut self, r: usize, dp: &PackedStringArray, dv: &PackedStringArray, df: &PackedInt32Array, de: &VarArray) {
        if r >= self.rules.len() {
            return;
        }
        let mut decls = Vec::with_capacity(dp.len());
        for d in 0..dp.len() {
            decls.push(self.make_decl(dp.as_slice()[d].clone(), dv.as_slice()[d].clone(), df.as_slice()[d], &de.at(d)));
        }
        self.rules[r].decls = Rc::new(decls);
        for s in self.sels.iter_mut() {
            if s.rule == r {
                s.origins = None;
                s.entries = None;
            }
        }
    }

    /// Marks for recompute the elements that the rules `rs` match now, or
    /// every element above `limit` rules (UssCascade.patch_rules).
    pub fn force_rules(&mut self, rs: &[i32], limit: usize) {
        let n = self.els.len();
        if rs.len() > limit {
            self.ov_force.extend(0..n);
            return;
        }
        let sels: Vec<usize> = (0..self.sels.len()).filter(|&s| rs.contains(&(self.sels[s].rule as i32))).collect();
        for i in 0..n {
            let mut hit = false;
            for &s in &sels {
                let sel = &self.sels[s];
                let rule = &self.rules[sel.rule];
                if rule.scope_lo != -2 && ((i as i32) < rule.scope_lo || (i as i32) >= rule.scope_hi) {
                    continue;
                }
                if sel.need != 0 && (self.bloom[i] & sel.need) != sel.need {
                    continue;
                }
                if self.match_from(&sel.parts, sel.parts.len() - 1, i, rule.scope_idx) {
                    hit = true;
                    break;
                }
            }
            if hit {
                self.ov_force.push(i);
            }
        }
    }

    /// One past the last preorder index of the subtree of element i.
    pub fn subtree_end(&self, i: usize) -> usize {
        self.end[i] as usize
    }

    /// The parent of element i (-1 for the root).
    pub fn parent_of(&self, i: usize) -> i32 {
        self.parent[i]
    }

    /// Compile the rules again from the tables of the GDScript cascade, in
    /// place: the per-element state, the interned names and the converted
    /// theme blocks stay (UssCascade.recompile_rules, a reload_stylesheet
    /// that changes selectors or rules). Elements whose ancestor key changes
    /// are marked with their subtrees, and elements with diagnostics (their
    /// offsets can move). False when the theme blocks differ: the caller
    /// builds a new cascade.
    pub fn recompile(&mut self, cas: &Gd<Object>) -> bool {
        let get = |name: &str| cas.get(name);
        let t = Tables {
            r_scope_idx: get("_rule_scope_idx").to::<PackedInt32Array>(),
            r_lo: get("_rule_scope_lo").to::<PackedInt32Array>(),
            r_hi: get("_rule_scope_hi").to::<PackedInt32Array>(),
            r_sheet: get("_rule_sheet").to::<PackedInt32Array>(),
            r_item: get("_rule_item").to::<PackedInt32Array>(),
            r_file: get("_rule_file").to::<PackedStringArray>(),
            r_dprop: get("_rule_dprop").to::<VarArray>(),
            r_dval: get("_rule_dval").to::<VarArray>(),
            r_dflag: get("_rule_dflag").to::<VarArray>(),
            r_dexp: get("_rule_dexp").to::<VarArray>(),
            s_rule: get("_sel_rule").to::<PackedInt32Array>(),
            s_spec: get("_sel_spec").to::<PackedInt64Array>(),
            s_parts: get("_sel_parts").to::<VarArray>(),
            s_states: get("_sel_states").to::<VarArray>(),
        };
        let mut blocks: Vec<(i64, usize, usize, usize, usize)> = vec![];
        if let Ok(arr) = get("_blocks").try_to::<VarArray>() {
            for bv in arr.iter_shared() {
                let Ok(a) = bv.try_to::<VarArray>() else { return false };
                let n = |k: usize| a.at(k).try_to::<i64>().unwrap_or(0);
                blocks.push((n(0), n(1) as usize, n(2) as usize, n(3) as usize, n(4) as usize));
            }
        }
        if blocks != self.block_ranges {
            return false;
        }
        let old_rules = std::mem::take(&mut self.rules);
        let old_sels = std::mem::take(&mut self.sels);
        let mut b = 0usize;
        let mut r = 0usize;
        let nr = t.r_sheet.len();
        while r < nr {
            if b < blocks.len() && blocks[b].1 == r {
                let (_, r0, cnt, _, _) = blocks[b];
                for k in 0..cnt {
                    self.rules.push(t.rule_shell(r0 + k, old_rules[r0 + k].decls.clone()));
                }
                r += cnt;
                b += 1;
                continue;
            }
            let rule = self.convert_rule(&t, r);
            self.rules.push(rule);
            r += 1;
        }
        let mut b = 0usize;
        let mut si = 0usize;
        let ns = t.s_rule.len();
        while si < ns {
            if b < blocks.len() && blocks[b].3 == si {
                let (_, _, _, s0, cnt) = blocks[b];
                for k in 0..cnt {
                    let mut sel = old_sels[s0 + k].clone();
                    sel.rule = t.s_rule.as_slice()[s0 + k] as usize;
                    sel.spec = t.s_spec.as_slice()[s0 + k];
                    self.sels.push(sel);
                }
                si += cnt;
                b += 1;
                continue;
            }
            let sel = self.convert_sel(&t, si);
            self.sels.push(sel);
            si += 1;
        }
        self.b_name.clear();
        self.b_class.clear();
        self.b_type.clear();
        self.b_any.clear();
        self.anc_classes.clear();
        self.anc_names.clear();
        self.anc_states = 0;
        self.anc_state_reqs.clear();
        self.index_sels();
        if self.computed_once {
            let n = self.els.len();
            let mut i = 0usize;
            while i < n {
                let ak = self.anc_key_of(i);
                if ak != self.anc_key[i] {
                    self.anc_key[i] = ak;
                    self.ov_force.extend(i..self.end[i] as usize);
                }
                if !self.warn[i].is_empty() {
                    self.ov_force.push(i);
                }
                i += 1;
            }
        }
        true
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

    pub fn element_var(&self, i: usize) -> Variant {
        self.els[i].var.clone()
    }

    /// The local name (tag) of element i.
    pub fn local_name(&self, i: usize) -> &str {
        &self.els[i].local_name
    }

    /// The `attributes` of element i's UxmlElement ([{name, value}]).
    pub fn attributes(&self, i: usize) -> VarArray {
        self.els[i].obj.get(&self.sn_attributes).try_to::<VarArray>().unwrap_or_default()
    }

    /// The first value of attribute `name` of element i.
    pub fn attr_str(&self, i: usize, name: &str) -> Option<String> {
        for a in self.attributes(i).iter_shared() {
            let Ok(d) = a.try_to::<VarDictionary>() else { continue };
            if gs(&d.get(&self.k_name).unwrap_or_default()).to_string() == name {
                return Some(gs(&d.get(&self.k_value).unwrap_or_default()).to_string());
            }
        }
        None
    }

    pub fn non_visual(&self, i: usize) -> bool {
        self.els[i].local_name == "UXML" || self.els[i].local_name == "Style"
    }

    pub fn file(&self) -> GString {
        self.source_file.clone()
    }

    pub fn location(&self, i: usize) -> (i64, i64, i64) {
        let e = &self.els[i];
        (e.offset, e.line, e.column)
    }

    /// The end of the open tag of element `i` (diagnostic `end_offset`).
    pub fn end_offset(&self, i: usize) -> i64 {
        self.els[i].end
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
    pub(crate) inner: Option<Cascade>,
    layout_in: Option<crate::layout::LayoutIn>,
    recs: crate::layout::RecCache,
    placement: crate::layout::Placement,
    xcache: crate::layout::XCache,
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
        only_forced: bool,
    ) -> PackedInt32Array {
        let _p = crate::prof::scope("cascade.update");
        match self.inner.as_mut() {
            Some(c) => c.update(&options, force, &key_bits, &mut styles, scan_all, &dirty, only_forced),
            None => PackedInt32Array::new(),
        }
    }

    /// The runtime controls per preorder index (null for non-visual), and
    /// whether each is a UxmlBox (measured by natural_size). Once per load.
    /// `kinds`: bit 1 UxmlBox (natural_size measure), bit 2 UxmlField,
    /// bit 4 an element of a pooled row (LayoutIn::ext);
    /// `natives`: the interactive inner control per index (or null).
    #[func]
    fn set_controls(&mut self, controls: VarArray, kinds: PackedByteArray, natives: VarArray) {
        let mut ctl = vec![];
        let mut labels = vec![];
        let mut rich = vec![];
        let mut texrects = vec![];
        let mut buttons = vec![];
        for (k, v) in controls.iter_shared().enumerate() {
            let c = v.try_to::<Gd<godot::classes::Control>>().ok();
            buttons.push(c.as_ref().is_some_and(|c| c.clone().try_cast::<godot::classes::Button>().is_ok()));
            labels.push(c.as_ref().and_then(|c| c.clone().try_cast::<godot::classes::Label>().ok()));
            rich.push(c.as_ref().and_then(|c| c.clone().try_cast::<godot::classes::RichTextLabel>().ok()));
            ctl.push(c);
            let nat = natives.get(k).and_then(|n| n.try_to::<Gd<godot::classes::TextureRect>>().ok());
            texrects.push(nat.map(|t| t.upcast::<godot::classes::Control>()));
        }
        let ks = kinds.as_slice();
        self.layout_in = Some(crate::layout::LayoutIn {
            v2: None,
            controls: ctl,
            boxed: ks.iter().map(|&b| b & 1 != 0).collect(),
            labels,
            rich,
            buttons,
            text_clip: false,
            pixel_grid: false,
            ppp: 1.0,
            auto_size: None,
            fields: ks.iter().map(|&b| b & 2 != 0).collect(),
            texrects,
            maxc: std::cell::RefCell::new(vec![None; ks.len()]),
            maxc_on: std::cell::Cell::new(false),
            unfit: std::cell::RefCell::new(vec![None; ks.len()]),
            margins: std::cell::RefCell::new(vec![None; ks.len()]),
            cliptext: std::cell::RefCell::new(vec![None; ks.len()]),
            touched: std::cell::RefCell::new(vec![false; ks.len()]),
            ext: ks.iter().map(|&b| b & 4 != 0).collect(),
        });
        self.placement = crate::layout::Placement::default();
        self.xcache.clear();
    }

    /// The style applier while best-fit text is active, else null (see
    /// LayoutIn::auto_size).
    #[func]
    fn set_auto_size(&mut self, applier: Variant) {
        if let Some(io) = self.layout_in.as_mut() {
            io.auto_size = applier.try_to::<Gd<godot::classes::Object>>().ok();
        }
    }

    /// UxmlBox.natural_epoch: the natural sizes changed since the last
    /// placing pass when it moved (XCache::validate).
    #[func]
    fn set_natural_epoch(&mut self, e: i64) {
        self.xcache.nat_epoch = e;
    }

    /// Round the layout output to the pixel grid (LayoutIn::pixel_grid).
    #[func]
    fn set_pixel_grid(&mut self, on: bool) {
        if let Some(io) = self.layout_in.as_mut() {
            io.pixel_grid = on;
        }
    }

    /// The pixel grid in pixels per point (LayoutIn::ppp; panel scaling).
    /// A change drops the cross-pass cache: its entries hold box lengths
    /// rounded on the old grid.
    #[func]
    fn set_pixels_per_point(&mut self, ppp: f64) {
        if let Some(io) = self.layout_in.as_mut() {
            if io.ppp != ppp {
                io.ppp = ppp;
                self.xcache.clear();
            }
        }
    }

    /// Whether any control carries `uxml_clip_text` (see LayoutIn::text_clip).
    #[func]
    fn set_text_clip(&mut self, any: bool) {
        if let Some(io) = self.layout_in.as_mut() {
            io.text_clip = any;
        }
    }

    /// Layout + native placement in one call (UxmlDocument._do_layout).
    /// `force`: indices re-applied since the last placement (their inset
    /// hooks must run); `force_all` for a full apply. Returns [rects
    /// changed vs the previous layout].
    #[func]
    fn layout_place(
        &mut self,
        host: Vector2,
        scroll_bar_width: f64,
        warned: VarDictionary,
        warnings: VarArray,
        applier: Variant,
        force: PackedInt32Array,
        force_all: bool,
    ) -> VarArray {
        let (Some(c), Some(io)) = (self.inner.as_ref(), self.layout_in.as_ref()) else {
            return VarArray::new();
        };
        let _p = crate::prof::scope("layout_place");
        let p0 = crate::prof::scope("lp.refresh");
        self.recs.refresh(c);
        let rec_changed = self.recs.take_changed();
        drop(p0);
        // Re-applied controls may have a new font, size or stylebox: their
        // max-content widths are measured again.
        {
            let mut mc = io.maxc.borrow_mut();
            let mut uf = io.unfit.borrow_mut();
            let mut mg = io.margins.borrow_mut();
            let mut ct = io.cliptext.borrow_mut();
            if force_all {
                mc.iter_mut().for_each(|e| *e = None);
                uf.iter_mut().for_each(|e| *e = None);
                mg.iter_mut().for_each(|e| *e = None);
                ct.iter_mut().for_each(|e| *e = None);
            } else {
                for &k in force.as_slice() {
                    if k >= 0 && (k as usize) < mc.len() {
                        mc[k as usize] = None;
                        uf[k as usize] = None;
                        mg[k as usize] = None;
                        ct[k as usize] = None;
                    }
                }
            }
        }
        let n = c.len();
        let mut forced = vec![force_all; n];
        for &k in force.as_slice() {
            if k >= 0 && (k as usize) < n {
                forced[k as usize] = true;
            }
        }
        let _ = scroll_bar_width;
        io.maxc_on.set(true);
        let (chg, sub) = self.xcache.validate(c, io, &forced, &rec_changed);
        let carry = self.xcache.carry.take().unwrap_or_default();
        let p1 = crate::prof::scope("lp.pass_new");
        let cached = crate::layout::Cached { chg: chg.clone(), sub, prev: self.placement.last.as_ref(), carry };
        let pass = crate::layout::Pass::new_cached(c, io, &self.recs.recs, warned, warnings, cached);
        drop(p1);
        let p1 = crate::prof::scope("lp.run");
        let (out, carry) = pass.run_cached(host);
        drop(p1);
        self.xcache.carry = Some(carry);
        io.maxc_on.set(false);
        let changed = match &self.placement.last {
            Some(prev) => prev.rects != out.rects,
            None => true,
        };
        self.placement.last = Some(out);
        let applier = applier.try_to::<Gd<Object>>().ok();
        let _p2 = crate::prof::scope("lp.place");
        for i in 0..n {
            self.placement.place_clean(io, i, &applier, forced[i], !chg[i]);
        }
        args(&[changed.to_variant()])
    }

    /// Lays out the subtrees of `roots` alone, from their rects and
    /// containing-block widths of the last layout_place (each root's border
    /// box cannot follow its content: UxmlDocument._local_root), and places
    /// the controls inside them; the roots keep their placement. `force`:
    /// indices re-applied since the last placement. Returns one bool per
    /// root: a rect of its subtree changed.
    #[func]
    fn layout_subtrees(
        &mut self,
        roots: PackedInt32Array,
        warned: VarDictionary,
        warnings: VarArray,
        applier: Variant,
        force: PackedInt32Array,
    ) -> VarArray {
        let (Some(c), Some(io)) = (self.inner.as_ref(), self.layout_in.as_ref()) else {
            return VarArray::new();
        };
        let Some(prev) = self.placement.last.as_ref() else {
            return VarArray::new();
        };
        self.recs.refresh(c);
        let n = c.len();
        let mut forced = vec![false; n];
        for &k in force.as_slice() {
            if k >= 0 && (k as usize) < n {
                forced[k as usize] = true;
            }
        }
        {
            let mut mc = io.maxc.borrow_mut();
            let mut uf = io.unfit.borrow_mut();
            let mut mg = io.margins.borrow_mut();
            let mut ct = io.cliptext.borrow_mut();
            for k in 0..n {
                if forced[k] {
                    mc[k] = None;
                    uf[k] = None;
                    mg[k] = None;
                    ct[k] = None;
                }
            }
        }
        let mut subs: Vec<(usize, Rect2, f64, f64, f64)> = vec![];
        for &r in roots.as_slice() {
            if r <= 0 || (r as usize) >= n {
                continue;
            }
            let r = r as usize;
            let Some(rect) = prev.raw.get(r).copied().flatten() else { continue };
            let (mut al, mut at) = (0.0f64, 0.0f64);
            let mut p = c.parent_of(r);
            while p >= 0 {
                if let Some(pr) = prev.raw[p as usize] {
                    al += pr.position.x as f64;
                    at += pr.position.y as f64;
                }
                p = c.parent_of(p as usize);
            }
            subs.push((r, rect, prev.cbs.get(r).copied().unwrap_or(0.0), al, at));
        }
        io.maxc_on.set(true);
        let _p = crate::prof::scope("layout_subtrees");
        let roots_u: Vec<usize> = subs.iter().map(|s| s.0).collect();
        self.xcache.drop_layouts(c, &roots_u);
        {
            // Re-applied here: the next placing pass sees them as changed.
            let mut t = io.touched.borrow_mut();
            for k in 0..n.min(t.len()) {
                if forced[k] {
                    t[k] = true;
                }
            }
        }
        let out = crate::layout::Pass::new_sub(c, io, &self.recs.recs, warned, warnings, &roots_u).run_subtrees(&subs);
        io.maxc_on.set(false);
        let mut result = VarArray::new();
        let last = self.placement.last.as_mut().unwrap();
        let mut placed: Vec<usize> = vec![];
        for &(r, _, _, _, _) in &subs {
            let mut changed = false;
            for j in r..c.subtree_end(r) {
                if last.rects[j] != out.rects[j] {
                    changed = true;
                }
                last.rects[j] = out.rects[j];
                last.raw[j] = out.raw[j];
                last.content[j] = out.content[j];
                last.insets[j] = out.insets[j];
                if out.rects[j].is_some() {
                    last.cbs[j] = out.cbs[j];
                }
                if j != r {
                    placed.push(j);
                }
            }
            result.push(&changed.to_variant());
        }
        let applier = applier.try_to::<Gd<Object>>().ok();
        for j in placed {
            self.placement.place(io, j, &applier, forced[j]);
        }
        result
    }

    /// Re-place (with inset hooks) the given elements from the last layout —
    /// the paint-only restyle path, where re-applied controls got fresh
    /// styleboxes but no layout ran.
    #[func]
    fn place_only(&mut self, applier: Variant, indices: PackedInt32Array) {
        let _p = crate::prof::scope("place_only");
        let Some(io) = self.layout_in.as_ref() else { return };
        let applier = applier.try_to::<Gd<Object>>().ok();
        for &k in indices.as_slice() {
            if k >= 0 {
                if let Some(t) = io.touched.borrow_mut().get_mut(k as usize) {
                    *t = true;
                }
                // Re-applied: apply() may have set or removed `uxml_clip_text`.
                if let Some(e) = io.cliptext.borrow_mut().get_mut(k as usize) {
                    *e = None;
                }
                self.placement.place(io, k as usize, &applier, true);
            }
        }
    }

    /// Per element: 1 when the last layout_place placed some element of its
    /// subtree (a rect, insets or control that changed), 0 when it skipped
    /// the whole subtree as clean. Empty before a layout_place. The layout
    /// hooks of the behaviors run for the subtrees that changed
    /// (UxmlDocument._run_layout_hooks).
    /// The rect of element i (relative to its parent) in the last placing
    /// layout: what the layout computed, before a Control clamps its size
    /// to its minimum (bench/equiv_v2.gd).
    #[func]
    fn placed_rect(&self, i: i64) -> Variant {
        match self.placement.last.as_ref().and_then(|o| o.rects.get(i as usize).copied().flatten()) {
            Some(r) => r.to_variant(),
            None => Variant::nil(),
        }
    }

    #[func]
    fn placed_subtrees(&self) -> PackedByteArray {
        let mut out = PackedByteArray::new();
        let (Some(c), r) = (self.inner.as_ref(), &self.placement.replaced) else { return out };
        let n = c.len();
        if r.len() != n {
            return out;
        }
        out.resize(n);
        let s = out.as_mut_slice();
        for i in (0..n).rev() {
            if r[i] {
                s[i] = 1;
            }
            if s[i] == 1 && i > 0 {
                let p = c.parent_of(i);
                if p >= 0 {
                    s[p as usize] = 1;
                }
            }
        }
        out
    }

    /// The content-box insets [start, end] (border + padding) of preorder
    /// index `i` from the last layout_place(), or [] when the element was
    /// not laid out (UxmlDocument.get_element_rect).
    #[func]
    fn insets_of(&self, i: i64) -> VarArray {
        let Some(out) = self.placement.last.as_ref() else {
            return VarArray::new();
        };
        if i < 0 {
            return VarArray::new();
        }
        match out.insets.get(i as usize).copied().flatten() {
            Some((s, e)) => args(&[s.to_variant(), e.to_variant()]),
            None => VarArray::new(),
        }
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
        let (r, cs, ins) = out.to_dicts(c);
        args(&[r.to_variant(), cs.to_variant(), ins.to_variant()])
    }

    /// Computed overrides for preorder index `i` ({property: {value,
    /// origin}}; empty clears them), applied on the next update.
    #[func]
    fn set_override(&mut self, i: i64, entries: VarDictionary) {
        if let Some(c) = self.inner.as_mut() {
            if i >= 0 {
                c.set_override(i as usize, entries);
            }
        }
    }

    /// Takes the placement state of `other`, a cascade over the same element
    /// tree (preorder indices are the same). The fits of Labels and Buttons
    /// and the last rects belong to the controls, not to a cascade: the
    /// GDScript path keeps them on the applier, the controls and `_rects`.
    #[func]
    fn adopt_placement(&mut self, mut other: Gd<UxmlNativeCascade>) {
        self.placement = std::mem::take(&mut other.bind_mut().placement);
    }

    #[func]
    fn patch_rule(&mut self, r: i64,dp: PackedStringArray, dv: PackedStringArray, df: PackedInt32Array, de: VarArray) {
        if let Some(c) = self.inner.as_mut() {
            if r >= 0 {
                c.patch_rule(r as usize, &dp, &dv, &df, &de);
            }
        }
    }

    /// See Cascade::recompile.
    #[func]
    fn recompile(&mut self, cascade: Gd<Object>) -> bool {
        match self.inner.as_mut() {
            Some(c) => c.recompile(&cascade),
            None => false,
        }
    }

    #[func]
    fn force_rules(&mut self, rs: PackedInt32Array, limit: i64) {
        if let Some(c) = self.inner.as_mut() {
            c.force_rules(rs.as_slice(), limit.max(0) as usize);
        }
    }

    /// The pre-override computed style of an overridden element, or null.
    #[func]
    fn target_style(&self, i: i64) -> Variant {
        match self.inner.as_ref().and_then(|c| if i >= 0 { c.target_style(i as usize) } else { None }) {
            Some(d) => d.to_variant(),
            None => Variant::nil(),
        }
    }

    /// Runtime v2: the output of `update` is the computed items per
    /// element (read natively), not Dictionaries.
    #[func]
    fn set_table_mode(&mut self, on: bool) {
        if let Some(c) = self.inner.as_mut() {
            c.set_table(on);
        }
    }

    /// Table mode: the computed style of element i ({prop: {value,
    /// origin}}, built on request).
    #[func]
    fn style_of(&self, i: i64) -> VarDictionary {
        match self.inner.as_ref() {
            Some(c) if i >= 0 && (i as usize) < c.len() => c.style_dict(i as usize),
            _ => VarDictionary::new(),
        }
    }

    /// The values of `props` in element i's computed style ({prop: {value}},
    /// the properties it has): style_of's values, without the rest.
    #[func]
    fn style_values(&self, i: i64, props: PackedStringArray) -> VarDictionary {
        match self.inner.as_ref() {
            Some(c) if i >= 0 && (i as usize) < c.len() => c.style_values(i as usize, &props),
            _ => VarDictionary::new(),
        }
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
        let _p = crate::prof::scope("effective_flags");
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
