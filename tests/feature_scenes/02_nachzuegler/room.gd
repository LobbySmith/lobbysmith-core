extends Node3D
## Feature scene 02: a room with crates and one figure per player. The host spawns
## and removes the figures; everything else is copied by the nodes' synchronizers.

const Menu := preload("../common/lan_menu.gd")

## Host: at most this many requests from one player in RATE_WINDOW_MS. Plenty for a button,
## far below what a changed client can send.
const RATE_LIMIT := 10
const RATE_WINDOW_MS := 1000

var _rate := {}   # host: sender id -> [window start (ms), requests in it]


func _ready() -> void:
	get_viewport().physics_object_picking = true   # lets the crates see mouse clicks
	%CountButton.pressed.connect(request_count)
	%LeaveButton.pressed.connect(LobbySmith.leave)
	LobbySmith.state.changed.connect(func(_key: String): _show_count())
	LobbySmith.player_left.connect(func(id: int): _rate.erase(id))   # a player who left keeps no entry
	LobbySmith.session_started.connect(_show_count)   # a late joiner may get the state after this scene
	LobbySmith.session_ended.connect(func(reason: LobbySmith.EndReason):
		Menu.return_to_menu(LobbySmith.get_tree(), reason))   # this room is already off the tree
	_show_count()


## Anyone may ask; only the host changes the count.
func request_count() -> void:
	_count.rpc_id(1)


## One line with everything a player sees, to compare between players.
func summary() -> String:
	var crates := []
	for i in 3:
		crates.append(get_node("Crate%d" % i).color_index)
	var figures := []
	for id: int in %Players.ids():
		var spot: Vector3 = %Players.figure_of(id).position
		figures.append("%d:(%.1f, %.1f)" % [id, spot.x, spot.z])
	return "count=%d crates=%s figures=[%s]" % [_current_count(), crates, ", ".join(figures)]


## Any peer may call this, so the host checks who asks and how often before it counts.
@rpc("any_peer", "call_local", "reliable")
func _count() -> void:
	if multiplayer.is_server() and request_allowed(_sender()):
		LobbySmith.state.set_value("count", _current_count() + 1)


## The peer that called the RPC (the host itself for its own call_local call).
func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


## Host: true for a player who has not asked too often. A connection that is no player yet
## (it may live up to join_timeout) is refused.
func request_allowed(sender: int) -> bool:
	if not LobbySmith.get_players().has(sender):
		return false
	# shortcut: fixed one-second window per sender and per node, no cap across nodes; add a
	# global cap per sender (or drop senders that keep hitting the limit) if strangers can join.
	var now := Time.get_ticks_msec()
	var slot: Array = _rate.get(sender, [now, 0])
	if now - int(slot[0]) >= RATE_WINDOW_MS:
		slot = [now, 0]
	slot[1] += 1
	_rate[sender] = slot
	return slot[1] <= RATE_LIMIT


func _current_count() -> int:
	return LobbySmith.state.get_value("count", 0)


func _show_count() -> void:
	%CounterLabel.text = "Count: %d" % _current_count()
