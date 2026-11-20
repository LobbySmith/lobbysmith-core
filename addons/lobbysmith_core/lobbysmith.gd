extends Node
## LobbySmith Core session. Autoload name: LobbySmith.
##
## Host or join with one call, over LAN (ENet) or a Steam lobby. Everyone in the
## session sees the same player list. The host is the server. The host also
## shows one scene to everyone (change_scene); scene_entered says when every
## player has it.

enum EndReason { LEFT, HOST_LEFT }
enum JoinError { ROOM_FULL, CODE_UNKNOWN, STEAM_MISSING, TIMEOUT }

## Host: after hosting. Client: after receiving the player list.
signal session_started()
signal session_ended(reason: EndReason)
signal join_failed(error: JoinError)
## Emitted on everyone who was already in the session.
signal player_joined(id: int)
signal player_left(id: int)
## The current scene is in place: everyone has it, or scene_timeout has passed.
## A player who gets the scene later, or who joins later, gets their own
## scene_entered at that moment. Start the game on scene_entered.
## On a host with nobody else to wait for it comes on the next frame, never inside
## the change_scene call. It is never emitted for a scene that is no longer on
## the stage: a change started in between drops it.
signal scene_entered()
## On everyone when get_players()[id]["ready"] changes: the current scene is
## (or is not yet) standing at that player. change_scene sets everyone but the
## host to false; each player becomes true when they report the scene.
signal ready_changed(id: int)

const SteamTransport := preload("transport_steam.gd")
const RoomCode := preload("room_code.gd")
const Stage := preload("stage.gd")
const SharedState := preload("shared_state.gd")
const Rounds := preload("rounds.gd")
const DEFAULT_PORT := 24565
const MAX_NAME_LENGTH := 24
# shortcut: ENet only (no address on Steam), best effort against a continuous fast flood, and 3+ honest
# players from one address whose registration takes longer than SILENT_GRACE can be dropped and must
# retry. Upgrade (per-address rate limit, or a token sent with the connect) if a game opens a port to
# the internet.
## Host (LAN): connections from one address that are still no player after SILENT_GRACE
## seconds. At most this many are kept; the oldest beyond that are dropped, so a machine that
## opens silent connections cannot fill every seat for long.
const MAX_SILENT_PER_ADDRESS := 2
## Seconds a new connection has to register before it counts as silent. Players who join at
## the same moment from one address (one router, one machine) all register within this time.
const SILENT_GRACE := 1.0
## ENet keeps a "throttle" per connection and drops unreliable packets when round trip times rise
## (measured: for seconds after a join or a scene change, down to all of them). LAN connections
## get this configuration: interval and acceleration are ENet's defaults, deceleration 0 means the
## throttle never goes down, so ENet drops no unreliable packet on its own. Under real congestion
## such a packet arrives late instead of never.
const THROTTLE_INTERVAL_MS := 5000
const THROTTLE_ACCELERATION := 2
const THROTTLE_DECELERATION := 0

## Code points removed from player names (inclusive ranges). None of them shows a glyph, but
## they hide a name or reverse the text around it:
## U+0080-U+009F C1 controls; U+00AD soft hyphen; U+061C Arabic letter mark; U+200B-U+200F zero-width space and
## joiners, left-to-right / right-to-left marks; U+2028, U+2029 line and paragraph separator;
## U+202A-U+202E bidi embeddings and overrides; U+2060-U+206F word joiner, invisible operators,
## bidi isolates (U+2066-U+2069), deprecated format characters; U+FEFF zero-width no-break space.
const INVISIBLE := [[0x80, 0x9F], [0x61C, 0x61C], [0x200B, 0x200F], [0x2028, 0x202E],
		[0x2060, 0x206F], [0xFEFF, 0xFEFF], [0xAD, 0xAD]]

var max_players: int = 8
## Seconds a join attempt may take. The host also drops a connection that has not
## become a player after this time.
var join_timeout: float = 15.0
## Seconds a scene change waits for players who have not reported the scene. Then
## scene_entered comes for everyone who is ready; the others become ready when
## they report and get their own scene_entered then.
var scene_timeout: float = 15.0
## 480 is Valve's test app. Use your own app id for a released game.
var steam_app_id: int = 480
## Name shown to others. Empty: the Steam name on Steam, "Player N" on LAN.
var local_name: String = ""

var _players := {}        # id -> {"name": String, "ready": bool}
var _pending := {}        # host only: id -> info, joined but scene not there yet
var _strangers := {}      # host only (LAN): id -> {address, since} of connections, players included until they leave
var _held := {}           # host only: waiting id -> serial it reported, announced once the change ends
var _active := false
var _joining := false
var _awaiting_scene := false  # client: roster received, scene still on its way
var _changing := false    # host only: a scene change waits for ready flags
var _room_code := ""
var _join_counter := 0    # host only: running number for "Player N"
var _join_attempt := 0    # tells a stale timeout from the current attempt
var _steam: SteamTransport
var _using_steam := false
var _stage: Stage
## Small dictionary only the host changes. See shared_state.gd.
## On a late joiner it is still empty while the scene's _ready runs: read it in
## session_started (or react to state.changed).
var state: SharedState
## Minimal round flow, kept in `state`. See rounds.gd.
var rounds: Rounds


func _ready() -> void:
	_stage = Stage.new()
	_stage.name = "Stage"
	add_child(_stage)
	_stage.scene_arrived.connect(_on_stage_scene_arrived)
	_stage.spawner = MultiplayerSpawner.new()
	_stage.spawner.name = "StageSpawner"
	_stage.spawner.spawn_path = NodePath("../Stage")
	_stage.spawner.spawn_function = _stage.make_scene
	add_child(_stage.spawner)
	state = SharedState.new()
	state.name = "State"
	add_child(state)
	rounds = Rounds.new()
	rounds.name = "Rounds"
	add_child(rounds)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_fail_join.bind(JoinError.TIMEOUT))
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _process(_delta: float) -> void:
	if _using_steam:
		_steam.poll()
	if _awaiting_scene and _stage.get_scene() != null:
		_start_session()


func _notification(what: int) -> void:
	# Closing the window is leaving: clients then hear that the host left.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		leave()


func host_lan(port: int = DEFAULT_PORT) -> Error:
	if _active or _joining:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	# One connection more than there are seats, so the host can still tell a
	# player who comes too late why they are turned away.
	var error := peer.create_server(port, max_players)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	_active = true
	_join_counter = 0
	_players = {1: _new_player(local_name)}
	session_started.emit()
	return OK


func join_lan(ip: String, port: int = DEFAULT_PORT) -> Error:
	if _active or _joining:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(ip, port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	_begin_join()
	return OK


func is_steam_available() -> bool:
	return Engine.has_singleton("Steam")


## Opens a Steam lobby with a room code. OK means "started": the result
## arrives as session_started or join_failed.
func host_steam() -> Error:
	if _active or _joining:
		return ERR_ALREADY_IN_USE
	_begin_join()
	if not is_steam_available():
		_fail_attempt.call_deferred(_join_attempt, JoinError.STEAM_MISSING)
		return OK
	_use_steam()
	_steam.host(steam_app_id, max_players)
	return OK


## Joins the Steam lobby with this room code. Typed input is fine
## ("ab-c 2x3"). OK means "started", like host_steam.
func join_steam(code: String) -> Error:
	if _active or _joining:
		return ERR_ALREADY_IN_USE
	_begin_join()
	if not is_steam_available():
		_fail_attempt.call_deferred(_join_attempt, JoinError.STEAM_MISSING)
		return OK
	_use_steam()
	_steam.join(steam_app_id, RoomCode.normalize(code))
	return OK


## Leaves the session, or cancels a join attempt. Does nothing otherwise.
func leave() -> void:
	if not _active and not _joining:
		return
	var was_active := _active
	_reset()
	if was_active:
		session_ended.emit(EndReason.LEFT)


## Host only: everyone in the session (and everyone who joins later) sees this
## scene. Replaces the scene shown before. OK means "started": scene_entered
## comes once every player has the scene or scene_timeout has passed (start the
## game on scene_entered). Errors: ERR_UNAVAILABLE without a session,
## ERR_UNAUTHORIZED on a client, ERR_BUSY while a change is running,
## ERR_FILE_NOT_FOUND if path is not a scene under res://. A player who joins during the change
## is announced (player_joined) after it ended. If a handler of a signal emitted
## meanwhile calls leave(), the session is simply over and OK is still returned.
## Core removes the project's current scene (the one the game started with, for
## example the menu) for everyone in the session when the stage shows a scene.
## A player who is turned away or cancels keeps their own scene.
## On a late joiner the scene's _ready runs before the player list and
## LobbySmith.state have arrived: read them in session_started (or react to
## state.changed).
func change_scene(path: String) -> Error:
	if not _active:
		return ERR_UNAVAILABLE
	if not multiplayer.is_server():
		return ERR_UNAUTHORIZED
	if _changing:
		return ERR_BUSY
	if not Stage.is_scene_path(path):
		return ERR_FILE_NOT_FOUND
	_changing = true
	for id in _players.keys():
		if id != 1:
			_set_ready(id, false)
			if not _active:
				return OK   # a ready_changed handler left: the session is over
	var serial := _stage.show_scene(path)
	_check_scene_change(false)
	if _changing:
		get_tree().create_timer(scene_timeout).timeout.connect(_on_scene_timeout.bind(serial))
	return OK


## True while a scene change is running: from change_scene until every player has
## the scene, the time limit has passed, or the session ended.
func is_changing_scene() -> bool:
	return _changing


## The scene on the stage, or null.
func get_scene() -> Node:
	return _stage.get_scene()


func is_active() -> bool:
	return _active


func is_host() -> bool:
	return _active and multiplayer.is_server()


## The Steam room code. "" on LAN.
func get_room_code() -> String:
	return _room_code


## id -> {"name": String, "ready": bool}. A copy; changing it changes nothing.
func get_players() -> Dictionary:
	return _players.duplicate(true)


func _new_player(raw_name: String) -> Dictionary:
	_join_counter += 1
	var player_name := _strip_control(raw_name).strip_edges().left(MAX_NAME_LENGTH)
	if player_name == "":
		player_name = "Player %d" % _join_counter
	return {"name": player_name, "ready": true}


# Removes control characters from a name: codes below 32, DEL, the C1 controls, and the
# invisible Unicode format characters listed in INVISIBLE (see there).
# The raw text is cut first. The engine has already read the whole packet by then, so this
# only keeps the work here small; Core does not limit the packet size.
func _strip_control(text: String) -> String:
	var raw := text.left(256)
	var clean := ""
	for i in raw.length():
		var code := raw.unicode_at(i)
		if code >= 32 and code != 127 and not _is_invisible(code):
			clean += raw[i]
	return clean


func _is_invisible(code: int) -> bool:
	for span in INVISIBLE:
		if code >= span[0] and code <= span[1]:
			return true
	return false


func _begin_join() -> void:
	_joining = true
	_join_attempt += 1
	get_tree().create_timer(join_timeout).timeout.connect(_on_join_timeout.bind(_join_attempt))


func _on_join_timeout(attempt: int) -> void:
	_fail_attempt(attempt, JoinError.TIMEOUT)


# Failures that do not arise in the same call go through here, called deferred:
# a failure queued by an earlier attempt must not end a newer one, and
# join_failed never comes from inside host_steam() / join_steam().
func _fail_attempt(attempt: int, error: JoinError) -> void:
	if attempt == _join_attempt:
		_fail_join(error)


func _on_server_disconnected() -> void:
	# Deferred: the peer must not be replaced while it reports its own end.
	_host_gone.call_deferred(_join_attempt)


# `attempt` is the session or join attempt the signal belonged to; if it is over
# already (leave, a new attempt), there is nothing left to end.
func _host_gone(attempt: int) -> void:
	if attempt != _join_attempt:
		return
	if _active:
		_reset()
		session_ended.emit(EndReason.HOST_LEFT)
	else:
		_fail_join(JoinError.TIMEOUT)


## Host: every new connection has join_timeout to become a player.
func _on_peer_connected(id: int) -> void:
	# A client is connected directly only to the host (id 1).
	if is_host() or id == 1:
		var throttled := _packet_peer(id)
		if throttled != null:
			throttled.throttle_configure(THROTTLE_INTERVAL_MS, THROTTLE_ACCELERATION, THROTTLE_DECELERATION)
	if is_host():
		get_tree().create_timer(join_timeout).timeout.connect(_drop_stranger.bind(id))
		var packet_peer := _packet_peer(id)
		if packet_peer != null:
			_strangers[id] = {"address": packet_peer.get_remote_address(), "since": Time.get_ticks_msec()}
			get_tree().create_timer(SILENT_GRACE).timeout.connect(_limit_silent_connections.bind(id))


## Host (LAN): the connection `id` has had SILENT_GRACE seconds. If its address holds more than
## MAX_SILENT_PER_ADDRESS connections that are still no player and at least that old, the oldest
## are dropped. Players are never counted, so several players behind one router are fine.
## Steam has no address and is skipped.
func _limit_silent_connections(id: int) -> void:
	if not is_host() or not _strangers.has(id):
		return
	var address: String = _strangers[id]["address"]
	var limit := Time.get_ticks_msec() - int(SILENT_GRACE * 1000.0) + 50
	var same := _strangers.keys().filter(func(other: int) -> bool:
		return _strangers[other]["address"] == address and _strangers[other]["since"] <= limit \
				and not _players.has(other) and not _pending.has(other))
	while same.size() > MAX_SILENT_PER_ADDRESS:
		var oldest: int = same.pop_front()
		_strangers.erase(oldest)
		_disconnect_peer(oldest)


func _packet_peer(id: int) -> ENetPacketPeer:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	return enet.get_peer(id) if enet != null else null


## Host: drops the connection if it is still no player (never registered, or never
## reported the scene). Does nothing if it is gone, we are no host, or it is a player.
## A joiner held for a running scene change did everything right: it is checked again
## later (a joiner that falls back to plain waiting is dropped then).
func _drop_stranger(id: int) -> void:
	if not is_host() or _players.has(id):
		return
	if _held.has(id):
		get_tree().create_timer(join_timeout).timeout.connect(_drop_stranger.bind(id))
		return
	_pending.erase(id)
	_disconnect_peer(id)


## Host: a player's connection ended, for whatever reason.
func _on_peer_disconnected(id: int) -> void:
	_strangers.erase(id)
	if not is_host():
		return
	# Someone still waiting for the scene was never announced, so nobody hears of them leaving.
	if _pending.erase(id) or not _players.has(id):
		_held.erase(id)
		return
	_players.erase(id)
	for other in _others(id):
		_player_removed.rpc_id(other, id)
	player_left.emit(id)
	# A player who left no longer holds up a running change.
	_check_scene_change()


func _use_steam() -> void:
	if _steam == null:
		_steam = SteamTransport.new()
		_steam.hosted.connect(_on_steam_hosted)
		_steam.joined.connect(_on_steam_joined)
		_steam.failed.connect(func(reason: String):
			_fail_attempt.call_deferred(_join_attempt, JoinError[reason]))
	_using_steam = true


func _on_steam_hosted(peer: MultiplayerPeer, code: String) -> void:
	if not _joining:
		peer.close()
		return
	multiplayer.multiplayer_peer = peer
	_joining = false
	_active = true
	_room_code = code
	_join_counter = 0
	_players = {1: _new_player(_own_name())}
	session_started.emit()


func _on_steam_joined(peer: MultiplayerPeer, code: String) -> void:
	if not _joining:
		peer.close()
		return
	multiplayer.multiplayer_peer = peer
	_room_code = code


func _own_name() -> String:
	if local_name.strip_edges() == "" and _using_steam:
		return _steam.get_persona_name()
	return local_name


func _on_connected_to_server() -> void:
	_register.rpc_id(1, _own_name())


## Client to host. The name is only ever taken for the sender itself.
@rpc("any_peer", "call_remote", "reliable")
func _register(raw_name: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or _players.has(id) or _pending.has(id):
		return
	if _players.size() + _pending.size() >= max_players:
		_rejected.rpc_id(id, JoinError.ROOM_FULL)
		# Disconnect a moment later so the reason still arrives.
		get_tree().create_timer(0.5).timeout.connect(_disconnect_peer.bind(id))
		return
	var info := _new_player(raw_name)
	var roster := _players.duplicate(true)
	roster[id] = info
	var has_scene := _stage.get_scene() != null
	_receive_roster.rpc_id(id, roster, has_scene, state.get_all())
	if has_scene:
		# The stage's spawner is already sending the scene. Others hear of the
		# newcomer once it reports that the scene is there.
		_pending[id] = info
	else:
		_admit(id, info)


## Host: set a player's ready flag and tell everyone in the session.
func _set_ready(id: int, value: bool) -> void:
	if _players[id]["ready"] == value:
		return
	_players[id]["ready"] = value
	ready_changed.emit(id)
	if not _active:
		return   # a handler left
	# Waiting players get it too, so their roster is right when they become active.
	for other in _others(1):
		_ready_set.rpc_id(other, id, value)


@rpc("authority", "call_remote", "reliable")
func _ready_set(id: int, value: bool) -> void:
	if _players.has(id) and _players[id]["ready"] != value:
		_players[id]["ready"] = value
		if _active:
			ready_changed.emit(id)


## Host: ends the scene change once every player has the scene. `immediate`
## false inside change_scene: scene_entered then waits for the next frame.
func _check_scene_change(immediate := true) -> void:
	if not _changing:
		return
	for id in _players:
		if not _players[id]["ready"]:
			return
	_end_scene_change(immediate)


## Host: the time is up. Ends the change if it is still the one this timer was for.
func _on_scene_timeout(serial: int) -> void:
	if _changing and serial == _stage.get_serial():
		_end_scene_change()


## Host: ends the change; players who are not ready hear of it when they report.
## Players who joined during the change are announced now, after scene_entered.
## `immediate` false: the change ended inside change_scene, where the old scene is
## still in the tree until the end of the frame; the host's scene_entered then
## comes one frame later, after the old scene is gone.
func _end_scene_change(immediate := true) -> void:
	_changing = false
	var serial := _stage.get_serial()
	for id in _players:
		if id != 1 and _players[id]["ready"]:
			_entered.rpc_id(id, serial)
	if immediate:
		scene_entered.emit()
	else:
		_emit_entered_next_frame(serial)
	var held := _held
	_held = {}
	for id in held:
		# A handler may have left, removed the player or started another change:
		# then the joiner does not have the current scene and keeps waiting. It
		# reports the new scene when it arrives.
		if not _active:
			return
		if not _pending.has(id) or _changing or _stage.get_serial() != held[id]:
			continue
		_admit(id, _pending[id])
		_pending.erase(id)
		# A player_joined handler may have left or started a change meanwhile.
		if _active and not _changing and _stage.get_serial() == held[id]:
			_entered.rpc_id(id, held[id])


## Host: scene_entered one frame later, unless the scene is gone by then.
func _emit_entered_next_frame(serial: int) -> void:
	await get_tree().process_frame
	if _active and serial == _stage.get_serial():
		scene_entered.emit()


## Host to client: everyone has the scene with this number.
@rpc("authority", "call_remote", "reliable")
func _entered(serial: int) -> void:
	if _active and serial == _stage.get_serial():
		scene_entered.emit()


## Host: the player has everything. Tell the others.
func _admit(id: int, info: Dictionary) -> void:
	for other in _others(id):
		_player_added.rpc_id(other, id, info)
	_players[id] = info
	player_joined.emit(id)


## Host: everyone but the host and `except` who has a roster, waiting ones included.
func _others(except: int) -> Array:
	var ids := _players.keys() + _pending.keys()
	ids.erase(1)
	ids.erase(except)
	return ids


## Client to host: the scene with this number is on the stage.
@rpc("any_peer", "call_remote", "reliable")
func _scene_ready(serial: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not is_host() or serial != _stage.get_serial():
		return
	if _pending.has(id):
		if _changing:
			# Announced when the change ends.
			_held[id] = serial
			return
		_admit(id, _pending[id])
		_pending.erase(id)
		# A player_joined handler may have left or started a change meanwhile.
		if _active and not _changing and serial == _stage.get_serial():
			_entered.rpc_id(id, serial)
	elif _players.has(id) and not _players[id]["ready"]:
		_set_ready(id, true)
		if not _active or serial != _stage.get_serial():
			return   # a ready_changed handler left or started a new change
		if _changing:
			_check_scene_change()
		else:
			# Reported after the change ended without them.
			_entered.rpc_id(id, serial)


@rpc("authority", "call_remote", "reliable")
func _receive_roster(players: Dictionary, has_scene: bool, values: Dictionary) -> void:
	_players = players
	state._replace(values if state._is_valid(values) else {})
	if has_scene:
		_awaiting_scene = true
	else:
		_start_session()


## The stage replaces the scene the project started with, but only for a player
## who is in the session. A joiner who is not admitted yet keeps theirs.
## An active client tells the host about every scene that arrives.
func _on_stage_scene_arrived() -> void:
	if not _active:
		return
	_free_project_scene()
	if not multiplayer.is_server():
		_scene_ready.rpc_id(1, _stage.get_serial())


func _free_project_scene() -> void:
	var tree := get_tree()
	if _stage.get_scene() != null and tree.current_scene != null:
		tree.current_scene.queue_free()
		tree.current_scene = null


## Client: roster, state and scene are all here.
func _start_session() -> void:
	var needs_report := _awaiting_scene
	_awaiting_scene = false
	_joining = false
	_active = true
	_free_project_scene()
	if needs_report:
		_scene_ready.rpc_id(1, _stage.get_serial())
	session_started.emit()


@rpc("authority", "call_remote", "reliable")
func _player_added(id: int, info: Dictionary) -> void:
	_players[id] = info
	if _active:
		player_joined.emit(id)


@rpc("authority", "call_remote", "reliable")
func _player_removed(id: int) -> void:
	_players.erase(id)
	if _active:
		player_left.emit(id)


@rpc("authority", "call_remote", "reliable")
func _rejected(error: JoinError) -> void:
	_fail_attempt.call_deferred(_join_attempt, error)


func _disconnect_peer(id: int) -> void:
	if is_host() and multiplayer.get_peers().has(id):
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _fail_join(error: JoinError) -> void:
	if not _joining:
		return
	_reset()
	join_failed.emit(error)


func _reset() -> void:
	if _using_steam:
		_steam.close()
		_using_steam = false
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_stage.clear()
	state._clear()
	_players = {}
	_pending = {}
	_strangers = {}
	_held = {}
	_changing = false
	_active = false
	_joining = false
	_awaiting_scene = false
	_join_attempt += 1
	_room_code = ""
