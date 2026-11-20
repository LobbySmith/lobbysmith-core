extends RefCounted
## Steam lobby with a room code, on top of GodotSteam.
##
## GodotSteam is looked up at runtime only, so this script (and LobbySmith Core)
## loads in projects that do not have it. Never name its classes as types here.

const RoomCode := preload("room_code.gd")
const CODE_KEY := "lobbysmith_code"
const SEARCH_ATTEMPTS := 5
const SEARCH_INTERVAL := 2.0
const ENTER_SUCCESS := 1    # Steam chat room enter responses
const ENTER_FULL := 4

signal hosted(peer: MultiplayerPeer, code: String)
signal joined(peer: MultiplayerPeer, code: String)
## reason is the name of a LobbySmith.JoinError value.
signal failed(reason: String)

var _steam: Object
var _mode := ""             # "", "host" or "join"
var _lobby_id := 0
var _joining_id := 0        # the lobby passed to joinLobby, until Steam answers
var _cancelled_id := 0      # a join cancelled before Steam answered; kept across close() and host()
var _code := ""
var _searches := 0
var _operation := 0         # tells a stale retry timer from the current attempt


func host(app_id: int, max_players: int) -> void:
	if not _setup(app_id):
		failed.emit("STEAM_MISSING")
		return
	_start("host")
	_steam.createLobby(_constant("LOBBY_TYPE_PUBLIC"), max_players)


func join(app_id: int, code: String) -> void:
	if not _setup(app_id):
		failed.emit("STEAM_MISSING")
		return
	if not RoomCode.is_valid(code):
		failed.emit("CODE_UNKNOWN")
		return
	_start("join")
	_code = code
	_search(_operation)


## Steam only delivers its answers while this is called every frame.
func poll() -> void:
	if _steam != null:
		_steam.run_callbacks()


## Leaves the lobby and drops whatever attempt is running.
func close() -> void:
	if _steam != null and _lobby_id != 0:
		_steam.leaveLobby(_lobby_id)
	_start("")


func get_persona_name() -> String:
	return _steam.getPersonaName() if _steam != null else ""


func _setup(app_id: int) -> bool:
	if _steam != null:
		return true
	if not Engine.has_singleton("Steam"):
		return false
	var steam := Engine.get_singleton("Steam")
	var result: Dictionary = steam.steamInitEx(app_id, false)
	if result.get("status", -1) != 0:
		return false   # Steam client not running or not signed in
	_steam = steam
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_match_list", _on_lobby_match_list)
	_steam.connect("lobby_joined", _on_lobby_joined)
	return true


func _start(mode: String) -> void:
	_mode = mode
	_operation += 1
	_lobby_id = 0
	if _joining_id != 0:
		_cancelled_id = _joining_id   # Steam may still report this join as done
	_joining_id = 0
	_code = ""
	_searches = 0


func _constant(constant_name: String) -> int:
	return ClassDB.class_get_integer_constant("Steam", constant_name)


func _new_peer() -> MultiplayerPeer:
	return ClassDB.instantiate("SteamMultiplayerPeer")


func _on_lobby_created(result: int, lobby_id: int) -> void:
	if _mode != "host":
		# The attempt was cancelled while Steam was creating the lobby: do not leave it orphaned.
		if result == 1:
			_steam.leaveLobby(lobby_id)
		return
	if _lobby_id != 0:
		return
	if result != 1:
		_start("")
		failed.emit("TIMEOUT")
		return
	_lobby_id = lobby_id
	_code = RoomCode.generate()
	_steam.setLobbyData(lobby_id, CODE_KEY, _code)
	var peer := _new_peer()
	if peer.call("host_with_lobby", lobby_id) != OK:
		close()
		failed.emit("TIMEOUT")
		return
	hosted.emit(peer, _code)


func _search(operation: int) -> void:
	if operation != _operation:
		return
	_searches += 1
	_steam.addRequestLobbyListStringFilter(CODE_KEY, _code, _constant("LOBBY_COMPARISON_EQUAL"))
	_steam.addRequestLobbyListDistanceFilter(_constant("LOBBY_DISTANCE_FILTER_WORLDWIDE"))
	_steam.requestLobbyList()


func _on_lobby_match_list(lobbies: Array) -> void:
	if _mode != "join" or _lobby_id != 0:
		return
	if not lobbies.is_empty():
		_joining_id = lobbies[0]
		_steam.joinLobby(_joining_id)
		return
	if _searches >= SEARCH_ATTEMPTS:
		_start("")
		failed.emit("CODE_UNKNOWN")
		return
	# A lobby that was just created can take a moment to show up in searches.
	var tree := Engine.get_main_loop() as SceneTree
	tree.create_timer(SEARCH_INTERVAL).timeout.connect(_search.bind(_operation))


## Open edge: lobby_match_list and lobby_created carry no id to match, so a reply to a cancelled
## search or lobby creation that arrives after a new attempt started is taken as the new attempt's.
func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if _mode == "host":
		# Steam also reports the host's own lobby as joined. Any other lobby is a leftover join:
		# once ours exists, or earlier when it is the join that was cancelled (its reply can come
		# before lobby_created).
		if response == ENTER_SUCCESS and lobby_id != _lobby_id \
				and (_lobby_id != 0 or lobby_id == _cancelled_id):
			_steam.leaveLobby(lobby_id)
			if lobby_id == _cancelled_id:
				_cancelled_id = 0
		return
	if lobby_id != _joining_id:
		# A reply for a join that was cancelled: do not stay a member (it takes a seat), and do
		# not touch the current attempt.
		if response == ENTER_SUCCESS:
			_steam.leaveLobby(lobby_id)
		return
	if _mode != "join" or _lobby_id != 0:
		return
	if lobby_id == _cancelled_id:
		_cancelled_id = 0   # joined on purpose after all: it is no longer a leftover
	if response != ENTER_SUCCESS:
		_start("")
		failed.emit("ROOM_FULL" if response == ENTER_FULL else "CODE_UNKNOWN")
		return
	_lobby_id = lobby_id
	var code := _code
	var peer := _new_peer()
	if peer.call("connect_to_lobby", lobby_id) != OK:
		close()
		failed.emit("TIMEOUT")
		return
	joined.emit(peer, code)
