extends SceneTree
## Parser equivalence: the native scanners (UxmlNativeParser) against the
## GDScript parsers, on every .uxml/.uss under tests/fixtures and the bench
## documents, plus seeded random mutations of each (deletions, insertions of
## syntax characters, duplications, truncations) — trees (ids, names,
## attributes, spans, children), USS items (incl. Dictionary key order) and
## warnings (incl. order) must be identical.
##
##   Godot --headless --path <project> -s res://bench/equiv_parse.gd [-- --mutations=N]

const NOISE := "<>/\"'=&;{}:*()[],.#@!?-_ \n\t\\x0"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	if not ClassDB.class_exists("UxmlNativeParser"):
		print("native core not loaded")
		quit(1)
		return
	# The comparator must be able to fail (key order, nested values).
	if _diff({"a": 1, "b": 2}, {"b": 2, "a": 1}, "").is_empty() or _diff([{"x": [1]}], [{"x": [2]}], "").is_empty():
		print("comparator self-test FAILED")
		quit(1)
		return
	var mutations := 40
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mutations="):
			mutations = int(a.substr(12))
	var files: Array = []
	_collect("res://tests/fixtures", files)
	_collect(UxmlBenchDir.of("godot_uxml_bench"), files)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		var is_uss: bool = String(path).ends_with(".uss")
		_compare(path, text, is_uss)
		for m in mutations:
			_compare("%s ~%d" % [path, m], _mutate(text, rng), is_uss)
	# Hand-picked edge cases.
	for t in ["", "<", "<a", "<a b", "<a b=", "<a b=\"", "<a b='x' b='y'/>", "<!-- x", "<![CDATA[", "<?x", "<a></b>", "<a/><b/>", "</a>", "<a>&#x110000000000000000;</a>", "<a v=\"&lt;&#38;lt;&#x41;&bogus;\"/>"]:
		_compare("uxml:" + t.c_escape(), t, false)
	for t in ["", "a", "a{", "a{b", "a{b:", "a{b:c", "@import", "@import \"x", "@import 'x';", "@media{a{b:c}}", ".a,{x:y}", "a > > b{}", "a + b{}", "a{b:\"c;d\";e:f}", "a{b:c/*x", "a{b:c/*x*/d}", "x{a:b}}", "/* unterminated", "a[x=\"]\"]{b:c}", ":hover(x){a:b}", "::before{a:b}"]:
		_compare("uss:" + t.c_escape(), t, true)
	print("EQUIV_PARSE %s: %d checks, %d failures" % ["OK" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _collect(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".uxml") or f.ends_with(".uss"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)


func _mutate(text: String, rng: RandomNumberGenerator) -> String:
	var t := text
	for k in 1 + rng.randi() % 4:
		if t.is_empty():
			t = NOISE[rng.randi() % NOISE.length()]
			continue
		var at := rng.randi() % t.length()
		match rng.randi() % 4:
			0:
				t = t.substr(0, at) + t.substr(at + 1 + rng.randi() % 8)
			1:
				t = t.substr(0, at) + NOISE[rng.randi() % NOISE.length()] + t.substr(at)
			2:
				t = t.substr(0, at) + t.substr(at, 1 + rng.randi() % 16) + t.substr(at)
			3:
				t = t.substr(0, at)
	return t


func _compare(name: String, text: String, is_uss: bool) -> void:
	_checks += 1
	var why := ""
	if is_uss:
		UssParser.use_native = false
		var a := UssParser.new().parse(text, "f.uss")
		UssParser.use_native = true
		var b := UssParser.new().parse(text, "f.uss")
		why = _diff(a, b, "uss")
	else:
		UxmlParser.use_native = false
		var a := UxmlParser.new().parse(text, "f.uxml")
		UxmlParser.use_native = true
		var b := UxmlParser.new().parse(text, "f.uxml")
		why = _diff(_tree(a["root"]), _tree(b["root"]), "tree")
		if why.is_empty():
			why = _diff(a["warnings"], b["warnings"], "warnings")
	if not why.is_empty():
		_fails += 1
		if _fails <= 10:
			print("FAIL %s: %s" % [name, why])


func _tree(el: UxmlElement) -> Dictionary:
	var kids: Array = []
	for c in el.children:
		kids.append(_tree(c))
	return {"id": el.id, "prefix": el.prefix, "local": el.local, "attributes": el.attributes,
		"open": [el.open_tag_start, el.open_tag_end, el.source_end], "children": kids}


func _diff(a, b, path: String) -> String:
	if typeof(a) != typeof(b):
		return "%s: type %s vs %s" % [path, typeof(a), typeof(b)]
	if a is Dictionary:
		var ka: Array = a.keys()
		var kb: Array = b.keys()
		if ka != kb:
			return "%s: keys %s vs %s" % [path, ka, kb]
		for k in ka:
			var s := _diff(a[k], b[k], "%s.%s" % [path, k])
			if not s.is_empty():
				return s
		return ""
	if a is Array:
		if a.size() != b.size():
			return "%s: size %d vs %d" % [path, a.size(), b.size()]
		for i in a.size():
			var s := _diff(a[i], b[i], "%s[%d]" % [path, i])
			if not s.is_empty():
				return s
		return ""
	return "" if a == b else "%s: %s vs %s" % [path, var_to_str(a), var_to_str(b)]
