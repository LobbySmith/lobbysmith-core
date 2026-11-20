extends RefCounted
# Host and 2 clients. Client 1 misbehaves: it registers a second time (twice), reports scenes
# with a wrong serial (999, a negative one, 0), reports the right serial again, and joined with
# a name full of control, zero-width and bidirectional characters and 10,000 characters long.
# The host's session, player list, state and scene stay as they were, client 2 is not
# affected, and client 1 is simply ignored (still a player, with the cleaned name).
# A second part checks the serial: client 1 holds back its report during a scene change, sends
# the wrong serials (999, -1, 0 and the number of the old scene), and the host must still wait
# for it; the right serial then ends the change.
# Not tested: calls of host-authority RPCs (state._apply, _receive_roster, _player_added,
# _player_removed, _ready_set, _entered, _rejected) by a client. The engine itself refuses
# them and logs an ERROR on the receiver, which the runner counts as a failure. Core relies on
# that engine check; it is not covered here.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const ROOM_B := "res://tests/headless/fixtures/room_b.tscn"
const DIRTY := "\u200b\u202eMal\u0007lory\u2066\u200f\ufeff\t"
const CLEAN := "Malloryxxxxxxxxxxxxxxxxx"   # 24 characters


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		await run_host(peer, lobbysmith)
	else:
		await run_client(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	var events := []
	lobbysmith.ready_changed.connect(func(id): events.append("ready_changed:%d" % id))
	lobbysmith.player_left.connect(func(id): events.append("player_left:%d" % id))
	lobbysmith.scene_entered.connect(func(): events.append("scene_entered"))
	lobbysmith.local_name = "Host"
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 3, 20.0):
		peer.fail_and_quit("roster never reached 3")
		return
	lobbysmith.state.set_value("a", 1)
	if lobbysmith.change_scene(ROOM) != OK or not await peer.wait_until(func(): return events.has("scene_entered"), 20.0):
		peer.fail_and_quit("room never entered")
		return
	if not await peer.wait_until(func(): return _all_ready(lobbysmith), 10.0):
		peer.fail_and_quit("not everybody ready in the room")
		return
	var before := _snapshot(lobbysmith)
	events.clear()
	peer.broadcast("abuse")
	var problem: String = await peer.collect_reports("abused", 1, 20.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	await peer.get_tree().create_timer(1.0).timeout   # let the host process every call
	var after := _snapshot(lobbysmith)
	if after != before:
		peer.fail_and_quit("host changed: before %s, after %s" % [before, after])
		return
	if not events.is_empty() or lobbysmith.is_changing_scene() or not lobbysmith.is_active():
		peer.fail_and_quit("host reacted: %s" % [events])
		return
	var names := []
	for info in lobbysmith.get_players().values():
		names.append(info["name"])
	names.sort()
	if names != ["Host", CLEAN, "Two"]:
		peer.fail_and_quit("names %s" % [names])
		return
	peer.broadcast("check")
	problem = await peer.collect_reports("check", 2, 20.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	problem = await _host_wrong_serial(peer, lobbysmith, events)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.broadcast("done")
	await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 10.0)
	peer.pass_and_quit()


# Part 2: client 1 does not report the new scene, then reports it with wrong serials.
func _host_wrong_serial(peer: Node, lobbysmith: Node, events: Array) -> String:
	var abuser := 0
	for id in lobbysmith.get_players():
		if lobbysmith.get_players()[id]["name"] == CLEAN:
			abuser = id
	peer.broadcast("hold")
	var problem: String = await peer.collect_reports("held", 1, 20.0)
	if problem != "":
		return problem
	events.clear()
	if lobbysmith.change_scene(ROOM_B) != OK:
		return "change_scene to room_b failed"
	var others_ready := func() -> bool:
		for id in lobbysmith.get_players():
			if id != 1 and id != abuser and not lobbysmith.get_players()[id]["ready"]:
				return false
		return true
	if not await peer.wait_until(others_ready, 20.0):
		return "client 2 never became ready in room_b"
	peer.broadcast("wrong")
	problem = await peer.collect_reports("wrong_sent", 1, 20.0)
	if problem != "":
		return problem
	await peer.get_tree().create_timer(1.0).timeout
	if lobbysmith.get_players()[abuser]["ready"] or not lobbysmith.is_changing_scene() or events.has("scene_entered"):
		return "a wrong serial was accepted: ready %s, changing %s, events %s" % [
				lobbysmith.get_players()[abuser]["ready"], lobbysmith.is_changing_scene(), events]
	peer.broadcast("right")
	if not await peer.wait_until(func(): return events.has("scene_entered") and lobbysmith.get_players()[abuser]["ready"], 10.0):
		return "the right serial did not end the change: events %s" % [events]
	return ""


func run_client(peer: Node, lobbysmith: Node) -> void:
	var events := []
	lobbysmith.ready_changed.connect(func(id): events.append("ready_changed:%d" % id))
	lobbysmith.player_left.connect(func(id): events.append("player_left:%d" % id))
	lobbysmith.scene_entered.connect(func(): events.append("scene_entered"))
	lobbysmith.local_name = (DIRTY + "x".repeat(10000)) if peer.index == 1 else "Two"
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_checkpoint("abuse", 40.0):
		peer.fail_and_quit("no abuse checkpoint")
		return
	events.clear()   # only what happens from here on counts
	if peer.index == 1:
		await _abuse(peer, lobbysmith)
	if not await peer.wait_checkpoint("check", 20.0):
		peer.fail_and_quit("no check checkpoint")
		return
	var problem := ""
	var serial: int = lobbysmith.get_scene().get_meta("lobbysmith_serial", 0) if lobbysmith.get_scene() != null else -1
	if lobbysmith.get_players().size() != 3 or not _all_ready(lobbysmith):
		problem = "players %s" % [lobbysmith.get_players()]
	elif lobbysmith.state.get_all() != {"a": 1}:
		problem = "state %s" % [lobbysmith.state.get_all()]
	elif serial != 1:
		problem = "scene serial %d" % serial
	elif not lobbysmith.is_active() or lobbysmith.get_scene().name != "Room":
		problem = "session or scene changed"
	elif events.has("player_left:1") or events.any(func(e): return e.begins_with("ready_changed") or e == "scene_entered"):
		problem = "unexpected events %s" % [events]
	peer.report("check", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	if peer.index == 1:
		if not await _client_wrong_serial(peer, lobbysmith):
			return
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint")
		return
	peer.pass_and_quit()


# Part 2, client 1: stops reporting scenes by itself, reports by hand when told.
func _client_wrong_serial(peer: Node, lobbysmith: Node) -> bool:
	if not await peer.wait_checkpoint("hold", 20.0):
		peer.fail_and_quit("no hold checkpoint")
		return false
	lobbysmith._stage.scene_arrived.disconnect(lobbysmith._on_stage_scene_arrived)
	peer.report("held", true)
	if not await peer.wait_checkpoint("wrong", 30.0):
		peer.fail_and_quit("no wrong checkpoint")
		return false
	var old_serial: int = lobbysmith.get_scene().get_meta("lobbysmith_serial", 0) - 1
	for serial in [999, -1, 0, old_serial]:
		lobbysmith._scene_ready.rpc_id(1, serial)
	await peer.get_tree().create_timer(0.5).timeout
	peer.report("wrong_sent", true)
	if not await peer.wait_checkpoint("right", 20.0):
		peer.fail_and_quit("no right checkpoint")
		return false
	lobbysmith._scene_ready.rpc_id(1, lobbysmith.get_scene().get_meta("lobbysmith_serial", 0))
	return true


# Everything a client can do to the host without the engine refusing the call.
func _abuse(peer: Node, lobbysmith: Node) -> void:
	lobbysmith._register.rpc_id(1, "Evil")
	lobbysmith._register.rpc_id(1, DIRTY)
	for serial in [999, -1, 0]:
		lobbysmith._scene_ready.rpc_id(1, serial)
	lobbysmith._scene_ready.rpc_id(1, 1)   # the right number, but this client is ready already
	await peer.get_tree().create_timer(0.5).timeout
	peer.report("abused", true)


func _all_ready(lobbysmith: Node) -> bool:
	for info in lobbysmith.get_players().values():
		if not info["ready"]:
			return false
	return true


func _snapshot(lobbysmith: Node) -> Dictionary:
	return {
		"players": lobbysmith.get_players(),
		"state": lobbysmith.state.get_all(),
		"scene": lobbysmith.get_scene().name if lobbysmith.get_scene() != null else "",
		"serial": lobbysmith.get_scene().get_meta("lobbysmith_serial", 0) if lobbysmith.get_scene() != null else 0,
		"changing": lobbysmith.is_changing_scene(),
		"peers": lobbysmith.multiplayer.get_peers().size(),
	}
