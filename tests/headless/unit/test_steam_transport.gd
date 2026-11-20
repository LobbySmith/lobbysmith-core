extends SceneTree
# The Steam lobby state machine against a FAKE Steam: a plain GDScript object registered as the
# "Steam" singleton, which records calls and emits the signals GodotSteam would emit. Nothing here
# runs against real Steam. The test stops where the transport would create a SteamMultiplayerPeer:
# a stand-in peer takes that place and only records which lobby it was asked to use.
# The test replaces the "Steam" singleton in its own process (also when GodotSteam is installed)
# and unregisters it again at the end. Not checked with a real GodotSteam.

const TRANSPORT := "res://addons/lobbysmith_core/transport_steam.gd"
const RoomCode := preload("res://addons/lobbysmith_core/room_code.gd")
const CODE := "ABC234"


class FakeSteam extends Object:
	signal lobby_created(result: int, lobby_id: int)
	signal lobby_match_list(lobbies: Array)
	signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
	var calls: Array = []
	var init_status := 0

	func steamInitEx(_app_id: int, _embed: bool) -> Dictionary:
		return {"status": init_status}
	func run_callbacks() -> void:
		pass
	func getPersonaName() -> String:
		return "Fake"
	func createLobby(_type: int, max_members: int) -> void:
		calls.append(["createLobby", max_members])
	func setLobbyData(lobby_id: int, key: String, value: String) -> void:
		calls.append(["setLobbyData", lobby_id, key, value])
	func addRequestLobbyListStringFilter(key: String, value: String, _comparison: int) -> void:
		calls.append(["filter", key, value])
	func addRequestLobbyListDistanceFilter(_distance: int) -> void:
		pass
	func requestLobbyList() -> void:
		calls.append(["requestLobbyList"])
	func joinLobby(lobby_id: int) -> void:
		calls.append(["joinLobby", lobby_id])
	func leaveLobby(lobby_id: int) -> void:
		calls.append(["leaveLobby", lobby_id])
	func count(call_name: String) -> int:
		var n := 0
		for c in calls:
			if c[0] == call_name:
				n += 1
		return n
	func has_call(call: Array) -> bool:
		return calls.has(call)


## Takes the place of SteamMultiplayerPeer, which cannot exist without GodotSteam.
class FakePeer extends MultiplayerPeerExtension:
	var lobby_call := ""
	var lobby_id := 0
	func host_with_lobby(id: int) -> int:
		lobby_call = "host_with_lobby"
		lobby_id = id
		return OK
	func connect_to_lobby(id: int) -> int:
		lobby_call = "connect_to_lobby"
		lobby_id = id
		return OK


class Transport extends "res://addons/lobbysmith_core/transport_steam.gd":
	func _new_peer() -> MultiplayerPeer:
		return FakePeer.new()
	# Without GodotSteam the Steam class has no constants. This returns 0 for every name, so the Steam
	# constant names the transport asks for are NOT checked by this test.
	func _constant(_constant_name: String) -> int:
		return 0


class Run extends RefCounted:
	var steam: FakeSteam = FakeSteam.new()
	var transport: Transport
	var hosted: Array = []
	var joined: Array = []
	var failed: Array = []

	func _init(init_status := 0) -> void:
		steam.init_status = init_status
		if Engine.has_singleton("Steam"):
			Engine.unregister_singleton("Steam")
		Engine.register_singleton("Steam", steam)
		transport = Transport.new()
		# The handlers capture the arrays, not this object: no reference cycle.
		var h := hosted
		var j := joined
		var f := failed
		transport.hosted.connect(func(peer, code): h.append([peer, code]))
		transport.joined.connect(func(peer, code): j.append([peer, code]))
		transport.failed.connect(func(reason): f.append(reason))

	func done() -> void:
		Engine.unregister_singleton("Steam")
		steam.free()


var _failures := 0


func _initialize() -> void:
	_host_ok()
	_host_create_fails()
	_host_cancelled_before_created()
	_steam_not_ready()
	_join_ok()
	_join_invalid_code()
	_join_room_full()
	_join_other_refusal()
	_join_cancelled_while_searching()
	_join_cancelled_before_joined()
	_join_stale_reply_of_old_lobby()
	_join_stale_refusal_of_old_lobby()
	_join_cancelled_then_host()
	_close_after_joined()
	await _join_retry_cancelled()
	await _join_five_empty_searches()
	if _failures == 0:
		print("RESULT: PASS")
	quit(0 if _failures == 0 else 1)


func _host_ok() -> void:
	var r := Run.new()
	r.transport.host(480, 4)
	check(r.steam.has_call(["createLobby", 4]), "host: createLobby with max players")
	r.steam.lobby_created.emit(1, 111)
	check(r.hosted.size() == 1 and r.failed.is_empty(), "host: hosted emitted once")
	if r.hosted.size() == 1:
		check(RoomCode.is_valid(r.hosted[0][1]), "host: valid room code")
		check(r.steam.has_call(["setLobbyData", 111, "lobbysmith_code", r.hosted[0][1]]), "host: code stored as lobby data")
		var peer: FakePeer = r.hosted[0][0]
		check(peer.lobby_call == "host_with_lobby" and peer.lobby_id == 111, "host: peer asked to host the lobby")
	# Real Steam also reports the host's own lobby as joined: that must not make it leave.
	r.steam.lobby_joined.emit(111, 0, false, 1)
	check(r.steam.count("leaveLobby") == 0, "host: the own lobby reported as joined is not left")
	r.transport.close()
	check(r.steam.has_call(["leaveLobby", 111]), "host: close leaves the lobby")
	r.done()


func _host_create_fails() -> void:
	var r := Run.new()
	r.transport.host(480, 4)
	r.steam.lobby_created.emit(2, 0)
	check(r.failed == ["TIMEOUT"] and r.hosted.is_empty(), "host: failed creation reports TIMEOUT")
	r.done()


func _host_cancelled_before_created() -> void:
	var r := Run.new()
	r.transport.host(480, 4)
	r.transport.close()
	r.steam.lobby_created.emit(1, 222)
	check(r.steam.has_call(["leaveLobby", 222]), "host cancelled: a lobby Steam finishes later is left")
	check(r.hosted.is_empty() and r.failed.is_empty(), "host cancelled: nothing is emitted")
	r.done()


func _steam_not_ready() -> void:
	var r := Run.new(1)
	r.transport.host(480, 4)
	check(r.failed == ["STEAM_MISSING"], "client not signed in: STEAM_MISSING")
	r.done()


func _join_ok() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	check(r.steam.has_call(["filter", "lobbysmith_code", CODE]) and r.steam.count("requestLobbyList") == 1, "join: searches by code")
	r.steam.lobby_match_list.emit([333])
	check(r.steam.has_call(["joinLobby", 333]), "join: joins the found lobby")
	r.steam.lobby_joined.emit(333, 0, false, 1)
	check(r.joined.size() == 1 and r.failed.is_empty(), "join: joined emitted once")
	if r.joined.size() == 1:
		check(r.joined[0][1] == CODE, "join: code passed on")
		var peer: FakePeer = r.joined[0][0]
		check(peer.lobby_call == "connect_to_lobby" and peer.lobby_id == 333, "join: peer asked to connect to the lobby")
	r.transport.close()
	check(r.steam.has_call(["leaveLobby", 333]), "join: close leaves the lobby")
	r.done()


func _join_invalid_code() -> void:
	var r := Run.new()
	r.transport.join(480, "nope")
	check(r.failed == ["CODE_UNKNOWN"] and r.steam.count("requestLobbyList") == 0, "join: invalid code fails without a search")
	r.done()


func _join_room_full() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([333])
	r.steam.lobby_joined.emit(333, 0, false, 4)
	check(r.failed == ["ROOM_FULL"] and r.joined.is_empty(), "join: full lobby reports ROOM_FULL")
	r.done()


func _join_other_refusal() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([333])
	r.steam.lobby_joined.emit(333, 0, false, 2)
	check(r.failed == ["CODE_UNKNOWN"] and r.joined.is_empty(), "join: other refusal reports CODE_UNKNOWN")
	r.done()


func _join_cancelled_while_searching() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.transport.close()
	r.steam.lobby_match_list.emit([333])
	check(r.steam.count("joinLobby") == 0 and r.failed.is_empty() and r.joined.is_empty(), "join cancelled in search: no join, nothing emitted")
	r.done()


# Audit finding A1: the player cancels after joinLobby, Steam then reports the lobby joined.
func _join_cancelled_before_joined() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([444])
	r.transport.close()
	r.steam.lobby_joined.emit(444, 0, false, 1)
	check(r.steam.has_call(["leaveLobby", 444]), "join cancelled before joined: the late lobby is left (ghost member)")
	check(r.joined.is_empty() and r.failed.is_empty(), "join cancelled before joined: nothing emitted")
	r.done()
	# A refused late join needs no leave.
	var s := Run.new()
	s.transport.join(480, CODE)
	s.steam.lobby_match_list.emit([555])
	s.transport.close()
	s.steam.lobby_joined.emit(555, 0, false, 4)
	check(s.steam.count("leaveLobby") == 0 and s.failed.is_empty(), "join cancelled, then refused: no leave, nothing emitted")
	s.done()


# Cancel a pending join(111), start a new one that reaches join(222): the reply for 111 is stale.
func _join_stale_reply_of_old_lobby() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([111])
	r.transport.close()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([222])
	r.steam.lobby_joined.emit(111, 0, false, 1)
	check(r.steam.has_call(["leaveLobby", 111]), "stale reply: the old lobby is left")
	check(r.joined.is_empty() and r.failed.is_empty(), "stale reply: the new attempt is still pending")
	r.steam.lobby_joined.emit(222, 0, false, 1)
	check(r.joined.size() == 1 and r.failed.is_empty(), "stale reply: the new lobby joins once")
	if r.joined.size() == 1:
		var peer: FakePeer = r.joined[0][0]
		check(peer.lobby_id == 222, "stale reply: peer connects to the new lobby")
	check(r.steam.count("leaveLobby") == 1, "stale reply: only the old lobby was left")
	r.done()


func _join_stale_refusal_of_old_lobby() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([111])
	r.transport.close()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([222])
	r.steam.lobby_joined.emit(111, 0, false, 4)
	check(r.failed.is_empty() and r.joined.is_empty() and r.steam.count("leaveLobby") == 0, "stale refusal: ignored, nothing left")
	r.steam.lobby_joined.emit(222, 0, false, 1)
	check(r.joined.size() == 1, "stale refusal: the new attempt still joins")
	r.done()


# Cancel a pending join(444), then host: Steam's late success for 444 arrives before lobby_created.
func _join_cancelled_then_host() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([444])
	r.transport.close()
	r.transport.host(480, 4)
	r.steam.lobby_joined.emit(444, 0, false, 1)   # before lobby_created: no lobby of our own yet
	check(r.steam.has_call(["leaveLobby", 444]), "join cancelled, then host: the late lobby is left (ghost member)")
	r.steam.lobby_created.emit(1, 555)
	check(r.hosted.size() == 1 and r.failed.is_empty(), "join cancelled, then host: hosting still works")
	check(r.steam.count("leaveLobby") == 1, "join cancelled, then host: only the old lobby was left")
	# A reply for a lobby that was never ours to leave is not touched before the own lobby exists.
	r.steam.lobby_joined.emit(555, 0, false, 1)
	check(r.steam.count("leaveLobby") == 1, "join cancelled, then host: the own lobby is not left")
	r.done()


func _close_after_joined() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([333])
	r.steam.lobby_joined.emit(333, 0, false, 1)
	r.transport.close()
	r.steam.lobby_joined.emit(333, 0, false, 1)   # a repeated report must not double up
	check(r.joined.size() == 1, "joined once only")
	r.done()


func _join_retry_cancelled() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	r.steam.lobby_match_list.emit([])   # arms the retry timer
	r.transport.close()
	await create_timer(2.5).timeout
	check(r.steam.count("requestLobbyList") == 1 and r.failed.is_empty(), "join cancelled: the pending retry does nothing")
	r.done()


func _join_five_empty_searches() -> void:
	var r := Run.new()
	r.transport.join(480, CODE)
	for i in 5:
		check(r.steam.count("requestLobbyList") == i + 1 and r.failed.is_empty(), "search %d runs and nothing has failed yet" % (i + 1))
		r.steam.lobby_match_list.emit([])
		if i < 4:
			var waited := 0.0
			while r.steam.count("requestLobbyList") == i + 1 and waited < 4.0:
				await create_timer(0.1).timeout
				waited += 0.1
	check(r.failed == ["CODE_UNKNOWN"] and r.steam.count("requestLobbyList") == 5, "five empty searches give CODE_UNKNOWN")
	r.done()


func check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("RESULT: FAIL ", what)
