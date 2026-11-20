extends RefCounted
# A coordinated scene change: everyone reports the new scene, the host keeps a
# ready flag per player, and scene_entered comes once all are ready. Three
# changes in a row: Room, RoomB, Room again.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const ROOM_B := "res://tests/headless/fixtures/room_b.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var entered := [0]
	lobbysmith.scene_entered.connect(func(): entered[0] += 1)
	if peer.role == "host":
		await run_host(peer, lobbysmith, entered)
	else:
		await run_client(peer, lobbysmith, entered)


func run_host(peer: Node, lobbysmith: Node, entered: Array) -> void:
	var changed_ids := []
	lobbysmith.ready_changed.connect(func(id): changed_ids.append(id))
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	if lobbysmith.is_changing_scene():
		peer.fail_and_quit("changing before any change")
		return
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("first change_scene failed")
		return
	if not lobbysmith.is_changing_scene():
		peer.fail_and_quit("not changing right after change_scene with clients")
		return
	if lobbysmith.change_scene(ROOM_B) != ERR_BUSY:
		peer.fail_and_quit("second change_scene during a change should be ERR_BUSY")
		return
	if lobbysmith.get_scene().name != "Room":
		peer.fail_and_quit("running change was touched, scene is %s" % lobbysmith.get_scene().name)
		return
	var players: Dictionary = lobbysmith.get_players()
	for id in players:
		if players[id]["ready"] != (id == 1):
			peer.fail_and_quit("player %d ready=%s right after the call" % [id, players[id]["ready"]])
			return
	if not await peer.wait_until(func(): return entered[0] >= 1, 10.0):
		peer.fail_and_quit("no scene_entered after the first change")
		return
	var problem := check_ready(lobbysmith)
	if problem == "":
		for id in lobbysmith.get_players():
			if id != 1 and changed_ids.count(id) < 2:
				problem = "player %d ready_changed only %d times" % [id, changed_ids.count(id)]
	if problem != "":
		peer.fail_and_quit(problem)
		return
	lobbysmith.get_scene().value = 11
	lobbysmith.state.set_value("round", 1)
	if not await mark(peer, "in_a"):
		return
	if lobbysmith.change_scene(ROOM_B) != OK:
		peer.fail_and_quit("change_scene to room B failed")
		return
	if not await peer.wait_until(func(): return entered[0] >= 2, 10.0):
		peer.fail_and_quit("no second scene_entered")
		return
	lobbysmith.get_scene().value = 22
	if not await mark(peer, "in_b"):
		return
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene back to room failed")
		return
	if not await peer.wait_until(func(): return entered[0] >= 3, 10.0):
		peer.fail_and_quit("no third scene_entered")
		return
	if lobbysmith.get_scene().value != 0:
		peer.fail_and_quit("scene back in room is not fresh: value %d" % lobbysmith.get_scene().value)
		return
	if not await mark(peer, "back"):
		return
	if entered[0] != 3:
		peer.fail_and_quit("scene_entered came %d times, expected 3" % entered[0])
		return
	lobbysmith.leave()
	peer.pass_and_quit()


func mark(peer: Node, tag: String) -> bool:
	peer.broadcast(tag)
	var problem: String = await peer.collect_reports(tag, peer.total - 1, 10.0)
	if problem != "":
		peer.fail_and_quit("%s: %s" % [tag, problem])
		return false
	return true


func check_ready(lobbysmith: Node) -> String:
	if lobbysmith.is_changing_scene():
		return "still changing"
	var players: Dictionary = lobbysmith.get_players()
	for id in players:
		if not players[id]["ready"]:
			return "player %d not ready" % id
	return ""


func run_client(peer: Node, lobbysmith: Node, entered: Array) -> void:
	var ended := [-1]
	lobbysmith.session_ended.connect(func(reason): ended[0] = reason)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	var steps := [["in_a", 1, 11, "Room"], ["in_b", 2, 22, "RoomB"], ["back", 3, 0, "Room"]]
	for step in steps:
		var tag: String = step[0]
		if not await peer.wait_checkpoint(tag, 30.0):
			peer.fail_and_quit("no %s checkpoint" % tag)
			return
		var count: int = step[1]
		var value: int = step[2]
		var scene_name: String = step[3]
		var there := func():
			var scene: Node = lobbysmith.get_scene()
			return entered[0] >= count and scene != null and scene.name == scene_name and scene.value == value
		var problem := ""
		if not await peer.wait_until(there, 5.0):
			var scene: Node = lobbysmith.get_scene()
			problem = "%s: entered %d, scene %s" % [tag, entered[0], scene.name if scene else "null"]
		elif lobbysmith.get_node("Stage").get_child_count() != 1:
			problem = "%s: stage has %d children" % [tag, lobbysmith.get_node("Stage").get_child_count()]
		elif check_ready(lobbysmith) != "":
			problem = "%s: %s" % [tag, check_ready(lobbysmith)]
		elif lobbysmith.state.get_value("round") != 1:
			problem = "%s: round is %s" % [tag, lobbysmith.state.get_value("round")]
		elif lobbysmith.change_scene(ROOM) != ERR_UNAUTHORIZED:
			problem = "%s: client change_scene should be ERR_UNAUTHORIZED" % tag
		peer.report(tag, problem == "", problem)
		if problem != "":
			await peer.get_tree().create_timer(0.5).timeout
			peer.fail_and_quit(problem)
			return
	if not await peer.wait_until(func(): return ended[0] == lobbysmith.EndReason.HOST_LEFT, 10.0):
		peer.fail_and_quit("no HOST_LEFT, got %d" % ended[0])
		return
	peer.pass_and_quit()
