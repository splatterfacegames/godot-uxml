class_name UxmlNumeric
extends RefCounted
## Text <-> value rules of Unity's numeric fields (IntegerField, LongField,
## FloatField, DoubleField, UnsignedIntegerField, UnsignedLongField,
## Hash128Field) and of the slider input field.
##
## The rules follow Unity 6000.3 as measured by tools/unity-dump/Assets/
## Editor/UxmlProbe.cs (bench/parity/probes/numeric.json): the field's own
## StringToValue/ValueToString for 70 inputs per type. The expression
## language is Unity's ExpressionEvaluator: + - * / % ^ ( ), unary minus,
## sqrt sin cos tan floor ceil round, L(a,b) (linear ramp) and R(a,b)
## (random), pi, the variables x v f # and the +=, -=, *=, /= forms that
## apply to the value before the edit. Intermediate results go through
## C#'s double.ToString() (15 significant digits) and back, as in Unity.
##
## Value types in GDScript: int for the integer fields (UnsignedLongField
## holds the 64-bit pattern: values above 2^63 - 1 are negative ints,
## `format()` shows them unsigned), float for FloatField (rounded to 32-bit
## float) and DoubleField, a 32-digit lowercase hex String for Hash128Field.

const FLOAT_MAX := 3.4028234663852886e38
const INT32_MIN := -2147483648
const INT32_MAX := 2147483647
const UINT32_MAX := 4294967295
const INT64_MIN := -9223372036854775807 - 1
const INT64_MAX := 9223372036854775807

## Characters a field accepts while typing (UINumericFieldsUtils).
const ALLOWED_FLOAT := "inftynaeINFTYNAE0123456789.,-*/+%^()cosqrludxvRL=pP#"
const ALLOWED_INT := "0123456789-*/+%^()cosintaqrtelfundxvRL,=pPI#"
const ALLOWED_HASH := "0123456789abcdefABCDEF"

## Field tag -> evaluator kind.
const KIND := {
	"IntegerField": "int", "LongField": "long", "UnsignedIntegerField": "uint",
	"UnsignedLongField": "ulong", "FloatField": "float", "DoubleField": "double",
	"Hash128Field": "hash", "SliderInt": "int", "Slider": "float",
}


## The value of a numeric UXML attribute (C# type parse, no expressions);
## the type's default when the text does not parse.
static func parse_attr(local: String, s: String) -> Variant:
	var kind: String = KIND.get(local, "double")
	match kind:
		"hash":
			return hash_parse(s)
		"float", "double":
			var r := _parse_real(s.strip_edges())
			var v: float = r[1] if r[0] else 0.0
			return to_f32(clamp_to_float(v)) if kind == "float" else v
		"ulong":
			var u := _parse_integer(s, true)
			return u[1] if u[0] else 0
	var r2 := _parse_integer(s, false)
	var n: int = r2[1] if r2[0] else 0
	if kind == "int":
		return clampi(n, INT32_MIN, INT32_MAX)
	if kind == "uint":
		return clampi(n, 0, UINT32_MAX) if r2[0] else 0
	return n


## Unity's StringToValue for a field of tag `local`: `text` is the typed
## text, `initial` the text before the edit (for += and x), `current` the
## value to keep when the text does not evaluate.
static func evaluate(local: String, text: String, initial: String, current: Variant) -> Variant:
	var kind: String = KIND.get(local, "double")
	match kind:
		"hash":
			return hash_parse(text)
		"float", "double":
			var r := _to_double(text, initial)
			if not r[0]:
				return current
			return to_f32(clamp_to_float(r[1])) if kind == "float" else float(r[1])
		"ulong":
			var u := _eval_ulong(text)
			if not u[0] and u[2] != null and not initial.is_empty():
				var o := _eval_ulong(initial)
				if o[0]:
					u = _eval_rpn_ulong(u[2], o[1])
			return u[1] if u[0] else current
	var r2 := _to_long(text, initial)
	if not r2[0]:
		return current
	var n: int = r2[1]
	if kind == "int":
		return clampi(n, INT32_MIN, INT32_MAX)
	if kind == "uint":
		return clampi(n, 0, UINT32_MAX)
	return n


## The text a field shows for `v` (Unity's ValueToString): "#######0" for
## the integer fields, "g7" for FloatField, "R" for DoubleField.
static func format(local: String, v: Variant) -> String:
	var kind: String = KIND.get(local, "double")
	match kind:
		"hash":
			return String(v)
		"float":
			return format_g(float(v), 7, false)
		"double":
			return format_r(float(v))
		"ulong":
			return String.num_uint64(int(v))
	return str(int(v))


## The allowed typing characters of a field ("" = any).
static func allowed(local: String) -> String:
	match KIND.get(local, ""):
		"float", "double":
			return ALLOWED_FLOAT
		"int", "long", "uint", "ulong":
			return ALLOWED_INT
	return ""


# ---------------------------------------------------------------------------
# Conversions
# ---------------------------------------------------------------------------

## The 32-bit float nearest to `v` (C# float), as a GDScript float.
static func to_f32(v: float) -> float:
	var a := PackedFloat32Array([v])
	return a[0]


## Mathf.ClampToFloat: finite values outside float's range clamp.
static func clamp_to_float(v: float) -> float:
	if is_nan(v) or is_inf(v):
		return v
	return clampf(v, -FLOAT_MAX, FLOAT_MAX)


## C# (long) cast of a double: truncation; NaN and out-of-range values give
## long.MinValue (x64 cvttsd2si).
static func double_to_long(v: float) -> int:
	if is_nan(v) or v >= 9.223372036854775807e18 or v < -9.223372036854775807e18:
		return INT64_MIN
	return int(v)


## C# (ulong) cast of a non-negative double (as Unity evaluates it).
static func double_to_ulong(v: float) -> int:
	if is_nan(v) or v >= 1.8446744073709552e19:
		return 0
	if v >= 9.223372036854775807e18:
		# Above 2^63 - 1: the int with the same 64 bits.
		return int(v - 9.223372036854775807e18) + INT64_MIN
	return int(v)


# ---------------------------------------------------------------------------
# C# number parsing (InvariantCulture)
# ---------------------------------------------------------------------------

static var _re_real: RegEx = null
static var _re_int: RegEx = null


## double.TryParse(s, NumberStyles.Float): [ok, value].
static func _parse_real(s: String) -> Array:
	if _re_real == null:
		_re_real = RegEx.create_from_string("^\\s*[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?\\s*$")
	if _re_real.search(s) == null:
		return [false, 0.0]
	var v := s.strip_edges().to_float()
	if is_inf(v):
		return [false, 0.0]  # OverflowException in C#
	return [true, v]


## long.TryParse / ulong.TryParse(s, NumberStyles.Integer): [ok, value].
static func _parse_integer(s: String, unsigned: bool) -> Array:
	if _re_int == null:
		_re_int = RegEx.create_from_string("^\\s*([+-]?)0*(\\d+)\\s*$")
	var m := _re_int.search(s)
	if m == null:
		return [false, 0]
	var neg := m.get_string(1) == "-"
	var digits := m.get_string(2)
	if unsigned:
		if neg and digits != "0":
			return [false, 0]
		if digits.length() > 20 or (digits.length() == 20 and digits > "18446744073709551615"):
			return [false, 0]
		if digits.length() < 19 or (digits.length() == 19 and digits <= "9223372036854775807"):
			return [true, digits.to_int()]
		# Above 2^63 - 1: the two's complement int of the same bits.
		var hi := digits.substr(0, digits.length() - 1).to_int()
		var lo := int(digits.substr(digits.length() - 1))
		return [true, hi * 10 + lo]
	var limit := "9223372036854775808" if neg else "9223372036854775807"
	if digits.length() > 19 or (digits.length() == 19 and digits > limit):
		return [false, 0]
	if digits == "9223372036854775808":
		return [true, INT64_MIN]
	var n := digits.to_int()
	return [true, -n if neg else n]


## ExpressionEvaluator.TryParse<T>: ',' -> '.', lower case, a trailing
## f/d/l after a digit removed, "" parses as 0, "pi" for the real types.
static func _try_parse(token: String, kind: String) -> Array:
	var e := token.replace(",", ".").to_lower()
	if e.length() > 1 and _is_digit(e.unicode_at(e.length() - 2)):
		while not e.is_empty() and e[e.length() - 1] in ["f", "d", "l"]:
			e = e.substr(0, e.length() - 1)
	if e.is_empty():
		return [true, 0.0 if kind == "double" else 0]
	match kind:
		"double":
			if e == "pi":
				return [true, PI]
			return _parse_real(e)
		"ulong":
			return _parse_integer(e, true)
	return _parse_integer(e, false)


static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57


## UINumericFieldsUtils.TryConvertStringToDouble with the initial text.
static func _to_double(text: String, initial: String) -> Array:
	var r := _to_double_plain(text)
	if not r[0] and r[2] != null and not initial.is_empty():
		var o := _to_double_plain(initial)
		if o[0]:
			return _eval_rpn(r[2], o[1])
	return r


## [ok, value, delayed RPN or null].
static func _to_double_plain(text: String) -> Array:
	match text.to_lower():
		"inf", "infinity":
			return [true, INF, null]
		"-inf", "-infinity":
			return [true, -INF, null]
		"nan":
			return [true, NAN, null]
	var p := _try_parse(text, "double")
	if p[0]:
		return [true, p[1], null]
	var ex := Expr.new(text)
	if ex.has_variables:
		return [false, 0.0, ex.rpn]
	return _eval_rpn(ex.rpn, 0.0)


## TryConvertStringToLong with the initial text: [ok, int].
static func _to_long(text: String, initial: String) -> Array:
	var r := _eval_long(text)
	if not r[0] and r[2] != null and not initial.is_empty():
		var o := _eval_long(initial)
		if o[0]:
			var d := _eval_rpn(r[2], float(o[1]))
			return [d[0], double_to_long(d[1])]
	return r


static func _eval_long(text: String) -> Array:
	var p := _try_parse(text, "long")
	if p[0]:
		return [true, p[1], null]
	var ex := Expr.new(text)
	if ex.has_variables:
		return [false, 0, ex.rpn]
	var d := _eval_rpn(ex.rpn, 0.0)
	return [d[0], double_to_long(d[1]), null]


static func _eval_ulong(text: String) -> Array:
	var p := _try_parse(text, "ulong")
	if p[0]:
		return [true, p[1], null]
	var ex := Expr.new(text)
	if ex.has_variables:
		return [false, 0, ex.rpn]
	return _eval_rpn_ulong(ex.rpn, 0)


static func _eval_rpn_ulong(rpn: PackedStringArray, start: int) -> Array:
	var startd := float(start) if start >= 0 else float(start) + 1.8446744073709552e19
	var d := _eval_rpn(rpn, startd)
	var v: float = d[1]
	if v < 0.0:
		v = 0.0
	return [d[0], double_to_ulong(v), null]


# ---------------------------------------------------------------------------
# ExpressionEvaluator
# ---------------------------------------------------------------------------

## name -> [precedence, inputs, right associative]
const OPS := {
	"-": [2, 2, false], "+": [2, 2, false], "/": [3, 2, false], "*": [3, 2, false],
	"%": [3, 2, false], "^": [5, 2, true], "_": [5, 1, false],
	"sqrt": [4, 1, false], "cos": [4, 1, false], "sin": [4, 1, false], "tan": [4, 1, false],
	"floor": [4, 1, false], "ceil": [4, 1, false], "round": [4, 1, false],
	"R": [4, 2, false], "L": [4, 2, false],
}


class Expr extends RefCounted:
	var rpn := PackedStringArray()
	var has_variables := false

	func _init(text: String) -> void:
		var t := UxmlNumeric._preformat(text)
		var tokens := UxmlNumeric._tokens(t)
		for tok in tokens:
			if UxmlNumeric._is_variable(tok) or tok == "R" or tok == "L":
				has_variables = true
		tokens = UxmlNumeric._fix_unary(tokens)
		rpn = UxmlNumeric._to_rpn(tokens)


static func _is_operator(t: String) -> bool:
	return OPS.has(t)


static func _is_command(t: String) -> bool:
	return t == "(" or t == ")" or t == "," or OPS.has(t)


static func _is_variable(t: String) -> bool:
	return t == "x" or t == "v" or t == "f" or t == "#"


static func _preformat(text: String) -> String:
	var r := text.strip_edges()
	if r.is_empty():
		return r
	var last := r[r.length() - 1]
	if _is_operator(last):
		while not r.is_empty() and r[r.length() - 1] == last:
			r = r.substr(0, r.length() - 1)
	if r.length() >= 2 and r[1] == "=":
		var op := r[0]
		var e := r.substr(2)
		match op:
			"+":
				r = "x+(%s)" % e
			"-":
				r = "x-(%s)" % e
			"*":
				r = "x*(%s)" % e
			"/":
				r = "x/(%s)" % e
	return r


static func _tokens(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for i in text.length():
		var c := text[i]
		if _is_command(c):
			if not cur.is_empty():
				out.append(cur)
			out.append(c)
			cur = ""
		elif c != " ":
			cur += c
		else:
			if not cur.is_empty():
				out.append(cur)
			cur = ""
	if not cur.is_empty():
		out.append(cur)
	return out


static func _fix_unary(tokens: PackedStringArray) -> PackedStringArray:
	if tokens.is_empty():
		return tokens
	if tokens[0] == "-":
		tokens[0] = "_"
	for i in range(1, tokens.size() - 1):
		if tokens[i] == "-" and _is_command(tokens[i - 1]) and tokens[i - 1] != ")":
			tokens[i] = "_"
	return tokens


static func _need_pop(stack: Array, op: String) -> bool:
	if stack.is_empty() or not OPS.has(op):
		return false
	var top: String = stack.back()
	if not OPS.has(top):
		return false
	var n: Array = OPS[op]
	var t: Array = OPS[top]
	if not n[2] and n[0] <= t[0]:
		return true
	return n[2] and n[0] < t[0]


static func _to_rpn(tokens: PackedStringArray) -> PackedStringArray:
	var ops: Array = []
	var out := PackedStringArray()
	for tok in tokens:
		if _is_command(tok):
			if tok == "(":
				ops.append(tok)
			elif tok == ")":
				while not ops.is_empty() and ops.back() != "(":
					out.append(ops.pop_back())
				if not ops.is_empty():
					ops.pop_back()
				if not ops.is_empty() and (ops.back() == "R" or ops.back() == "L"):
					out.append(ops.pop_back())
			elif tok == ",":
				while not ops.is_empty() and ops.back() != "(":
					out.append(ops.pop_back())
			else:
				while _need_pop(ops, tok):
					out.append(ops.pop_back())
				ops.append(tok)
		else:
			out.append(tok)
	while not ops.is_empty():
		out.append(ops.pop_back())
	return out


## EvaluateDouble: [ok, value]. `value` is the input of the variables.
static func _eval_rpn(rpn: PackedStringArray, value: float, index := 0, count := 1) -> Array:
	var stack: Array = []
	for tok in rpn:
		if _is_operator(tok):
			var spec: Array = OPS[tok]
			var vals: Array = []
			var parsed := true
			while not stack.is_empty() and not _is_command(stack.back()) and vals.size() < spec[1]:
				var p := _try_parse(stack.pop_back(), "double")
				parsed = parsed and p[0]
				vals.append(p[1] if p[0] else 0.0)
			vals.reverse()
			if parsed and vals.size() == spec[1]:
				stack.append(cs_double(_apply(tok, vals, index, count)))
			else:
				return [false, 0.0, null]
		elif _is_variable(tok):
			stack.append(str(index) if tok == "#" else cs_double(value))
		else:
			stack.append(tok)
	if stack.size() == 1:
		var p2 := _try_parse(stack.pop_back(), "double")
		if p2[0]:
			return [true, p2[1], null]
	return [false, value, null]


static func _apply(op: String, v: Array, index: int, count: int) -> float:
	var a: float = v[0] if v.size() >= 1 else 0.0
	var b: float = v[1] if v.size() >= 2 else 0.0
	match op:
		"_":
			return -a
		"+":
			return a + b
		"-":
			return a - b
		"*":
			return a * b
		"/":
			if b == 0.0:
				# IEEE division: C# gives NaN or an infinity, which the next
				# parse rejects.
				return NAN if a == 0.0 or is_nan(a) else (INF if a > 0.0 else -INF)
			return a / b
		"%":
			return fmod(a, b) if b != 0.0 else NAN
		"^":
			return pow(a, b)
		"sqrt":
			return 0.0 if a <= 0.0 else sqrt(a)
		"floor":
			return floorf(a)
		"ceil":
			return ceilf(a)
		"round":
			return round_even(a)
		"cos":
			return cos(a)
		"sin":
			return sin(a)
		"tan":
			return tan(a)
		"R":
			var r := _rand_uint() & 0xFFFFFF
			return a + (float(r) / float(0xFFFFFF)) * (b - a)
		"L":
			var c := maxi(count, 1)
			var f := 0.5 if c < 2 else float(index) / float(c - 1)
			return a + f * (b - a)
	return 0.0


## Math.Round: halves go to the even neighbour.
static func round_even(a: float) -> float:
	var f := floorf(a)
	var d := a - f
	if d > 0.5:
		return f + 1.0
	if d < 0.5:
		return f
	return f if fmod(f, 2.0) == 0.0 else f + 1.0


## Unity's PCG generator (state 0, sequence 0), shared by every field as in
## Unity.
static var _rng_state := 0
static var _rng_inc := 1
static var _rng_ready := false


static func _rng_step() -> void:
	_rng_state = _rng_state * 6364136223846793005 + _rng_inc


static func _rand_uint() -> int:
	if not _rng_ready:
		_rng_ready = true
		_rng_state = 0
		_rng_step()
		_rng_step()
	var s := _rng_state
	_rng_step()
	var xs := (((s >> 18) & 0x3FFFFFFFFFFF) ^ s)
	var x := ((xs >> 27) & 0x1FFFFFFFFF) & 0xFFFFFFFF
	var rot := (s >> 59) & 31
	return ((x >> rot) | (x << ((32 - rot) & 31))) & 0xFFFFFFFF


# ---------------------------------------------------------------------------
# C# number formatting
# ---------------------------------------------------------------------------

## C# double.ToString() under Unity's Mono: "G15"; NaN, Infinity,
## -Infinity spelled as C# spells them.
static func cs_double(v: float) -> String:
	return format_g(v, 15, true)


## [negative, digits (no leading zeros), decimal exponent of the first
## digit] of `v`, at most 17 significant digits.
static func _digits(v: float, exact17: bool) -> Array:
	var neg := v < 0.0 or (v == 0.0 and 1.0 / v < 0.0)
	var a := absf(v)
	if a == 0.0:
		return [neg, "0", 0]
	# String.num gives 17 significant digits in fixed notation, which is
	# exact enough only for moderate magnitudes; elsewhere the shortest
	# round-trip digits are used.
	var s := String.num(a, 20) if exact17 and a >= 1e-4 and a < 1e19 else String.num_scientific(a)
	var exp := 0
	var e_at := s.find("e")
	if e_at >= 0:
		exp = int(s.substr(e_at + 1))
		s = s.substr(0, e_at)
	var dot := s.find(".")
	var int_part := s if dot < 0 else s.substr(0, dot)
	var frac := "" if dot < 0 else s.substr(dot + 1)
	var all := int_part + frac
	var lead := 0
	while lead < all.length() and all[lead] == "0":
		lead += 1
	all = all.substr(lead)
	var first_exp := int_part.length() - 1 - lead + exp
	while all.length() > 1 and all.ends_with("0"):
		all = all.substr(0, all.length() - 1)
	return [neg, all, first_exp]


## C# "G<precision>" ("g" with lower-case e when not `upper`).
static func format_g(v: float, precision: int, upper := true) -> String:
	if is_nan(v):
		return "NaN"
	if is_inf(v):
		return "Infinity" if v > 0.0 else "-Infinity"
	var d := _digits(v, precision > 15)
	var digits: String = d[1]
	var exp: int = d[2]
	if digits.length() > precision:
		var keep := digits.substr(0, precision)
		var up := int(digits[precision]) >= 5
		digits = keep
		if up:
			var arr := digits.to_utf8_buffer()
			var i := arr.size() - 1
			while i >= 0:
				if arr[i] == 57:
					arr[i] = 48
					i -= 1
				else:
					arr[i] += 1
					break
			digits = arr.get_string_from_utf8()
			if i < 0:
				digits = "1" + digits
				exp += 1
			digits = digits.substr(0, precision)
		while digits.length() > 1 and digits.ends_with("0"):
			digits = digits.substr(0, digits.length() - 1)
	if digits == "0":
		return "0"
	var sign := "-" if d[0] else ""
	if exp >= precision or exp < -4:
		var mant := digits[0] + ("." + digits.substr(1) if digits.length() > 1 else "")
		var es := str(absi(exp))
		if es.length() < 2:
			es = "0" + es
		return "%s%s%s%s%s" % [sign, mant, "E" if upper else "e", "+" if exp >= 0 else "-", es]
	if exp < 0:
		return sign + "0." + "0".repeat(-exp - 1) + digits
	if digits.length() <= exp + 1:
		return sign + digits + "0".repeat(exp + 1 - digits.length())
	return sign + digits.substr(0, exp + 1) + "." + digits.substr(exp + 1)


## C# "R" for double under Mono: G15 when it round-trips, else G17.
static func format_r(v: float) -> String:
	var g15 := format_g(v, 15, true)
	if is_nan(v) or is_inf(v):
		return g15
	if g15.to_float() == v:
		return g15
	return format_g(v, 17, true)


# ---------------------------------------------------------------------------
# Hash128
# ---------------------------------------------------------------------------

## Hash128.Parse as measured: hex pairs left to right (a non-hex digit
## counts as 0), at most 16 bytes, an odd last digit ignored, except that a
## single digit is one byte.
static func hash_parse(s: String) -> String:
	var n := mini(s.length(), 32)
	var out := ""
	if n == 1:
		out = "0" + _hex_digit(s[0])
	else:
		for i in n / 2:
			out += _hex_digit(s[2 * i]) + _hex_digit(s[2 * i + 1])
	return out + "0".repeat(32 - out.length())


static func _hex_digit(c: String) -> String:
	var l := c.to_lower()
	return l if "0123456789abcdef".contains(l) else "0"
