extends RefCounted
# Only the host changes LobbySmith.state; everyone sees the same values and gets
# a changed signal for each change. Leaving empties the state.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const EXPECTED := {"count": 4, "phase": "day", "scores": {"red": [1, 2.5, true]}}


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var state: Node = lobbysmith.state
	var keys := []
	state.changed.connect(func(key: String): keys.append(key))
	if peer.role == "host":
		if state.set_value("a", 1) != ERR_UNAUTHORIZED:
			peer.fail_and_quit("set_value before hosting should be ERR_UNAUTHORIZED")
			return
		if lobbysmith.host_lan(peer.port) != OK:
			peer.fail_and_quit("host_lan failed")
			return
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
			peer.fail_and_quit("roster never reached %d" % peer.total)
			return
		var node := Node.new()
		var results := [
			state.set_value("count", 3), state.set_value("phase", "day"),
			state.set_value("scores", {"red": [1, 2.5, true]}), state.set_value("count", 4),
			state.set_value("bad", node), state.set_value("bad", [Vector3.ZERO]),
			state.set_value("bad", {1: "x"}),
		]
		node.free()
		if results != [OK, OK, OK, OK, ERR_INVALID_PARAMETER, ERR_INVALID_PARAMETER, ERR_INVALID_PARAMETER]:
			peer.fail_and_quit("unexpected set_value results %s" % [results])
			return
		if state.has("bad") or state.get_value("missing", 9) != 9:
			peer.fail_and_quit("has/get_value default wrong")
			return
		if keys != ["count", "phase", "scores", "count"]:
			peer.fail_and_quit("host changed signals were %s" % [keys])
			return
		if lobbysmith.change_scene(ROOM) != OK:
			peer.fail_and_quit("change_scene failed")
			return
		if state.get_all().size() != 3:
			peer.fail_and_quit("scene change altered the state")
			return
		peer.broadcast("set")
		var problem: String = await peer.collect_reports("set", peer.total - 1, 10.0)
		if problem != "":
			peer.fail_and_quit(problem)
			return
		lobbysmith.leave()
		peer.pass_and_quit()
	else:
		if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("join_lan failed")
			return
		if not await peer.wait_checkpoint("set", 30.0):
			peer.fail_and_quit("no set checkpoint")
			return
		var problem := ""
		if not await peer.wait_until(func(): return state.get_value("count") == 4, 5.0):
			problem = "client never saw count == 4"
		elif state.get_all() != EXPECTED:
			problem = "client state was %s" % [state.get_all()]
		elif keys.size() != 4:
			problem = "client changed signals: %d" % keys.size()
		elif state.set_value("x", 1) != ERR_UNAUTHORIZED or state.has("x"):
			problem = "client set_value should be ERR_UNAUTHORIZED"
		else:
			var copy: Dictionary = state.get_all()
			copy["scores"]["red"].append(9)
			if state.get_value("scores") != EXPECTED["scores"]:
				problem = "get_all is not a deep copy"
		peer.report("set", problem == "", problem)
		await peer.get_tree().create_timer(0.5).timeout
		if problem != "":
			peer.fail_and_quit(problem)
			return
		lobbysmith.leave()
		if not state.get_all().is_empty():
			peer.fail_and_quit("state not empty after leave")
			return
		peer.pass_and_quit()
