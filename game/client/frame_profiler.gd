class_name FrameProfiler
extends RefCounted
## Cheap per-section timing for --perf runs: wrap a section with
## `var t := FrameProfiler.start()` ... `FrameProfiler.add("name", t)`.

static var enabled := false
static var _totals := {}


static func start() -> int:
	return Time.get_ticks_usec() if enabled else 0


static func add(key: String, since_usec: int) -> void:
	if enabled:
		_totals[key] = int(_totals.get(key, 0)) + Time.get_ticks_usec() - since_usec


## "name=avg_ms ..." over `frames` frames, largest first; resets the totals.
static func report(frames: int) -> String:
	var keys := _totals.keys()
	keys.sort_custom(func(a, b): return int(_totals[a]) > int(_totals[b]))
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%.2f" % [k, float(_totals[k]) / 1000.0 / maxi(1, frames)])
	_totals.clear()
	return " ".join(parts)
