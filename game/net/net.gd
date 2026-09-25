extends Node
## Autoload "Net": the whole RPC surface in one place.
## Godot matches RPCs by node path and method list, so client and server
## share this node. Every c_* call is handled on the server and every s_*
## call on the client; the bodies only forward to the active handler.
##
## Protocol messages (see the plan): AUTH/JOIN_ZONE = c_hello, PLAYER_INPUT =
## c_inputs, PLAYER_SNAPSHOT = s_snapshot, AVATAR_STATE = c_avatar/s_avatar,
## INTERACTION_REQUEST/ACCEPT/DECLINE = c_interaction_*, CHAT_MESSAGE,
## EMOTE, BLOCK_PLAYER, LEAVE_ZONE = disconnect.

var server: Node = null  ## ZoneServer when running as a server
var client: Node = null  ## GameClient when connected as a player
var peer: MultiplayerPeer = null
var _local_server_pid := -1

const WS_BUFFER := 1 << 20


## transport: "enet" (UDP; desktop) or "ws" (WebSocket; browsers and phones,
## which cannot use UDP). One zone server speaks one transport.
func start_server(port: int, transport := "enet") -> Error:
	close()
	var err: Error
	if transport == "ws":
		var ws := WebSocketMultiplayerPeer.new()
		_tune_ws(ws)
		err = ws.create_server(port)
		peer = ws
	else:
		var enet := ENetMultiplayerPeer.new()
		err = enet.create_server(port, Protocol.MAX_PEERS, 2)
		if err == OK:
			_unlimit_bandwidth(enet)
		peer = enet
	if err != OK:
		peer = null
		return err
	multiplayer.multiplayer_peer = peer
	return OK


## address: "host:port" for ENet, or a ws:// / wss:// URL for WebSocket.
func connect_to(address: String) -> Error:
	close()
	var err: Error
	if address.begins_with("ws://") or address.begins_with("wss://"):
		var ws := WebSocketMultiplayerPeer.new()
		_tune_ws(ws)
		err = ws.create_client(address)
		peer = ws
	else:
		var hp := split_host_port(address)
		var enet := ENetMultiplayerPeer.new()
		err = enet.create_client(hp[0], hp[1], 2)
		if err == OK:
			_unlimit_bandwidth(enet)
		peer = enet
	if err != OK:
		peer = null
		return err
	multiplayer.multiplayer_peer = peer
	return OK


static func split_host_port(text: String) -> Array:
	var host := text.strip_edges()
	var port := Protocol.DEFAULT_PORT
	var colon := host.rfind(":")
	if colon > 0:
		port = int(host.substr(colon + 1))
		host = host.substr(0, colon)
	return [host if not host.is_empty() else "127.0.0.1", port]


## Explicitly unlimited. Without this, a single round-trip spike (such as the
## client pausing to build the world) made ENet cap the unreliable packet
## throttle at 1/32, silently dropping ~97% of inputs for seconds.
static func _unlimit_bandwidth(enet: ENetMultiplayerPeer) -> void:
	enet.host.bandwidth_limit(0, 0)


## A phone on a slow link must not overflow the default 64 KB buffers.
static func _tune_ws(ws: WebSocketMultiplayerPeer) -> void:
	ws.inbound_buffer_size = WS_BUFFER
	ws.outbound_buffer_size = WS_BUFFER
	ws.max_queued_packets = 4096


func close() -> void:
	if peer:
		peer.close()
	peer = null
	multiplayer.multiplayer_peer = null


## ENet's RTT-based throttle drops unreliable packets whenever round-trip
## times jump. The game already repeats unacknowledged inputs and sends fresh
## snapshots constantly, so the throttle would only lose data here.
## WebSocket runs over TCP and has no such throttle.
func disable_throttling(peer_id: int) -> void:
	if peer is ENetMultiplayerPeer:
		var p: ENetPacketPeer = (peer as ENetMultiplayerPeer).get_peer(peer_id)
		if p:
			p.throttle_configure(5000, 0, 0)


## False while a peer is going away (closing WebSocket, disconnecting ENet
## peer); sending then only logs errors.
func is_open(peer_id: int) -> bool:
	if peer is WebSocketMultiplayerPeer:
		var ws: WebSocketPeer = (peer as WebSocketMultiplayerPeer).get_peer(peer_id)
		return ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	if peer is ENetMultiplayerPeer:
		var ep: ENetPacketPeer = (peer as ENetMultiplayerPeer).get_peer(peer_id)
		return ep != null and ep.get_state() == ENetPacketPeer.STATE_CONNECTED
	return true


## Disconnects a peer once the messages already queued for it are sent.
func kick(peer_id: int) -> void:
	if peer is ENetMultiplayerPeer:
		var p: ENetPacketPeer = (peer as ENetMultiplayerPeer).get_peer(peer_id)
		if p:
			p.peer_disconnect_later()
	elif peer:
		get_tree().create_timer(0.3).timeout.connect(func():
			if peer:
				peer.disconnect_peer(peer_id))


## Starts a headless dedicated server as a separate process ("host locally").
func spawn_local_server(port: int, zone_id: String) -> int:
	stop_local_server()
	var args := PackedStringArray(["--headless"])
	if not OS.has_feature("template"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--", "--server", "--port=%d" % port, "--zone=%s" % zone_id])
	_local_server_pid = OS.create_process(OS.get_executable_path(), args)
	return _local_server_pid


func stop_local_server() -> void:
	if _local_server_pid > 0:
		OS.kill(_local_server_pid)
	_local_server_pid = -1


func _exit_tree() -> void:
	stop_local_server()


func _sender() -> int:
	return multiplayer.get_remote_sender_id()


# --- client -> server --------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable", 1)
func c_hello(payload: Dictionary) -> void:
	if server:
		server.on_hello(_sender(), payload)


@rpc("any_peer", "call_remote", "unreliable", 0)
func c_inputs(data: PackedByteArray) -> void:
	if server:
		server.on_inputs(_sender(), data)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_interaction_request(target_id: int, kind: String) -> void:
	if server:
		server.on_interaction_request(_sender(), target_id, kind)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_interaction_response(request_id: int, accept: bool) -> void:
	if server:
		server.on_interaction_response(_sender(), request_id, accept)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_conversation_leave(other_id: int) -> void:
	if server:
		server.on_conversation_leave(_sender(), other_id)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_chat(text: String) -> void:
	if server:
		server.on_chat(_sender(), text)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_emote(kind: String) -> void:
	if server:
		server.on_emote(_sender(), kind)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_block(target_id: int) -> void:
	if server:
		server.on_block(_sender(), target_id)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_report(target_id: int, reason: String) -> void:
	if server:
		server.on_report(_sender(), target_id, reason)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_avatar(avatar: Dictionary) -> void:
	if server:
		server.on_avatar(_sender(), avatar)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_board(line: int, vehicle: int) -> void:
	if server:
		server.on_board(_sender(), line, vehicle)


@rpc("any_peer", "call_remote", "reliable", 1)
func c_blocked_list() -> void:
	if server:
		server.on_blocked_list(_sender())


@rpc("any_peer", "call_remote", "reliable", 1)
func c_unblock(account_id: String) -> void:
	if server:
		server.on_unblock(_sender(), account_id)


## Step off now if the tram is at a stop, otherwise toggle the stop request.
@rpc("any_peer", "call_remote", "reliable", 1)
func c_alight() -> void:
	if server:
		server.on_alight(_sender())


# --- server -> client --------------------------------------------------------

@rpc("authority", "call_remote", "reliable", 1)
func s_welcome(info: Dictionary) -> void:
	if client:
		client.on_welcome(info)


@rpc("authority", "call_remote", "reliable", 1)
func s_reject(reason: String) -> void:
	if client:
		client.on_reject(reason)


@rpc("authority", "call_remote", "unreliable", 0)
func s_snapshot(data: PackedByteArray) -> void:
	if client:
		client.on_snapshot(data)


@rpc("authority", "call_remote", "reliable", 1)
func s_entity_enter(id: int, info: Dictionary) -> void:
	if client:
		client.on_entity_enter(id, info)


@rpc("authority", "call_remote", "reliable", 1)
func s_entity_leave(id: int) -> void:
	if client:
		client.on_entity_leave(id)


@rpc("authority", "call_remote", "reliable", 1)
func s_interaction_incoming(request_id: int, from_id: int, kind: String) -> void:
	if client:
		client.on_interaction_incoming(request_id, from_id, kind)


@rpc("authority", "call_remote", "reliable", 1)
func s_interaction_result(request_id: int, result: String) -> void:
	if client:
		client.on_interaction_result(request_id, result)


@rpc("authority", "call_remote", "reliable", 1)
func s_conversation_open(other_id: int) -> void:
	if client:
		client.on_conversation_open(other_id)


@rpc("authority", "call_remote", "reliable", 1)
func s_conversation_close(other_id: int, reason: String) -> void:
	if client:
		client.on_conversation_close(other_id, reason)


@rpc("authority", "call_remote", "reliable", 1)
func s_chat(from_id: int, text: String) -> void:
	if client:
		client.on_chat(from_id, text)


@rpc("authority", "call_remote", "reliable", 1)
func s_emote(from_id: int, kind: String) -> void:
	if client:
		client.on_emote(from_id, kind)


@rpc("authority", "call_remote", "reliable", 1)
func s_avatar(id: int, avatar: Dictionary) -> void:
	if client:
		client.on_avatar(id, avatar)


@rpc("authority", "call_remote", "reliable", 1)
func s_notice(code: String, detail: String) -> void:
	if client:
		client.on_notice(code, detail)


## Your own ride: boarded {line, vehicle, slot, ack}, request {stop_request},
## or alighted {line: -1, pos, ack, reason, stop}.
@rpc("authority", "call_remote", "reliable", 1)
func s_ride(info: Dictionary) -> void:
	if client:
		client.on_ride(info)


## Someone else's ride: [line, vehicle, slot], or [] when they step off.
@rpc("authority", "call_remote", "reliable", 1)
func s_rider(id: int, ride: Array) -> void:
	if client:
		client.on_rider(id, ride)


## The zone's weather (see WeatherService), on joining and when it changes.
@rpc("authority", "call_remote", "reliable", 1)
func s_weather(info: Dictionary) -> void:
	if client:
		client.on_weather(info)


## Poses of every prop that is away from home, sent once on joining.
@rpc("authority", "call_remote", "reliable", 1)
func s_props(data: PackedByteArray) -> void:
	if client:
		client.on_props(data)


## People you have blocked: [{account, name, since}].
@rpc("authority", "call_remote", "reliable", 1)
func s_blocked_list(list: Array) -> void:
	if client:
		client.on_blocked_list(list)


## Player counts per 64 m cell, row-major from the north-west corner.
@rpc("authority", "call_remote", "reliable", 1)
func s_population(counts: PackedByteArray) -> void:
	if client:
		client.on_population(counts)
