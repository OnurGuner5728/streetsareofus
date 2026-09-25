class_name SnapshotCodec
extends RefCounted
## Compact binary layouts for the two high-frequency messages.
## Inputs are quantized here, and the client simulates the quantized values
## so its prediction runs on exactly what the server will see.
##
## Input batch:  u8 count, then per input
##   u32 seq, s8 move_x, s8 move_y, u16 yaw, s8 pitch, u8 buttons
## Snapshot:     u32 tick, u32 ack_seq, f32x3 self_pos, f32x3 self_vel, u16 count,
##   then per entity: u32 id, f32x3 pos, u16 yaw, s8 pitch, u8 speed_dm, u8 flags

const MAX_INPUTS_PER_PACKET := Protocol.MAX_RESENT_INPUTS
const MAX_ENTITIES := 512
const ENTITY_BYTES := 21
const FLAG_GROUNDED := 1
const FLAG_SPRINT := 2
const FLAG_RIDING := 4


static func quantize_input(seq: int, mx: float, my: float, yaw: float, pitch: float, buttons: int) -> Dictionary:
	var qx := clampi(roundi(mx * 127.0), -127, 127)
	var qy := clampi(roundi(my * 127.0), -127, 127)
	var qyaw := _yaw_to_u16(yaw)
	var qpitch := clampi(roundi(pitch / (PI / 2.0) * 127.0), -127, 127)
	return {
		"seq": seq, "qx": qx, "qy": qy, "qyaw": qyaw, "qpitch": qpitch, "buttons": buttons & 0xFF,
		"mx": qx / 127.0, "my": qy / 127.0, "yaw": _u16_to_yaw(qyaw),
		"pitch": qpitch / 127.0 * (PI / 2.0),
	}


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
	return buf.data_array


## Returns an empty array for malformed packets.
static func decode_inputs(data: PackedByteArray) -> Array:
	if data.size() < 1:
		return []
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	var count := buf.get_u8()
	if count > MAX_INPUTS_PER_PACKET or data.size() != 1 + count * 10:
		return []
	var out := []
	for i in count:
		var seq := buf.get_u32()
		var qx := buf.get_8()
		var qy := buf.get_8()
		var qyaw := buf.get_u16()
		var qpitch := buf.get_8()
		var buttons := buf.get_u8()
		var inp := quantize_input(seq, 0, 0, 0, 0, buttons)
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


static func encode_snapshot(tick: int, ack_seq: int, self_pos: Vector3, self_vel: Vector3, entities: Array) -> PackedByteArray:
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
	return buf.data_array


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
	if data.size() != 34 + count * ENTITY_BYTES:
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
	return snap


static func _yaw_to_u16(yaw: float) -> int:
	return int(roundf(fposmod(yaw, TAU) / TAU * 65536.0)) % 65536


static func _u16_to_yaw(q: int) -> float:
	return q / 65536.0 * TAU
