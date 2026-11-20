extends Control
## Feature scene 08: the host starts and ends rounds, every player presses a point
## button during a round. The points live in LobbySmith.state under "points"; the round
## itself lives in LobbySmith.rounds (key "lobbysmith:round", not written here).

const Menu := preload("../common/lan_menu.gd")

## Host: at most this many point requests from one player in RATE_WINDOW_MS. Plenty for a
## button; raise it for a game where players press faster.
const RATE_LIMIT := 10
const RATE_WINDOW_MS := 1000

var _rate := {}   # host: sender id -> [window start (ms), requests in it]


func _ready() -> void:
	%StartButton.pressed.connect(_start)
	%EndButton.pressed.connect(_end)
	%PointButton.pressed.connect(_press_point)
	%LeaveButton.pressed.connect(LobbySmith.leave)
	LobbySmith.state.changed.connect(func(_key: String): _refresh())
	LobbySmith.player_left.connect(func(id: int): _rate.erase(id))   # a player who left keeps no entry
	# A late joiner may get the state after this scene.
	LobbySmith.session_started.connect(_refresh)
	LobbySmith.session_ended.connect(func(reason: LobbySmith.EndReason):
		Menu.return_to_menu(LobbySmith.get_tree(), reason))   # this room is already off the tree
	_refresh()


## One line with everything a player sees, to compare between players.
func summary() -> String:
	return "round=%d running=%d points=%d" % [LobbySmith.rounds.get_number(), int(LobbySmith.rounds.is_running()), _points()]


func _start() -> void:
	# Points first: `started` must find the new count.
	LobbySmith.state.set_value("points", 0)
	LobbySmith.rounds.start()


func _end() -> void:
	LobbySmith.rounds.end({"points": _points()})


func _press_point() -> void:
	if LobbySmith.is_host():
		_add_point(multiplayer.get_unique_id())
	else:
		_request_point.rpc_id(1)


## Clients ask, the host counts. Any peer may call this, so the host checks who asks and how
## often (and, in _add_point, that a round is running).
@rpc("any_peer", "call_remote", "reliable")
func _request_point() -> void:
	if multiplayer.is_server():
		var sender := multiplayer.get_remote_sender_id()
		if _may_ask(sender):
			_add_point(sender)


## Host: true for a player who has not asked too often. A connection that is no player yet
## (it may live up to join_timeout) is refused.
func _may_ask(sender: int) -> bool:
	if not LobbySmith.get_players().has(sender):
		return false
	# shortcut: fixed one-second window per sender, no cap across requests of other kinds; add a
	# global cap per sender (or drop senders that keep hitting the limit) if strangers can join.
	var now := Time.get_ticks_msec()
	var slot: Array = _rate.get(sender, [now, 0])
	if now - int(slot[0]) >= RATE_WINDOW_MS:
		slot = [now, 0]
	slot[1] += 1
	_rate[sender] = slot
	return slot[1] <= RATE_LIMIT


func _add_point(sender: int) -> void:
	if LobbySmith.rounds.is_running() and LobbySmith.get_players().has(sender):
		LobbySmith.state.set_value("points", _points() + 1)


func _points() -> int:
	return LobbySmith.state.get_value("points", 0)


func _refresh() -> void:
	var running: bool = LobbySmith.rounds.is_running()
	var number: int = LobbySmith.rounds.get_number()
	if number == 0:
		%RoundLabel.text = "No round yet."
	elif running:
		%RoundLabel.text = "Round %d is running." % number
	else:
		var result: Variant = LobbySmith.rounds.get_result()
		var final_points: int = result.get("points", 0) if result is Dictionary else 0
		%RoundLabel.text = "Round %d ended. Points: %d" % [number, final_points]
	%PointsLabel.text = "Points: %d" % _points()
	%StartButton.disabled = not LobbySmith.is_host() or running
	%EndButton.disabled = not LobbySmith.is_host() or not running
	%PointButton.disabled = not running
