class_name TrafficRoute
extends RefCounted
## One closed lane loop of the road traffic (see Traffic). A platoon leader's
## front bumper follows a planned trajectory X(u) along the loop: it brakes
## for bends, stops at pedestrian crossings while their light is red and
## sets off again on green. The lap time is a whole number of signal cycles,
## so the trajectory repeats exactly and every platoon slot is the same
## trajectory shifted by whole cycles: the lights look identical to all of
## them, and two slots never get closer than the check in _verify() allows.
## Everything is a pure function of time; nothing is simulated per frame.

const STEP := 1.0  # resampling distance of the lane polyline (m)
const CYCLE := 40.0  # signal cycle of every pedestrian crossing (s)
const RED := 13.0  # part of the cycle in which cars stop for pedestrians (s)
const RED_MARGIN := 0.4
const RESTART_DELAY := 1.2  # cars wait this long after the light turns green
const ACCEL := 1.7
const BRAKE := 2.2  # comfortable braking, also used for the speed profile
const BRAKE_MAX := 4.0
const LAT_ACCEL := 2.0  # sideways acceleration allowed in bends
const MIN_SPEED := 2.2
const SIM_DT := 0.5
const STOP_LINE := 3.2  # a stopped front bumper is this far before the crossing centre
const ZEBRA_CLEAR := 2.0  # half length of the crossing zone that stays empty in red
const MIN_GAP := 3.5  # smallest bumper gap between two platoon slots
const F_MIN := 0.6  # slowest cruise scale the lap-time fit may use
const Q_MIN := 0.4  # deepest slowdown of the closing stretch of the loop
const F_SCAN := 0.08
const SLOW_SPEED := 9.0  # class speeds from here up count as major road

var index := 0
var pts := PackedVector2Array()  # lane centre, XZ, evenly spaced, closed
var step := STEP
var length := 0.0
var cap := PackedFloat32Array()  # speed limit per sample (class and bends)
var class_speed := PackedFloat32Array()
var vprof := PackedFloat32Array()  # limit that also respects braking distances
var gates: Array = []  # [stop arc, signal phase, extra clearance seconds], by arc
var gate_ids: Array = []  # crossing index of each gate
var gate_slow := PackedFloat32Array()  # slowest limit while a platoon clears each gate
var vehicles: Array = []  # Traffic.Vehicle
var span := 0.0  # length of one platoon (leader front to last rear)
var tail_start := 0.0  # arc from which the closing stretch may slow down

var lap := 0.0  # seconds, a whole number of CYCLE
var slots := 0
var tab_x := PackedFloat64Array()  # leader front arc every SIM_DT seconds, lap + 1 entries
var tab_v := PackedFloat32Array()
var ready := false

var _rt := PackedFloat64Array()  # recorded simulation (time, arc, speed)
var _rs := PackedFloat64Array()
var _rv := PackedFloat32Array()


## `raw` is a closed polyline (XZ); segment i runs from raw[i] to raw[i + 1]
## and has the speed limit `limits[i]`.
func setup(raw: PackedVector2Array, limits: PackedFloat32Array) -> void:
	var p := raw
	var a := limits
	for _i in 2:
		var r := _chaikin(p, a)
		p = r[0]
		a = r[1]
	var n := p.size()
	var cum := PackedFloat64Array()
	cum.resize(n + 1)
	for i in n:
		cum[i + 1] = cum[i] + p[i].distance_to(p[(i + 1) % n])
	var total := cum[n]
	var count := maxi(int(roundf(total / STEP)), 8)
	step = total / count
	length = total
	pts.resize(count)
	class_speed.resize(count)
	var seg := 0
	for k in count:
		var target := k * step
		while seg < n - 1 and cum[seg + 1] < target:
			seg += 1
		var seg_len := cum[seg + 1] - cum[seg]
		pts[k] = p[seg].lerp(p[(seg + 1) % n], (target - cum[seg]) / seg_len if seg_len > 0.0 else 0.0)
		class_speed[k] = a[seg]
	_caps()


static func _chaikin(p: PackedVector2Array, a: PackedFloat32Array) -> Array:
	var n := p.size()
	var out := PackedVector2Array()
	var out_a := PackedFloat32Array()
	for i in n:
		var q := p[i]
		var r := p[(i + 1) % n]
		out.append(q.lerp(r, 0.25))
		out.append(q.lerp(r, 0.75))
		out_a.append(a[i])
		out_a.append(minf(a[i], a[(i + 1) % n]))
	return [out, out_a]


func _caps() -> void:
	var n := pts.size()
	cap.resize(n)
	var theta := PackedFloat32Array()
	theta.resize(n)
	for i in n:
		var d := pts[(i + 1) % n] - pts[i]
		theta[i] = atan2(d.y, d.x)
	for i in n:
		var turn := absf(angle_difference(theta[(i - 2 + n) % n], theta[(i + 2) % n]))
		var kappa := turn / (4.0 * step)
		var v := float(class_speed[i])
		if kappa > 0.0001:
			v = minf(v, sqrt(LAT_ACCEL / kappa))
		cap[i] = maxf(v, MIN_SPEED)


## Shares of the loop that lie on major roads.
func major_share() -> float:
	var n := 0
	for v in class_speed:
		if v >= SLOW_SPEED:
			n += 1
	return float(n) / maxf(class_speed.size(), 1.0)


## Turns the loop so that arc 0 lies far from every gate (the trajectory
## starts and ends at cruising speed there), then sorts the gates.
func set_gates(list: Array) -> void:
	# list: [arc of the crossing centre, phase, crossing index]
	gates.clear()
	gate_ids.clear()
	var arcs := []
	for g in list:
		arcs.append(fposmod(float(g[0]) - STOP_LINE, length))
	var shift := 0.0
	if not arcs.is_empty():
		var sorted := arcs.duplicate()
		sorted.sort()
		var best := -1.0
		for i in sorted.size():
			var nxt: float = sorted[(i + 1) % sorted.size()] + (length if i == sorted.size() - 1 else 0.0)
			var gap: float = nxt - float(sorted[i])
			if gap > best:
				best = gap
				shift = float(sorted[i]) + gap / 2.0
	var n := pts.size()
	var k0 := int(roundf(shift / step)) % n
	if k0 != 0:
		var np := PackedVector2Array()
		var ns := PackedFloat32Array()
		for i in n:
			np.append(pts[(i + k0) % n])
			ns.append(class_speed[(i + k0) % n])
		pts = np
		class_speed = ns
		_caps()
	var entries := []
	for i in list.size():
		entries.append([fposmod(float(list[i][0]) - STOP_LINE - k0 * step, length), float(list[i][1]), 0.0, int(list[i][2])])
	entries.sort_custom(func(a, b): return a[0] < b[0])
	for e in entries:
		gates.append([e[0], e[1], e[2]])
		gate_ids.append(e[3])
	_profile()


func _profile() -> void:
	var n := pts.size()
	vprof = cap.duplicate()
	for _pass in 2:
		for k in range(n - 1, -1, -1):
			var nxt := vprof[(k + 1) % n]
			vprof[k] = minf(vprof[k], sqrt(nxt * nxt + 2.0 * BRAKE * step))


func _speed_limit(s: float) -> float:
	var n := vprof.size()
	var x := s / step
	var i := int(x)
	return lerpf(vprof[i % n], vprof[(i + 1) % n], x - i)


# --- signals -----------------------------------------------------------------------

## Whether a red window of a crossing with this phase touches [t0, t1].
static func red_between(phase: float, t0: float, t1: float) -> bool:
	var k0 := floori((t0 - phase - RED) / CYCLE)
	for k in range(k0, k0 + 3):
		var a := phase + k * CYCLE
		if a < t1 and a + RED > t0:
			return true
	return false


## Earliest time from t on at which a platoon that needs `clear` seconds to
## cross does not meet a red window (it waits for the end of that red plus the
## restart delay).
static func go_time(phase: float, t: float, clear: float) -> float:
	var go := t
	var k0 := floori((t - phase - RED) / CYCLE)
	for k in range(k0, k0 + 4):
		var a := phase + k * CYCLE
		if a < go + clear + RED_MARGIN and a + RED > go - RED_MARGIN:
			go = a + RED + RESTART_DELAY
	return go


# --- leader trajectory -------------------------------------------------------------

## One lap of the platoon leader's front bumper at cruise scale `f`; `q` < 1
## slows the closing stretch after the last gate (it takes up whatever lap time
## the lights leave over). Returns the lap time, or -1 if it never finishes.
## `record` keeps the trajectory.
func _simulate(f: float, q: float, record: bool, limit := INF) -> float:
	var gi := 0
	var s := 0.0
	var v := f * vprof[0]
	var u := 0.0
	var stop := false
	var decided := false
	var waiting := false
	var open_at := 0.0
	var guard := 0
	if record:
		_rt.clear()
		_rs.clear()
		_rv.clear()
		_rt.append(0.0)
		_rs.append(0.0)
		_rv.append(v)
	while s < length:
		guard += 1
		if guard > 30000:
			return -1.0
		if u > limit:
			return u
		var vt := f * _speed_limit(s)
		if s > tail_start and q < 1.0:
			var w := (s - tail_start) / maxf(length - tail_start, 1.0)
			vt = maxf(vt * (q + (1.0 - q) * pow(absf(2.0 * w - 1.0), 2.0)), minf(vt, 1.6))
		var sg := INF
		if gi < gates.size():
			var g: Array = gates[gi]
			sg = g[0]
			var d := sg - s
			var ext := (span + 2.0 * ZEBRA_CLEAR) / maxf(minf(v, f * gate_slow[gi]), 2.0) + float(g[2])
			if waiting:
				vt = 0.0
				if u >= open_at:
					waiting = false
					stop = false
			elif not decided:
				if d <= v * v / (2.0 * BRAKE) + 5.0 + v * SIM_DT:
					decided = true
					var tp := u + d / maxf(v, 2.0)
					stop = red_between(float(g[1]), tp - 0.8, tp + ext + 0.8)
			elif not stop and d > 0.0:
				var tp2 := u + d / maxf(v, 2.0)
				if red_between(float(g[1]), tp2 - 0.8, tp2 + ext + 0.8) and v * v / (2.0 * BRAKE_MAX) < d - 0.5:
					stop = true
			if stop and not waiting:
				vt = minf(vt, sqrt(2.0 * BRAKE * maxf(d - 0.3, 0.0)))
		if waiting:
			v = 0.0
		elif vt > v:
			v = minf(v + ACCEL * SIM_DT, vt)
		else:
			v = maxf(v - BRAKE_MAX * SIM_DT, vt)
		var ns := s + v * SIM_DT
		if stop and not waiting and gi < gates.size():
			ns = minf(ns, sg - 0.02)
			if sg - ns < 0.35 and v < 0.25:
				waiting = true
				var span_d := STOP_LINE + 2.0 * ZEBRA_CLEAR + span
				var clear := maxf(sqrt(2.0 * span_d / ACCEL), span_d / maxf(f * gate_slow[gi], 2.0)) + 0.8
				open_at = go_time(float(gates[gi][1]), u + SIM_DT, clear)
				v = 0.0
		u += SIM_DT
		if gi < gates.size() and ns >= sg:
			gi += 1
			decided = false
			stop = false
			waiting = false
		if ns >= length:
			var frac := (length - s) / maxf(ns - s, 0.000001)
			var t_end := u - SIM_DT + SIM_DT * frac
			if record:
				_rt.append(t_end)
				_rs.append(length)
				_rv.append(v)
			return t_end
		s = ns
		if record:
			_rt.append(u)
			_rs.append(s)
			_rv.append(v)
	return u


## Finds the cruise scale that makes the lap a whole number of signal cycles,
## records that trajectory and checks the result. False if the loop cannot
## be made to work (it is then left out of the traffic).
func plan(platoon_span: float) -> bool:
	span = platoon_span
	ready = false
	_gate_speeds()
	for _attempt in 5:
		if not _fit():
			return false
		var bad := _verify()
		if bad == -1:
			ready = true
			return true
		if bad == -2:
			return false
		gates[bad][2] = float(gates[bad][2]) + 1.0
	return false


## The slowest speed limit along the stretch a platoon needs to clear each gate.
func _gate_speeds() -> void:
	gate_slow.resize(gates.size())
	var n := vprof.size()
	for gi in gates.size():
		var from := float(gates[gi][0]) + STOP_LINE - ZEBRA_CLEAR
		var to := from + 2.0 * ZEBRA_CLEAR + span
		var slow := INF
		var k := from
		while k <= to:
			slow = minf(slow, vprof[int(fposmod(k, length) / step) % n])
			k += step
		gate_slow[gi] = slow
	tail_start = length
	if not gates.is_empty():
		var last := float(gates[gates.size() - 1][0]) + STOP_LINE + ZEBRA_CLEAR + span + 2.0
		if length - last > 20.0:
			tail_start = last


func _fit() -> bool:
	var t_fast := _simulate(1.0, 1.0, false)
	if t_fast < 0.0:
		return false
	var m0 := maxi(1, ceili(t_fast / CYCLE - 0.0001))
	var gated := not gates.is_empty() and tail_start < length
	for m in range(m0, m0 + 3):
		var target := m * CYCLE
		var f := -1.0
		var q := 1.0
		if gated:
			# Scan the cruise scale for one whose lap fits between the
			# natural and the fully slowed closing stretch.
			var best_q := -1.0
			var fg := 1.0
			while fg >= F_MIN - 0.0001:
				var t_nat := _simulate(fg, 1.0, false, target + 1.0)
				if t_nat > target:
					break
				if t_nat > 0.0:
					var t_slow := _simulate(fg, Q_MIN, false)
					if t_slow >= target - 0.3:
						var sol := _secant(fg, true, Q_MIN, t_slow, 1.0, t_nat, target)
						if sol > best_q:
							best_q = sol
							f = fg
							q = sol
						if best_q > 0.7:
							break
				fg -= F_SCAN
			if f < 0.0:
				continue
		else:
			var t_lo := _simulate(F_MIN, 1.0, false)
			if t_lo < target:
				return false
			f = _secant(1.0, false, F_MIN, t_lo, 1.0, t_fast, target)
		var t_end := _simulate(f, q, true)
		if t_end > 0.0 and t_end <= target and target - t_end < 0.6:
			_tabulate(target, t_end)
			return true
	return false


## False-position search for the parameter (closing-stretch factor when
## `tail`, else cruise scale) at which the lap time reaches `target`; returns
## the faster side, whose time is at most `target`.
func _secant(f: float, tail: bool, lo: float, t_lo: float, hi: float, t_hi: float, target: float) -> float:
	for _i in 7:
		if target - t_hi < 0.25 or t_lo - t_hi < 0.01:
			break
		var x := lo + (hi - lo) * (t_lo - target) / (t_lo - t_hi)
		x = clampf(x, lo + (hi - lo) * 0.02, hi - (hi - lo) * 0.02)
		var t := _simulate(f, x, false, target + 1.0) if tail else _simulate(x, 1.0, false, target + 1.0)
		if t > target:
			lo = x
			t_lo = t
		else:
			hi = x
			t_hi = t
	return hi


func _tabulate(target: float, t1: float) -> void:
	var w := target / t1
	var n := roundi(target / SIM_DT)
	lap = target
	slots = roundi(target / CYCLE)
	tab_x.resize(n + 1)
	tab_v.resize(n + 1)
	var j := 0
	for k in n + 1:
		var tau := minf(k * SIM_DT / w, t1)
		while j < _rt.size() - 2 and _rt[j + 1] < tau:
			j += 1
		var span_t := _rt[j + 1] - _rt[j]
		var a := clampf((tau - _rt[j]) / span_t, 0.0, 1.0) if span_t > 0.0 else 0.0
		tab_x[k] = lerpf(_rs[j], _rs[j + 1], a)
		tab_v[k] = lerpf(_rv[j], _rv[j + 1], a) / w
	tab_x[n] = length


## -1 when the plan is sound; a gate index whose clearance must grow; -2 when
## slots would run into each other.
func _verify() -> int:
	var n := tab_x.size() - 1
	for gi in gates.size():
		var g: Array = gates[gi]
		var centre: float = float(g[0]) + STOP_LINE
		var zone_lo := centre - ZEBRA_CLEAR
		var zone_hi := centre + ZEBRA_CLEAR + span
		for k in n:
			var x0 := tab_x[k]
			var x1 := tab_x[k + 1]
			var inside := (x1 > zone_lo and x0 < zone_hi) or (x1 > zone_lo - length and x0 < zone_hi - length)
			if inside and red_between(float(g[1]), k * SIM_DT - RED_MARGIN, (k + 1) * SIM_DT + RED_MARGIN):
				return gi
	var behind := roundi(CYCLE / SIM_DT)
	for k in n:
		var ahead := tab_x[k] - span
		var kb := k - behind
		var x_behind := tab_x[kb] if kb >= 0 else tab_x[kb + n] - length
		if ahead - x_behind < MIN_GAP:
			return -2
	return -1


# --- queries -----------------------------------------------------------------------

## Leader front arc position at route time u (any real number).
func front(u: float) -> float:
	var t := fposmod(u, lap)
	var x := t / SIM_DT
	var k := mini(int(x), tab_x.size() - 2)
	var a := x - k
	var a2 := a * a
	var a3 := a2 * a
	var h := SIM_DT
	return (2.0 * a3 - 3.0 * a2 + 1.0) * tab_x[k] + (a3 - 2.0 * a2 + a) * h * tab_v[k] \
		+ (-2.0 * a3 + 3.0 * a2) * tab_x[k + 1] + (a3 - a2) * h * tab_v[k + 1]


## [speed, acceleration] of the leader at route time u.
func motion(u: float) -> Vector2:
	var t := fposmod(u, lap)
	var x := t / SIM_DT
	var k := mini(int(x), tab_x.size() - 2)
	var a := x - k
	return Vector2(lerpf(tab_v[k], tab_v[k + 1], a), (tab_v[k + 1] - tab_v[k]) / SIM_DT)


func point_at(s: float) -> Vector2:
	var n := pts.size()
	var x := fposmod(s, length) / step
	var i := int(x)
	return pts[i % n].lerp(pts[(i + 1) % n], x - i)


func dir_at(s: float) -> Vector2:
	var d := point_at(s + 1.5) - point_at(s - 1.5)
	return d.normalized() if d.length_squared() > 0.0001 else Vector2.RIGHT
