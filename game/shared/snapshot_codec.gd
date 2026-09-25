class_name SnapshotCodec
extends RefCounted
## Compact binary layouts for the two high-frequency messages.
## Inputs are quantized here, and the client simulates the quantized values
## so its prediction runs on exactly what the server will see.
##
## Input batch:  u8 count, then per input
##   u32 seq, s8 move_x, s8 move_y, u16 yaw, s8 pitch, u8 buttons, u16 world_tick
## world_tick is the client's estimate of the server tick it saw when it
## made the input (low 16 bits). Moving obstacles (trams) are evaluated at
## that tick on both sides, so prediction and server agree exactly.
## Snapshot:     u32 tick, u32 ack_seq, f32x3 self_pos, f32x3 self_vel, u16 count,
##   then per entity: u32 id, f32x3 pos, u16 yaw, s8 pitch, u8 speed_dm, u8 flags,
##   then u16 prop_count and per moving prop: u16 id, s16x3 pos_cm, s16x4 quat

const MAX_INPUTS_PER_PACKET := Protocol.MAX_RESENT_INPUTS
const INPUT_BYTES := 12
const MAX_ENTITIES := 512
const ENTITY_BYTES := 21
const PROP_BYTES := 16
const MAX_PROPS := 256
const FLAG_GROUNDED := 1
const FLAG_SPRINT := 2
const FLAG_RIDING := 4


static func quantize_input(seq: int, mx: float, my: float, yaw: float, pitch: float, buttons: int, world_tick := 0) -> Dictionary:
	var qx := clampi(roundi(mx * 127.0), -127, 127)
	var qy := clampi(roundi(my * 127.0), -127, 127)
	var qyaw := _yaw_to_u16(yaw)
	var qpitch := clampi(roundi(pitch / (PI / 2.0) * 127.0), -127, 127)
	return {
		"seq": seq, "qx": qx, "qy": qy, "qyaw": qyaw, "qpitch": qpitch, "buttons": buttons & 0xFF,
		"mx": qx / 127.0, "my": qy / 127.0, "yaw": _u16_to_yaw(qyaw),
		"pitch": qpitch / 127.0 * (PI / 2.0), "wt": world_tick,
	}


## Full tick from the low 16 bits a client sent, taking the value closest
## to the server's own tick.
static func unwrap_tick(low: int, server_tick: int) -> int:
	var d := (server_tick - low) & 0xFFFF
	if d >= 0x8000:
		d -= 0x10000
	return server_tick - d


static func encode_inputs(inputs: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	var count := mini(inputs.size(), MAX_INPUTS_PER_PACKET)
	buf.put_u8(count)
	for i in range(inputs.size() - count, inputs.size()):
		var inp: Dictionary = inputs[i]
		buf.put_u32(inp.seq)
		buf.put_8(inp.qx)
		buf.put_8(inp.qy)
		buf.put_u16(inp.qyaw)
		buf.put_8(inp.qpitch)
		buf.put_u8(inp.buttons)
		buf.put_u16(int(inp.get("wt", 0)) & 0xFFFF)
	return buf.data_array


## Returns an empty array for malformed packets.
static func decode_inputs(data: PackedByteArray) -> Array:
	if data.size() < 1:
		return []
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	var count := buf.get_u8()
	if count > MAX_INPUTS_PER_PACKET or data.size() != 1 + count * INPUT_BYTES:
		return []
	var out := []
	for i in count:
		var seq := buf.get_u32()
		var qx := buf.get_8()
		var qy := buf.get_8()
		var qyaw := buf.get_u16()
		var qpitch := buf.get_8()
		var buttons := buf.get_u8()
		var inp := quantize_input(seq, 0, 0, 0, 0, buttons, buf.get_u16())
		inp.qx = clampi(qx, -127, 127)
		inp.qy = clampi(qy, -127, 127)
		inp.qyaw = qyaw
		inp.qpitch = clampi(qpitch, -127, 127)
		inp.mx = inp.qx / 127.0
		inp.my = inp.qy / 127.0
		inp.yaw = _u16_to_yaw(qyaw)
		inp.pitch = inp.qpitch / 127.0 * (PI / 2.0)
		out.append(inp)
	return out


static func encode_snapshot(tick: int, ack_seq: int, self_pos: Vector3, self_vel: Vector3, entities: Array, props := PackedByteArray()) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(tick)
	buf.put_u32(ack_seq)
	for v in [self_pos, self_vel]:
		buf.put_float(v.x)
		buf.put_float(v.y)
		buf.put_float(v.z)
	var count := mini(entities.size(), MAX_ENTITIES)
	buf.put_u16(count)
	for i in count:
		var e: Dictionary = entities[i]
		var pos: Vector3 = e.pos
		buf.put_u32(e.id)
		buf.put_float(pos.x)
		buf.put_float(pos.y)
		buf.put_float(pos.z)
		buf.put_u16(_yaw_to_u16(e.yaw))
		buf.put_8(clampi(roundi(float(e.pitch) / (PI / 2.0) * 127.0), -127, 127))
		buf.put_u8(clampi(roundi(float(e.speed) * 10.0), 0, 255))
		buf.put_u8(e.flags)
	var out := buf.data_array
	if props.is_empty():
		out.append_array(PackedByteArray([0, 0]))
	else:
		out.append_array(props)
	return out


## Prop poses: u16 count, then per prop u16 id, s16x3 position in cm,
## s16x4 rotation quaternion. Used in snapshots and in the join sync.
static func encode_props(poses: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	var count := mini(poses.size(), MAX_PROPS)
	buf.put_u16(count)
	for i in count:
		var entry: Array = poses[i]
		var xf: Transform3D = entry[1]
		buf.put_u16(int(entry[0]))
		for v in [xf.origin.x, xf.origin.y, xf.origin.z]:
			buf.put_16(clampi(roundi(v * 100.0), -32767, 32767))
		var q := xf.basis.get_rotation_quaternion()
		for v in [q.x, q.y, q.z, q.w]:
			buf.put_16(clampi(roundi(v * 32767.0), -32767, 32767))
	return buf.data_array


## [[id, Transform3D], ...] from encode_props data starting at `offset`,
## or null when malformed.
static func decode_props(data: PackedByteArray, offset := 0) -> Variant:
	if data.size() < offset + 2:
		return null
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	buf.seek(offset)
	var count := buf.get_u16()
	if count > MAX_PROPS or data.size() != offset + 2 + count * PROP_BYTES:
		return null
	var out := []
	for i in count:
		var id := buf.get_u16()
		var pos := Vector3(buf.get_16(), buf.get_16(), buf.get_16()) / 100.0
		var q := Quaternion(buf.get_16() / 32767.0, buf.get_16() / 32767.0, buf.get_16() / 32767.0, buf.get_16() / 32767.0)
		if q.length_squared() < 0.5:
			q = Quaternion.IDENTITY
		out.append([id, Transform3D(Basis(q.normalized()), pos)])
	return out


## Returns {} for malformed packets.
static func decode_snapshot(data: PackedByteArray) -> Dictionary:
	if data.size() < 34:
		return {}
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	var snap := {"tick": buf.get_u32(), "ack": buf.get_u32()}
	snap.self_pos = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	snap.self_vel = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	var count := buf.get_u16()
	var props_at := 34 + count * ENTITY_BYTES
	if count > MAX_ENTITIES or data.size() < props_at + 2:
		return {}
	var props: Variant = decode_props(data, props_at)
	if props == null:
		return {}
	var entities := []
	for i in count:
		entities.append({
			"id": buf.get_u32(),
			"pos": Vector3(buf.get_float(), buf.get_float(), buf.get_float()),
			"yaw": _u16_to_yaw(buf.get_u16()),
			"pitch": buf.get_8() / 127.0 * (PI / 2.0),
			"speed": buf.get_u8() / 10.0,
			"flags": buf.get_u8(),
		})
	snap.entities = entities
	snap.props = props
	return snap


static func _yaw_to_u16(yaw: float) -> int:
	return int(roundf(fposmod(yaw, TAU) / TAU * 65536.0)) % 65536


static func _u16_to_yaw(q: int) -> float:
	return q / 65536.0 * TAU
