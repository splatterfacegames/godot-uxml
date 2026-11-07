class_name UssTransitions
extends RefCounted
## USS transitions (Unity 6 semantics) for one UxmlDocument.
##
## Ported in behaviour from Unity's StylePropertyAnimationSystem /
## ComputedTransitions / VisualTreeStyleUpdater (UnityCsReference 6000.0):
## the CSS "starting of transitions" rules, Unity's reversing shortening
## factor for interrupted transitions, delays held at the start value,
## discrete properties switching at an eased progress of 0.5, Unity's
## easing curves, and its per-frame collapsing of run/start/end/cancel
## events.
##
## The animated value of a running transition is written into the cascade
## as a computed override (UssCascade.set_override), so it IS the element's
## computed value: inheritance, layout and the style applier all see it.
## The cascade keeps the value it resolved itself (target_style), which is
## the end value when a style change arrives mid-transition.
##
## The document calls after_update() after every cascade update and
## advance() + tick() once per frame while active() is true. One GDScript
## implementation serves both cascade backends, so the native and GDScript
## paths animate identically by construction.

enum { K_COLOR, K_LENGTH, K_FLOAT, K_INT, K_DISCRETE, K_TRANSLATE, K_ORIGIN, K_ROTATE, K_SCALE, K_SIZE, K_SHADOW, K_FILTER, K_MATERIAL }

## Animatable longhands (the USS property reference's "Fully animatable" and
## "Discrete" rows) -> value kind. Order is the order `all` visits them.
const ANIMATABLE := {
	"color": K_COLOR, "font-size": K_LENGTH, "letter-spacing": K_LENGTH,
	"word-spacing": K_LENGTH, "-unity-paragraph-spacing": K_LENGTH,
	"-unity-text-outline-color": K_COLOR, "-unity-text-outline-width": K_FLOAT,
	"-unity-text-align": K_DISCRETE, "-unity-font-style": K_DISCRETE,
	"-unity-font": K_DISCRETE, "-unity-font-definition": K_DISCRETE,
	"visibility": K_DISCRETE, "white-space": K_DISCRETE, "text-shadow": K_SHADOW,
	"align-content": K_DISCRETE, "align-items": K_DISCRETE, "align-self": K_DISCRETE,
	"flex-direction": K_DISCRETE, "flex-wrap": K_DISCRETE, "justify-content": K_DISCRETE,
	"position": K_DISCRETE, "flex-basis": K_LENGTH, "flex-grow": K_FLOAT, "flex-shrink": K_FLOAT,
	"width": K_LENGTH, "height": K_LENGTH, "min-width": K_LENGTH, "min-height": K_LENGTH,
	"max-width": K_LENGTH, "max-height": K_LENGTH,
	"top": K_LENGTH, "right": K_LENGTH, "bottom": K_LENGTH, "left": K_LENGTH,
	"margin-top": K_LENGTH, "margin-right": K_LENGTH, "margin-bottom": K_LENGTH, "margin-left": K_LENGTH,
	"padding-top": K_LENGTH, "padding-right": K_LENGTH, "padding-bottom": K_LENGTH, "padding-left": K_LENGTH,
	"border-top-width": K_FLOAT, "border-right-width": K_FLOAT,
	"border-bottom-width": K_FLOAT, "border-left-width": K_FLOAT,
	"background-color": K_COLOR, "background-image": K_DISCRETE,
	"background-position-x": K_DISCRETE, "background-position-y": K_DISCRETE,
	"background-repeat": K_DISCRETE, "background-size": K_SIZE,
	"border-top-color": K_COLOR, "border-right-color": K_COLOR,
	"border-bottom-color": K_COLOR, "border-left-color": K_COLOR,
	"border-top-left-radius": K_LENGTH, "border-top-right-radius": K_LENGTH,
	"border-bottom-right-radius": K_LENGTH, "border-bottom-left-radius": K_LENGTH,
	"opacity": K_FLOAT, "overflow": K_DISCRETE, "text-overflow": K_DISCRETE,
	"-unity-overflow-clip-box": K_DISCRETE, "-unity-text-overflow-position": K_DISCRETE,
	"-unity-background-image-tint-color": K_COLOR,
	"-unity-slice-left": K_INT, "-unity-slice-right": K_INT,
	"-unity-slice-top": K_INT, "-unity-slice-bottom": K_INT,
	"-unity-slice-scale": K_FLOAT, "-unity-slice-type": K_DISCRETE,
	"translate": K_TRANSLATE, "rotate": K_ROTATE, "scale": K_SCALE, "transform-origin": K_ORIGIN,
	"filter": K_FILTER, "-unity-material": K_MATERIAL,
}

## transition-property shorthands -> the longhands they match
## (StylePropertyUtil.IsMatchingShorthand).
const SHORTHANDS := {
	"background-position": ["background-position-x", "background-position-y"],
	"border-color": ["border-top-color", "border-right-color", "border-bottom-color", "border-left-color"],
	"border-radius": ["border-top-left-radius", "border-top-right-radius",
		"border-bottom-right-radius", "border-bottom-left-radius"],
	"border-width": ["border-top-width", "border-right-width", "border-bottom-width", "border-left-width"],
	"flex": ["flex-grow", "flex-shrink", "flex-basis"],
	"margin": ["margin-top", "margin-right", "margin-bottom", "margin-left"],
	"padding": ["padding-top", "padding-right", "padding-bottom", "padding-left"],
	"-unity-background-scale-mode": ["background-position-x", "background-position-y",
		"background-repeat", "background-size"],
	"-unity-text-outline": ["-unity-text-outline-color", "-unity-text-outline-width"],
}

## The value a property has when the cascade leaves it unset (Unity's
## InitialStyle). null: the runtime renders an unset value from the Godot
## theme, which has no USS equivalent to interpolate from or to — such a
## change applies immediately.
const INITIAL := {
	"color": null, "font-size": null, "-unity-font": null, "-unity-font-definition": null,
	"letter-spacing": "0px", "word-spacing": "0px", "-unity-paragraph-spacing": "0px",
	"-unity-text-outline-color": "rgba(0, 0, 0, 0)", "-unity-text-outline-width": "0",
	"-unity-text-align": "upper-left", "-unity-font-style": "normal",
	"visibility": "visible", "white-space": "normal", "text-shadow": "0px 0px 0px rgba(0, 0, 0, 0)",
	"align-content": "flex-start", "align-items": "stretch", "align-self": "auto",
	"flex-direction": "column", "flex-wrap": "nowrap", "justify-content": "flex-start",
	"position": "relative", "flex-basis": "auto", "flex-grow": "0", "flex-shrink": "1",
	"width": "auto", "height": "auto", "min-width": "auto", "min-height": "auto",
	"max-width": "none", "max-height": "none",
	"top": "auto", "right": "auto", "bottom": "auto", "left": "auto",
	"margin-top": "0px", "margin-right": "0px", "margin-bottom": "0px", "margin-left": "0px",
	"padding-top": "0px", "padding-right": "0px", "padding-bottom": "0px", "padding-left": "0px",
	"border-top-width": "0", "border-right-width": "0", "border-bottom-width": "0", "border-left-width": "0",
	"background-color": "rgba(0, 0, 0, 0)", "background-image": "none",
	"background-position-x": "center", "background-position-y": "center",
	"background-repeat": "no-repeat no-repeat", "background-size": "auto auto",
	"border-top-color": "rgba(0, 0, 0, 0)", "border-right-color": "rgba(0, 0, 0, 0)",
	"border-bottom-color": "rgba(0, 0, 0, 0)", "border-left-color": "rgba(0, 0, 0, 0)",
	"border-top-left-radius": "0px", "border-top-right-radius": "0px",
	"border-bottom-right-radius": "0px", "border-bottom-left-radius": "0px",
	"opacity": "1", "overflow": "visible", "text-overflow": "clip",
	"-unity-overflow-clip-box": "padding-box", "-unity-text-overflow-position": "end",
	"-unity-background-image-tint-color": "rgb(255, 255, 255)",
	"-unity-slice-left": "0", "-unity-slice-right": "0", "-unity-slice-top": "0", "-unity-slice-bottom": "0",
	"-unity-slice-scale": "1", "-unity-slice-type": "sliced",
	"translate": "none", "rotate": "none", "scale": "none", "transform-origin": "center",
	"filter": "none", "-unity-material": "none",
}

## Properties whose percentages resolve against the parent's height / width
## (VisualElement.GetParentSizeForLengthConversion); radii, translate and
## transform-origin use the element's own size.
const _PARENT_H := {"top": true, "bottom": true, "height": true, "max-height": true, "min-height": true}
const _PARENT_W := {
	"left": true, "right": true, "width": true, "max-width": true, "min-width": true,
	"margin-top": true, "margin-right": true, "margin-bottom": true, "margin-left": true,
	"padding-top": true, "padding-right": true, "padding-bottom": true, "padding-left": true,
}
const _OWN_W := {
	"border-top-left-radius": true, "border-top-right-radius": true,
	"border-bottom-right-radius": true, "border-bottom-left-radius": true,
}

# Event state bits (StylePropertyAnimationSystem.TransitionState).
const _S_RUNNING := 1
const _S_STARTED := 2
const _S_ENDED := 4
const _S_CANCELED := 8

enum Event { RUN, START, END, CANCEL }

## Transition clock in milliseconds. Advanced by advance(); start times and
## delays are relative to it.
var now_ms := 0.0

## Resolves a percentage base for unit conversion:
## func(index: int, property: String, sub: int) -> float (NAN = unknown).
var size_of: Callable = Callable()

## The interpolation defaults of a custom filter function (Unity
## FilterParameterDeclaration.interpolationDefaultValue):
## func(index: int, ref: String, entry: Dictionary) -> Array of float/Color.
## Unset or empty: the parameters pad with 0.
var filter_defaults: Callable = Callable()

var _cascade: UssCascade
# index -> {property: anim Dictionary}
var _running := {}
# index -> {property: typed end value}
var _completed := {}
# index -> current override Dictionary (last written to the cascade)
var _written := {}
# Transitions that completed in the last tick: index -> {property: [typed
# end, end entry]}. Unity applies the end value to the computed style on
# completion, so it is the before-change value of the next style change
# even when the cascade has moved on (an inherited target, for example).
var _ended := {}
# Event queue of the current frame: key -> state bits, key -> [events]
var _ev_state := {}
var _ev_queue := {}

static var _compiled_cache := {}
static var _parse_cache := {}


func _init(cascade: UssCascade) -> void:
	_cascade = cascade


## True while any transition runs (the document processes frames only then).
func active() -> bool:
	return not _running.is_empty()


func advance(ms: float) -> void:
	now_ms += ms


func has_running(i: int) -> bool:
	return _running.has(i)


# ---------------------------------------------------------------------------
# Transition lists
# ---------------------------------------------------------------------------

## The computed transition list of a style: Array of [name, duration_ms,
## delay_ms, easing], with non-animatable names and entries whose combined
## duration is not positive removed (ComputeTransitionPropertyData). Lists
## shorter than transition-property repeat.
static func compiled(style: Dictionary) -> Array:
	var p = style.get("transition-property")
	var d = style.get("transition-duration")
	var dl = style.get("transition-delay")
	var tf = style.get("transition-timing-function")
	var ps := "all" if p == null else String(p["value"])
	var ds := "0s" if d == null else String(d["value"])
	var dls := "0s" if dl == null else String(dl["value"])
	var tfs := "ease" if tf == null else String(tf["value"])
	var key := ps + "\u0001" + ds + "\u0001" + dls + "\u0001" + tfs
	var hit = _compiled_cache.get(key)
	if hit != null:
		return hit
	var names := _list(ps, "all")
	var durs: Array = []
	for t in _list(ds, "0s"):
		durs.append(_time_ms(t))
	var delays: Array = []
	for t in _list(dls, "0s"):
		delays.append(_time_ms(t))
	var easings: Array = []
	for t in _list(tfs, "ease"):
		easings.append(maxi(0, UssProperties.EASING_MODES.find(t.to_lower())))
	var out: Array = []
	for k in names.size():
		var nm := String(names[k]).to_lower()
		if not (nm == "all" or ANIMATABLE.has(nm) or SHORTHANDS.has(nm)):
			continue
		var dur: int = durs[k % durs.size()] if not durs.is_empty() else 0
		var delay: int = delays[k % delays.size()] if not delays.is_empty() else 0
		if maxi(0, dur) + delay <= 0:
			continue
		var ef: int = easings[k % easings.size()] if not easings.is_empty() else 0
		out.append([nm, maxi(0, dur), delay, ef])
	if _compiled_cache.size() > 1024:
		_compiled_cache.clear()
	_compiled_cache[key] = out
	return out


static func _list(text: String, initial: String) -> PackedStringArray:
	var t := text.strip_edges()
	if t == "initial" or t == "unset" or t.is_empty():
		return PackedStringArray([initial])
	var out := PackedStringArray()
	for part in t.split(","):
		out.append(String(part).strip_edges())
	return out


## "2s" / "800ms" / bare seconds -> whole milliseconds, rounded half to even
## like Mathf.RoundToInt. Unreadable -> 0.
static func _time_ms(t: String) -> int:
	var s := t.strip_edges().to_lower()
	var v := 0.0
	if s.ends_with("ms"):
		var n := s.substr(0, s.length() - 2)
		if not n.is_valid_float():
			return 0
		v = n.to_float()
	elif s.ends_with("s"):
		var n2 := s.substr(0, s.length() - 1)
		if not n2.is_valid_float():
			return 0
		v = n2.to_float() * 1000.0
	elif s.is_valid_float():
		v = s.to_float() * 1000.0
	else:
		return 0
	return round_even(v)


static func round_even(v: float) -> int:
	var f := floorf(v)
	var r := v - f
	if r > 0.5:
		return int(f) + 1
	if r < 0.5:
		return int(f)
	return int(f) + (1 if int(f) % 2 != 0 else 0)


static func _matches(name: String, prop: String) -> bool:
	if name == prop or name == "all":
		return true
	var sh = SHORTHANDS.get(name)
	return sh != null and (sh as Array).has(prop)


static func _transition_for(list: Array, prop: String) -> Array:
	var k := list.size() - 1
	while k >= 0:
		if _matches(list[k][0], prop):
			return list[k]
		k -= 1
	return []


# ---------------------------------------------------------------------------
# Style changes
# ---------------------------------------------------------------------------

## Called after a cascade update with the changed indices and their previous
## computed styles (UssCascade.update / last_old). Starts, retargets and
## cancels transitions, writes the resulting overrides into the cascade and
## re-runs the cascade until the overrides are stable; returns the merged
## [changed, last_old] (previous style = the one before the first update).
func after_update(changed: PackedInt32Array, olds: Array, options: Dictionary) -> Array:
	if changed.is_empty():
		_ended.clear()
		return [changed, olds]
	if not _process_changes(changed, olds):
		_ended.clear()
		return [changed, olds]
	var pos := {}
	var m_changed := PackedInt32Array(changed)
	var m_old: Array = olds.duplicate()
	for k in changed.size():
		pos[changed[k]] = k
	for _pass in 4:
		# Only overrides changed since the previous update.
		var ch2 := _cascade.update(options, false, PackedInt32Array(), true)
		var o2: Array = _cascade.last_old
		var olds2: Array = []
		for k in ch2.size():
			var idx := ch2[k]
			var at = pos.get(idx)
			if at == null:
				pos[idx] = m_changed.size()
				m_changed.append(idx)
				m_old.append(o2[k])
				olds2.append(o2[k])
			else:
				olds2.append(m_old[at])
		if not _process_changes(ch2, olds2):
			break
	_ended.clear()
	return [m_changed, m_old]


func _process_changes(changed: PackedInt32Array, olds: Array) -> bool:
	var els: Array = _cascade.els
	var styles: Dictionary = _cascade.styles
	var dirty := {}
	for k in changed.size():
		var old = olds[k]
		if old == null:
			continue  # first style: nothing to transition from
		var i := changed[k]
		var tgt: Dictionary
		if _written.has(i):
			tgt = _cascade.target_style(i)
		else:
			tgt = styles[els[i]]
		var run = _running.get(i)
		if run == null and not (tgt.has("transition-duration") or tgt.has("transition-delay")):
			continue
		_process_element(i, old, tgt, dirty)
	for i in dirty:
		_write(i)
	return _flush_overrides()


func _process_element(i: int, old: Dictionary, tgt: Dictionary, dirty: Dictionary) -> void:
	var list := compiled(tgt)
	var run = _running.get(i)
	if run != null:
		# CancelAnimationsWithNoTransitionProperty
		for prop in (run as Dictionary).keys():
			if _transition_for(list, prop).is_empty():
				_cancel(i, prop, dirty)
		if not _running.has(i):
			run = null
	if list.is_empty():
		return
	var k := list.size() - 1
	while k >= 0:
		var t: Array = list[k]
		var nm: String = t[0]
		if nm == "all":
			for prop in ANIMATABLE:
				var just_ended: bool = _ended.has(i) and _ended[i].has(prop)
				if not _running.has(i) and not just_ended and _raw(old, prop) == _raw(tgt, prop):
					continue
				_start(i, prop, old, tgt, t[1], t[2], t[3], dirty)
		elif SHORTHANDS.has(nm):
			for prop in SHORTHANDS[nm]:
				_start(i, prop, old, tgt, t[1], t[2], t[3], dirty)
		else:
			_start(i, nm, old, tgt, t[1], t[2], t[3], dirty)
		k -= 1


static func _raw(style: Dictionary, prop: String):
	var e = style.get(prop)
	return null if e == null else e["value"]


## StylePropertyAnimationSystem.Values<T>.StartTransition.
func _start(i: int, prop: String, old: Dictionary, tgt: Dictionary,
		dur: int, delay: int, ef: int, dirty: Dictionary) -> void:
	var kind: int = ANIMATABLE[prop]
	var a_entry = old.get(prop)
	var b_entry = tgt.get(prop)
	if b_entry != null and _running.has(i):
		# Same end value as the running transition: nothing to do (the
		# per-frame case for an animating element).
		var r0 = _running[i].get(prop)
		if r0 != null and r0["b_entry"] != null and r0["b_entry"]["value"] == b_entry["value"]:
			return
	var a
	var ended = _ended.get(i)
	if ended != null and (ended as Dictionary).has(prop) and not (_running.has(i) and _running[i].has(prop)):
		a = ended[prop][0]
		a_entry = ended[prop][1]
	else:
		a = _typed(kind, prop, a_entry)
	var b = _typed(kind, prop, b_entry)
	if a == null or b == null:
		return  # unset theme value or keyword (auto/none): applies immediately
	var start = _converted(i, prop, kind, a, b)
	if start == null:
		return
	var combined := maxi(0, dur) + delay
	var comp = _completed.get(i)
	if comp != null and (comp as Dictionary).has(prop):
		if _same(kind, b, comp[prop]):
			return
		if combined <= 0:
			return
		comp.erase(prop)
		if comp.is_empty():
			_completed.erase(i)
	var run: Dictionary = _running.get(i, {})
	var cur = run.get(prop)
	if cur != null:
		var an: Dictionary = cur
		if _same(kind, b, an["b"]):
			return
		if _same(kind, b, an["cur"]):
			_queue_cancel(i, prop, an)
			_remove(i, prop, dirty)
			return
		if combined <= 0:
			_queue_cancel(i, prop, an)
			_remove(i, prop, dirty)
			return
		var s2 = _converted(i, prop, kind, an["cur"], b)
		if s2 == null:
			_queue_cancel(i, prop, an)
			_remove(i, prop, dirty)
			return
		var na := _anim(kind, s2, b, an["cur_entry"], b_entry, dur, delay, ef)
		na["index"] = i
		if _same(kind, b, an["ras"]):
			var rsf := clampf(absf(1.0 - (1.0 - float(an["eased"])) * float(an["rsf"])), 0.0, 1.0)
			na["rsf"] = rsf
			na["start_ms"] = now_ms + (round_even(delay * rsf) if delay < 0 else delay)
			na["dur"] = round_even(dur * rsf)
			na["ras"] = an["b"]
		an["started"] = false
		_queue_cancel(i, prop, an)
		_queue(i, prop, Event.RUN, an)
		run[prop] = na
		dirty[i] = true
		return
	if combined <= 0:
		return
	if _same(kind, start, b):
		return
	run[prop] = _anim(kind, start, b, a_entry, b_entry, dur, delay, ef)
	run[prop]["index"] = i
	_running[i] = run
	dirty[i] = true
	_queue(i, prop, Event.RUN, run[prop])


func _anim(kind: int, a, b, a_entry, b_entry, dur: int, delay: int, ef: int) -> Dictionary:
	return {
		"kind": kind, "a": a, "b": b, "ras": a, "cur": a,
		"a_entry": a_entry, "b_entry": b_entry, "cur_entry": a_entry,
		"start_ms": now_ms + delay, "dur": dur, "delay": delay, "ease": ef,
		"eased": 0.0, "rsf": 1.0, "started": false,
	}


## Cancel because the property left the element's transition list: the
## value jumps to the transition's end value (the target).
func _cancel(i: int, prop: String, dirty: Dictionary) -> void:
	var an: Dictionary = _running[i][prop]
	_queue_cancel(i, prop, an)
	_remove(i, prop, dirty)
	var comp = _completed.get(i)
	if comp != null:
		comp.erase(prop)
		if comp.is_empty():
			_completed.erase(i)


func _remove(i: int, prop: String, dirty: Dictionary) -> void:
	var run: Dictionary = _running[i]
	run.erase(prop)
	if run.is_empty():
		_running.erase(i)
	dirty[i] = true


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

## Advance every running transition to now_ms (UpdateProgress +
## UpdateValues) and write the changed overrides. Returns true when any
## override changed (the document then restyles).
func tick() -> bool:
	_ended.clear()
	if _running.is_empty():
		return false
	var dirty := {}
	for i in _running.keys():
		var run: Dictionary = _running[i]
		for prop in run.keys():
			var an: Dictionary = run[prop]
			var start: float = an["start_ms"]
			var dur: int = an["dur"]
			if now_ms < start:
				an["eased"] = 0.0
			elif now_ms >= start + dur:
				an["cur"] = an["b"]
				an["cur_entry"] = an["b_entry"]
				var comp: Dictionary = _completed.get(i, {})
				comp[prop] = an["b"]
				_completed[i] = comp
				var en: Dictionary = _ended.get(i, {})
				en[prop] = [an["b"], an["b_entry"]]
				_ended[i] = en
				_queue(i, prop, Event.END, an)
				run.erase(prop)
				dirty[i] = true
				continue
			else:
				if not an["started"]:
					an["started"] = true
					_queue(i, prop, Event.START, an)
				an["eased"] = easing(int(an["ease"]), (now_ms - start) / float(dur))
			var before = an["cur"]
			_lerp(an)
			if not is_same(before, an["cur"]):
				dirty[i] = true
		if run.is_empty():
			_running.erase(i)
	for i in dirty:
		_write(i)
	return _flush_overrides()


## Every running transition (in its delay or interpolating): Array of
## {index, property, from, to, value, start_time, delay, duration, easing,
## elapsed, progress}. Times in seconds on this clock: `start_time` is the
## moment the transition was started, the interpolation begins `delay`
## later and lasts `duration`; `elapsed` is the clock minus `start_time`;
## `progress` the eased progress (0 in the delay).
func snapshot() -> Array:
	var out: Array = []
	for i in _running:
		var run: Dictionary = _running[i]
		for prop in run:
			var an: Dictionary = run[prop]
			var kind: int = an["kind"]
			var begin: float = float(an["start_ms"]) - float(an["delay"])
			out.append({
				"index": i, "property": prop,
				"from": _serialize(kind, prop, an["a"], an["a_entry"]),
				"to": _serialize(kind, prop, an["b"], an["b_entry"]),
				"value": _serialize(kind, prop, an["cur"], an["cur_entry"]),
				"start_time": begin / 1000.0,
				"delay": float(an["delay"]) / 1000.0,
				"duration": float(an["dur"]) / 1000.0,
				"easing": UssProperties.EASING_MODES[int(an["ease"])],
				"elapsed": (now_ms - begin) / 1000.0,
				"progress": float(an["eased"]),
			})
	return out


## Scrub: put every running transition `ms` after its start (the delay
## included) and write the values. A transition put past its end shows the
## end value and keeps running; tick() completes it (and queues its end
## event) when the clock passes the end. No event is queued here. Returns
## true when an override changed.
func seek(ms: float) -> bool:
	if _running.is_empty():
		return false
	var dirty := {}
	for i in _running:
		var run: Dictionary = _running[i]
		for prop in run:
			var an: Dictionary = run[prop]
			an["start_ms"] = now_ms - ms + float(an["delay"])
			var start: float = an["start_ms"]
			var dur: int = an["dur"]
			if now_ms < start:
				an["eased"] = 0.0
				an["started"] = false
			elif dur <= 0 or now_ms >= start + dur:
				an["eased"] = easing(int(an["ease"]), 1.0)
				an["started"] = true
			else:
				an["eased"] = easing(int(an["ease"]), (now_ms - start) / float(dur))
				an["started"] = true
			var before = an["cur"]
			_lerp(an)
			if not is_same(before, an["cur"]):
				dirty[i] = true
	for i in dirty:
		_write(i)
	return _flush_overrides()


func _lerp(an: Dictionary) -> void:
	var t: float = an["eased"]
	var kind: int = an["kind"]
	if kind == K_FILTER:
		an["cur"] = _lerp_filter(an, clampf(t, 0.0, 1.0))
		return
	if kind == K_MATERIAL:
		an["cur"] = _lerp_material(an, t)
		return
	if kind == K_DISCRETE:
		var useb := t >= 0.5
		an["cur"] = an["b"] if useb else an["a"]
		an["cur_entry"] = an["b_entry"] if useb else an["a_entry"]
		return
	var a: Array = an["a"]
	var b: Array = an["b"]
	var out: Array = []
	for c in a.size():
		var x = a[c]
		var y = b[c]
		if x is Color:
			out.append(Color((x as Color).r + ((y as Color).r - (x as Color).r) * t,
				(x as Color).g + ((y as Color).g - (x as Color).g) * t,
				(x as Color).b + ((y as Color).b - (x as Color).b) * t,
				(x as Color).a + ((y as Color).a - (x as Color).a) * t))
		elif x is Array:
			if y[1] == "none":
				out.append([0.0, "none"])  # an interpolated value is never `none`
				continue
			var v: float = x[0] + (float(y[0]) - float(x[0])) * t
			if kind == K_INT:
				v = float(round_even(v))
			out.append([v, y[1]])
		else:
			out.append(y)
	an["cur"] = out


# Override entries -------------------------------------------------------

var _pending := {}


## Rebuild element i's override Dictionary from its running transitions.
func _write(i: int) -> void:
	var run = _running.get(i)
	var ov := {}
	if run != null:
		for prop in run:
			var an: Dictionary = run[prop]
			var e = an["cur_entry"] if an["kind"] == K_DISCRETE else an.get("src_entry", an["b_entry"])
			var origin = {"kind": "transition"} if e == null else e["origin"]
			ov[prop] = {"value": _serialize(an["kind"], prop, an["cur"], an["cur_entry"]), "origin": origin}
	var prev = _written.get(i)
	if prev == null and ov.is_empty():
		return
	if prev != null and prev == ov:
		return
	if ov.is_empty():
		_written.erase(i)
	else:
		_written[i] = ov
	_pending[i] = ov


func _flush_overrides() -> bool:
	if _pending.is_empty():
		return false
	for i in _pending:
		_cascade.set_override(i, _pending[i])
	_pending.clear()
	return true


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

func _key(i: int, prop: String) -> String:
	return "%d|%s" % [i, prop]


func _queue(i: int, prop: String, ev: int, an: Dictionary) -> void:
	var key := _key(i, prop)
	var bit := _S_RUNNING if ev == Event.RUN else (_S_STARTED if ev == Event.START else _S_ENDED)
	_ev_state[key] = int(_ev_state.get(key, 0)) | bit
	var elapsed := 0.0
	var delay: int = an["delay"]
	if ev == Event.END:
		elapsed = int(an["dur"]) / 1000.0
	elif delay < 0:
		elapsed = mini(maxi(-delay, 0), int(an["dur"])) / 1000.0
	var q: Array = _ev_queue.get(key, [])
	q.append([ev, i, prop, elapsed])
	_ev_queue[key] = q


## QueueTransitionCancelEvent: a cancel within the same frame as the run/
## start/end of the same transition removes both instead of sending them.
func _queue_cancel(i: int, prop: String, an: Dictionary) -> void:
	var key := _key(i, prop)
	var send := true
	if _ev_state.has(key):
		var st: int = _ev_state[key]
		if st == 0 or (st & _S_CANCELED) != 0:
			_ev_state[key] = _S_CANCELED
		else:
			_ev_state[key] = 0
			send = false
		_ev_queue.erase(key)
	else:
		_ev_state[key] = _S_CANCELED
	if not send:
		return
	var elapsed: float = (now_ms - float(an["start_ms"])) if an["started"] else 0.0
	var delay: int = an["delay"]
	if delay < 0:
		elapsed = -delay + elapsed
	var q: Array = _ev_queue.get(key, [])
	q.append([Event.CANCEL, i, prop, elapsed / 1000.0])
	_ev_queue[key] = q


## Hand the queued events to `emit(kind: Event, index, property, elapsed_s)`
## in queue order and clear the frame state.
func flush_events(emit: Callable) -> void:
	if _ev_queue.is_empty():
		_ev_state.clear()
		return
	var q := _ev_queue
	_ev_queue = {}
	_ev_state.clear()
	for key in q:
		for ev in q[key]:
			emit.call(ev[0], ev[1], ev[2], ev[3])


# ---------------------------------------------------------------------------
# Typed values
# ---------------------------------------------------------------------------
# Interpolable values are Arrays of components: Color, or [number, unit]
# (unit text kept for serialization: "px", "%", "deg", ""). Discrete values
# are [String]. null = not interpolable (keyword, unreadable, unset theme
# value).

func _typed(kind: int, prop: String, entry):
	var text
	if entry == null:
		text = INITIAL.get(prop)
		if text == null:
			return null
	else:
		text = entry["value"]
	var s := String(text).strip_edges()
	var key := "%d|%s|%s" % [kind, prop, s] if kind == K_ORIGIN else "%d|%s" % [kind, s]
	var hit = _parse_cache.get(key)
	if hit != null:
		return null if hit is bool else hit
	var v = _parse(kind, s)
	if _parse_cache.size() > 8192:
		_parse_cache.clear()
	_parse_cache[key] = false if v == null else v
	return v


static func _parse(kind: int, s: String):
	match kind:
		K_COLOR:
			var c := UssValues.parse_color(s)
			return [c["color"]] if c["ok"] else null
		K_LENGTH:
			var l = _len(s)
			return null if l == null else [l]
		K_FLOAT, K_INT:
			var n = _num(s)
			return null if n == null else [n]
		K_DISCRETE:
			return [s]
		K_TRANSLATE:
			if s == "none":
				return [[0.0, "px"], [0.0, "px"], [0.0, ""], [1.0, "none"]]
			var parts := UssProperties.split_value(s)
			if parts.is_empty() or parts.size() > 3:
				return null
			var out: Array = []
			for k in 2:
				var l2 = _len(parts[k]) if k < parts.size() else [0.0, "px"]
				if l2 == null:
					return null
				out.append(l2)
			var z = _num(parts[2]) if parts.size() > 2 else [0.0, ""]
			if z == null:
				return null
			out.append([z[0], ""])
			out.append([0.0, "none"])
			return out
		K_ORIGIN:
			var parts2 := UssProperties.split_value(s)
			if parts2.is_empty() or parts2.size() > 3:
				return null
			var x = [50.0, "%"]
			var y = [50.0, "%"]
			var vals: Array = []
			for p in parts2:
				vals.append(String(p))
			if vals.size() == 1:
				var only := String(vals[0])
				if only == "top" or only == "bottom":
					y = _origin_kw(only)
				else:
					x = _origin_kw(only) if _origin_kw(only) != null else _len(only)
			else:
				var v0 := String(vals[0])
				var v1 := String(vals[1])
				if v0 == "top" or v0 == "bottom" or v1 == "left" or v1 == "right":
					var tmp := v0
					v0 = v1
					v1 = tmp
				x = _origin_kw(v0) if _origin_kw(v0) != null else _len(v0)
				y = _origin_kw(v1) if _origin_kw(v1) != null else _len(v1)
			if x == null or y == null:
				return null
			var z2 = _num(vals[2]) if vals.size() > 2 else [0.0, ""]
			if z2 == null:
				return null
			return [x, y, [z2[0], ""]]
		K_ROTATE:
			if s == "none":
				return [[0.0, "deg"], [1.0, "none"]]
			var deg = _angle(s)
			return null if deg == null else [[deg, "deg"], [0.0, "none"]]
		K_SCALE:
			if s == "none":
				return [[1.0, ""], [1.0, ""], [1.0, ""], [1.0, "none"]]
			var parts3 := UssProperties.split_value(s)
			if parts3.is_empty() or parts3.size() > 3:
				return null
			var sx = _num(parts3[0])
			var sy = _num(parts3[1]) if parts3.size() > 1 else sx
			var sz = _num(parts3[2]) if parts3.size() > 2 else [1.0, ""]
			if sx == null or sy == null or sz == null:
				return null
			return [[sx[0], ""], [sy[0], ""], [sz[0], ""], [0.0, "none"]]
		K_SIZE:
			var parts4 := UssProperties.split_value(s)
			if parts4.is_empty() or parts4.size() > 2:
				return null
			if parts4.size() == 1:
				return null  # one value means "<x> auto": auto does not interpolate
			var w = _len(parts4[0])
			var h = _len(parts4[1])
			if w == null or h == null:
				return null
			return [w, h]
		K_SHADOW:
			var parts5 := UssProperties.split_value(s)
			var lens: Array = []
			var col = null
			for p2 in parts5:
				var ps := String(p2)
				var l3 = _len(ps)
				if l3 != null and lens.size() < 3:
					lens.append(l3)
					continue
				var c2 := UssValues.parse_color(ps)
				if not c2["ok"] or col != null:
					return null
				col = c2["color"]
			if lens.size() < 2:
				return null
			while lens.size() < 3:
				lens.append([0.0, "px"])
			return [lens[0], lens[1], lens[2], Color.BLACK if col == null else col]
		K_FILTER:
			var fr := UssValues.parse_filter(s)
			if not fr["ok"]:
				return null
			var funcs: Array = []
			for fn in fr["funcs"]:
				funcs.append([String(fn["name"]), String(fn["ref"]), (fn["params"] as Array).duplicate()])
			return [funcs]
		K_MATERIAL:
			var mr := UssValues.parse_material(s)
			if not mr["ok"]:
				return null
			var props: Array = []
			for pr in mr["props"]:
				props.append([String(pr["name"]), String(pr["type"]), pr["value"]])
			return [String(mr["ref"]), props]
	return null


static func _origin_kw(s: String):
	match s:
		"left", "top":
			return [0.0, "%"]
		"center":
			return [50.0, "%"]
		"right", "bottom":
			return [100.0, "%"]
	return null


## px/% length (bare numbers are px) -> [value, unit]; keywords -> null.
static func _len(s: String):
	var l := UssValues.parse_length(s)
	match l["kind"]:
		"px":
			return [float(l["value"]), "px"]
		"percent":
			return [float(l["value"]), "%"]
	return null


## Number with an optional px suffix -> [value, ""] (output as a bare
## number, which every reader of these properties accepts as px).
static func _num(s: String):
	var t := s.strip_edges()
	var k := t.length()
	while k > 0:
		var c := t.unicode_at(k - 1)
		if (c >= 48 and c <= 57) or c == 46:
			break
		k -= 1
	var n := t.substr(0, k)
	if n.is_empty() or not n.is_valid_float():
		return null
	var unit := t.substr(k).to_lower()
	if not (unit.is_empty() or unit == "px"):
		return null
	return [n.to_float(), ""]


static func _angle(s: String):
	var t := s.strip_edges().to_lower()
	var units := {"deg": 1.0, "grad": 0.9, "rad": 180.0 / PI, "turn": 360.0}
	for u in ["grad", "turn", "rad", "deg"]:
		if t.ends_with(u):
			var n := t.substr(0, t.length() - String(u).length())
			if n.is_valid_float():
				return n.to_float() * float(units[u])
			return null
	if t.is_valid_float():
		return t.to_float()  # unitless angle: degrees
	return null


## Value equality (SameFunc): Mathf.Approximately per float component for
## colors / lengths / numbers (with equal units), exact for the rest.
static func _same(kind: int, a: Array, b: Array) -> bool:
	if kind == K_FILTER or kind == K_MATERIAL:
		return a == b
	if a.size() != b.size():
		return false
	var exact := kind == K_TRANSLATE or kind == K_ROTATE or kind == K_SCALE or kind == K_ORIGIN or kind == K_SIZE or kind == K_SHADOW
	for c in a.size():
		var x = a[c]
		var y = b[c]
		if x is String:
			if not (y is String) or x != y:
				return false
		elif x is Color:
			var cx: Color = x
			var cy: Color = y
			if not (_approx(cx.r, cy.r) and _approx(cx.g, cy.g) and _approx(cx.b, cy.b) and _approx(cx.a, cy.a)):
				return false
		else:
			if x[1] != y[1]:
				return false
			if exact:
				if float(x[0]) != float(y[0]):
					return false
			elif not _approx(x[0], y[0]):
				return false
	return true


static func _approx(a: float, b: float) -> bool:
	return absf(b - a) < maxf(1e-6 * maxf(absf(a), absf(b)), 1.121039e-44 * 8.0)


## TryConvertLengthUnits for every length component of start value `a`
## against end value `b`: px <-> % through the percentage base; 0 of any
## unit converts to 0px. Returns the converted start value, or null when it
## is not convertible (the change then applies without a transition).
func _converted(i: int, prop: String, kind: int, a: Array, b: Array):
	if kind == K_FILTER:
		# ValuesListFilterFunction.ConvertUnits: the functions both lists
		# have must match in type (and, for filter(), in definition).
		var fa: Array = a[0]
		var fb: Array = b[0]
		for k in mini(fa.size(), fb.size()):
			if fa[k][0] != fb[k][0] or fa[k][1] != fb[k][1]:
				return null
		return a
	if kind == K_MATERIAL:
		# ValuesMaterialDefinition.ConvertUnits: to or from no material, or
		# the same material with matching property names and types.
		if String(a[0]).is_empty() != String(b[0]).is_empty():
			return a
		if a[0] != b[0]:
			return null
		for k in mini(a[1].size(), b[1].size()):
			if a[1][k][0] != b[1][k][0] or a[1][k][1] != b[1][k][1]:
				return null
		return a
	if a.size() != b.size():
		return null
	var out = null
	for c in a.size():
		var x = a[c]
		var y = b[c]
		if not (x is Array) or x[1] == y[1]:
			continue
		if not ((x[1] == "px" or x[1] == "%") and (y[1] == "px" or y[1] == "%")):
			return null
		var conv
		if y[1] == "px":
			if _approx(x[0], 0.0):
				conv = [0.0, "px"]
			else:
				var base := _base(i, prop, c)
				if is_nan(base) or not (base >= 0.0):
					return null
				conv = [float(x[0]) * base / 100.0, "px"]
		else:
			var base2 := _base(i, prop, c)
			if is_nan(base2) or not (base2 > 0.0):
				return null
			conv = [float(x[0]) * 100.0 / base2, "%"]
		if out == null:
			out = a.duplicate()
		out[c] = conv
	return a if out == null else out


func _base(i: int, prop: String, sub: int) -> float:
	if not size_of.is_valid():
		return NAN
	return size_of.call(i, prop, sub)


func _serialize(kind: int, _prop: String, v: Array, entry) -> String:
	if kind == K_DISCRETE:
		return v[0] if entry == null else String(entry["value"])
	if kind == K_FILTER:
		return _filter_text(v)
	if kind == K_MATERIAL:
		return _material_text(v)
	var parts := PackedStringArray()
	match kind:
		K_TRANSLATE:
			for c in 3:
				parts.append(_fmt(v[c]))
		K_ROTATE:
			parts.append(_fmt(v[0]))
		K_SCALE:
			for c in 3:
				parts.append(_fmt(v[c]))
		_:
			for x in v:
				parts.append(_fmt(x))
	return " ".join(parts)


static func _fmt(x) -> String:
	if x is Color:
		var c: Color = x
		return "rgba(%s, %s, %s, %s)" % [
			_n(clampf(c.r, 0.0, 1.0) * 255.0), _n(clampf(c.g, 0.0, 1.0) * 255.0),
			_n(clampf(c.b, 0.0, 1.0) * 255.0), _n(clampf(c.a, 0.0, 1.0))]
	return _n(x[0]) + String(x[1])


static func _n(v: float) -> String:
	var r := snappedf(v, 0.0001)
	if r == 0.0:
		return "0"
	if r == floorf(r) and absf(r) < 1e15:
		return str(int(r))
	return String.num(r, 4)


# ---------------------------------------------------------------------------
# Easing (UnityEngine.UIElements.Experimental.Easing + ComputedTransitions)
# ---------------------------------------------------------------------------

static func easing(mode: int, t: float) -> float:
	match mode:
		0:  # ease: Unity's best-fit cubic for cubic-bezier(0.25, 0.1, 0.25, 1)
			return t * (1.8 + t * (-0.6 + t * -0.2))
		1:
			return t * t
		2:
			return t * (2.0 - t)
		3:
			var t2 := t * 2.0
			if t2 < 1.0:
				return t2 * t2 * 0.5
			return -0.5 * ((t2 - 1.0) * (t2 - 3.0) - 1.0)
		4:
			return t
		5:
			return sin(PI / 2.0 * (t - 1.0)) + 1.0
		6:
			return sin(t * PI / 2.0)
		7:
			return (sin(PI * (t - 0.5)) + 1.0) * 0.5
		8:
			return pow(t, 3.0)
		9:
			return pow(t - 1.0, 3.0) + 1.0
		10:
			var t3 := t * 2.0
			if t3 < 1.0:
				return pow(t3, 3.0) * 0.5
			return 0.5 * (pow(t3 - 2.0, 3.0) + 2.0)
		11:
			return -(sqrt(1.0 - t * t) - 1.0)
		12:
			var t4 := t - 1.0
			return sqrt(1.0 - t4 * t4)
		13:
			var t5 := t * 2.0
			if t5 < 1.0:
				return -0.5 * (sqrt(1.0 - t5 * t5) - 1.0)
			t5 -= 2.0
			return 0.5 * (sqrt(1.0 - t5 * t5) + 1.0)
		14:
			return _in_elastic(t)
		15:
			return _out_elastic(t)
		16:
			if t < 0.5:
				return _in_elastic(t * 2.0) * 0.5
			return _out_elastic((t - 0.5) * 2.0) * 0.5 + 0.5
		17:
			return _in_back(t)
		18:
			return 1.0 - _in_back(1.0 - t)
		19:
			if t < 0.5:
				return _in_back(t * 2.0) * 0.5
			return (1.0 - _in_back(1.0 - (t - 0.5) * 2.0)) * 0.5 + 0.5
		20:
			return 1.0 - _out_bounce(1.0 - t)
		21:
			return _out_bounce(t)
		22:
			if t < 0.5:
				return (1.0 - _out_bounce(1.0 - t * 2.0)) * 0.5
			return _out_bounce((t - 0.5) * 2.0) * 0.5 + 0.5
	return t * (1.8 + t * (-0.6 + t * -0.2))


static func _in_elastic(t: float) -> float:
	if t == 0.0:
		return 0.0
	if t == 1.0:
		return 1.0
	var p := 0.3
	var s := p / 4.0
	var t2 := t - 1.0
	return -(pow(2.0, 10.0 * t2) * sin((t2 - s) * (2.0 * PI) / p))


static func _out_elastic(t: float) -> float:
	if t == 0.0:
		return 0.0
	if t == 1.0:
		return 1.0
	var p := 0.3
	var s := p / 4.0
	return pow(2.0, -10.0 * t) * sin((t - s) * (2.0 * PI) / p) + 1.0


static func _in_back(t: float) -> float:
	var s := 1.70158
	return t * t * ((s + 1.0) * t - s)


static func _out_bounce(t: float) -> float:
	if t < 1.0 / 2.75:
		return 7.5625 * t * t
	if t < 2.0 / 2.75:
		t -= 1.5 / 2.75
		return 7.5625 * t * t + 0.75
	if t < 2.5 / 2.75:
		t -= 2.25 / 2.75
		return 7.5625 * t * t + 0.9375
	t -= 2.625 / 2.75
	return 7.5625 * t * t + 0.984375


# ---------------------------------------------------------------------------
# filter and -unity-material (StylePropertyAnimationSystem
# ValuesListFilterFunction / ValuesMaterialDefinition)
# ---------------------------------------------------------------------------

## Interpolation default of parameter j of filter function `fn` (Unity
## FilterParameterDeclaration.interpolationDefaultValue of the built-in
## definitions; a custom definition's own values).
func _filter_default(an: Dictionary, fn: Array, j: int):
	match String(fn[0]):
		"tint":
			return Color(1, 1, 1, 1)
		"opacity":
			return 1.0
		"filter":
			if filter_defaults.is_valid():
				var entry = an["b_entry"] if an["b_entry"] != null else an["a_entry"]
				var d: Array = filter_defaults.call(int(an.get("index", -1)), String(fn[1]), entry)
				if j < d.size():
					return d[j]
	return 0.0


## GetFunctionOrDefault: the function at k, or the other list's function
## with interpolation-default parameters.
func _filter_or_default(an: Dictionary, src: Array, other: Array, k: int) -> Array:
	if k < src.size():
		return src[k]
	var f: Array = other[k]
	var params: Array = []
	for j in (f[2] as Array).size():
		params.append(_filter_default(an, f, j))
	return [f[0], f[1], params]


## Lerp of two filter lists: Mathf.Lerp / Color.Lerp (t clamped) per
## parameter; a shorter list pads with interpolation defaults.
func _lerp_filter(an: Dictionary, t: float) -> Array:
	var fa: Array = an["a"][0]
	var fb: Array = an["b"][0]
	var out: Array = []
	for k in maxi(fa.size(), fb.size()):
		var x := _filter_or_default(an, fa, fb, k)
		var y := _filter_or_default(an, fb, fa, k)
		var params: Array = []
		var px: Array = x[2]
		var py: Array = y[2]
		for j in px.size():
			var p = px[j]
			var q = py[j] if j < py.size() else p
			if p is Color and q is Color:
				params.append((p as Color).lerp(q, t))
			elif (p is float or p is int) and (q is float or q is int):
				params.append(lerpf(float(p), float(q), t))
			else:
				params.append(p)
		out.append([x[0], x[1], params])
	if fa.size() > fb.size():
		an["src_entry"] = an["a_entry"]
	return [out]


static func _zero_prop(p: Array) -> Array:
	match String(p[1]):
		"float":
			return [p[0], p[1], 0.0]
		"vector":
			return [p[0], p[1], [0.0, 0.0, 0.0, 0.0]]
		"color":
			return [p[0], p[1], Color(0, 0, 0, 0)]
	return [p[0], p[1], ""]


## Lerp of two material definitions: the end value itself above an eased
## progress of 0.999; else the start material (or the end one when there
## is none) with Vector4.Lerp per property and textures switching at 0.5.
func _lerp_material(an: Dictionary, t: float) -> Array:
	var a: Array = an["a"]
	var b: Array = an["b"]
	if t > 0.999:
		an.erase("src_entry")
		return b
	var ref: String = a[0] if not String(a[0]).is_empty() else b[0]
	if ref == String(a[0]) and ref != String(b[0]):
		an["src_entry"] = an["a_entry"]
	else:
		an.erase("src_entry")
	var tc := clampf(t, 0.0, 1.0)
	var pa: Array = a[1]
	var pb: Array = b[1]
	var props: Array = []
	for k in maxi(pa.size(), pb.size()):
		var x: Array = pa[k] if k < pa.size() else _zero_prop(pb[k])
		var y: Array = pb[k] if k < pb.size() else _zero_prop(pa[k])
		if x[1] != y[1]:
			props.append(x)
			continue
		match String(x[1]):
			"float":
				props.append([x[0], x[1], lerpf(float(x[2]), float(y[2]), tc)])
			"vector":
				var v: Array = []
				for c in 4:
					v.append(lerpf(float(x[2][c]), float(y[2][c]), tc))
				props.append([x[0], x[1], v])
			"color":
				props.append([x[0], x[1], (x[2] as Color).lerp(y[2], tc)])
			_:
				props.append(x if tc < 0.5 else y)
	return [ref, props]


static func _param_text(p) -> String:
	if p is Color:
		return _fmt(p)
	return _n(float(p))


static func _filter_text(v: Array) -> String:
	var funcs: Array = v[0]
	if funcs.is_empty():
		return "none"
	var parts := PackedStringArray()
	for fn in funcs:
		var args := PackedStringArray()
		if fn[0] == "filter":
			args.append(String(fn[1]))
		for p in fn[2]:
			args.append(_param_text(p))
		parts.append("%s(%s)" % [fn[0], " ".join(args)])
	return " ".join(parts)


static func _material_text(v: Array) -> String:
	if String(v[0]).is_empty():
		return "none"
	var parts := PackedStringArray([String(v[0])])
	for p in v[1]:
		var val := ""
		match String(p[1]):
			"float":
				val = _n(float(p[2]))
			"vector":
				var nums := PackedStringArray()
				for c in 4:
					nums.append(_n(float(p[2][c])))
				val = " ".join(nums)
			"color":
				val = _fmt(p[2])
			_:
				val = String(p[2])
		if val.is_empty():
			continue  # a texture property with no texture keeps the material's own
		parts.append('prop("%s" %s)' % [p[0], val])
	return " ".join(parts)
