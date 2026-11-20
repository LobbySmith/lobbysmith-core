extends RefCounted
# Players who join while a scene is running: the others hear player_joined only
# once the newcomer has the scene, and the newcomer's session_started fires only
# once it has roster, state and scene. The extra player never reports "scene
# stands", so the host must not announce it.
# Also used by late_join_8 (same flow, the extra is the ninth player).

const ROOM := "res://tests/headless/fixtures/room.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	match peer.role:
		"host":
			await run_host(peer, lobbysmith)
		"client":
			await run_client(peer, lobbysmith)
		"extra":
			await run_extra(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	var joined := [0]
	var left := [0]
	lobbysmith.player_joined.connect(func(_id): joined[0] += 1)
	lobbysmith.player_left.connect(func(_id): left[0] += 1)
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() >= 2, 20.0):
		peer.fail_and_quit("first client never joined")
		return
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	lobbysmith.get_scene().value = 7
	lobbysmith.state.set_value("count", 5)
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 30.0):
		peer.fail_and_quit("roster never reached %d, has %d" % [peer.total, lobbysmith.get_players().size()])
		return
	lobbysmith.get_scene().value = 8
	peer.broadcast("all")
	var problem: String = await peer.collect_reports("sum", peer.total - 1, 15.0)
	if problem == "":
		var mine := checksum(lobbysmith)
		for entry in peer._reports["sum"]:
			if entry[1] != mine:
				problem = "a client's checksum differs from the host's"
	var before := ids(lobbysmith)
	# The extra player comes about 4 s after the clients.
	await peer.get_tree().create_timer(8.0).timeout
	if problem == "":
		if joined[0] != peer.total - 1:
			problem = "player_joined came %d times, expected %d" % [joined[0], peer.total - 1]
		elif left[0] != 0:
			problem = "player_left came %d times" % left[0]
		elif ids(lobbysmith) != before or before.size() != peer.total:
			problem = "player list changed or wrong size: %s" % [ids(lobbysmith)]
	peer.broadcast("done")
	await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 10.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node) -> void:
	var problem := [""]
	var started := [false]
	# [scene_entered count at session_started]
	var entered := [0, -1]
	lobbysmith.scene_entered.connect(func(): entered[0] += 1)
	lobbysmith.player_joined.connect(func(id):
		if not lobbysmith.get_players().has(id) and problem[0] == "":
			problem[0] = "player_joined(%d) but the id is not in get_players()" % id)
	lobbysmith.session_started.connect(func():
		started[0] = true
		entered[1] = entered[0]
		if peer.index > 1 and problem[0] == "":
			problem[0] = late_problem(peer, lobbysmith))
	var project_scene: Node = null
	if peer.index > 1:
		await peer.get_tree().process_frame
		project_scene = make_project_scene(peer)
		await peer.get_tree().create_timer(3.0).timeout
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return started[0], 15.0):
		peer.fail_and_quit("no session_started")
		return
	if peer.index > 1:
		# A late joiner gets its own scene_entered, and only after session_started.
		await peer.get_tree().create_timer(0.5).timeout
		if entered[1] != 0:
			peer.fail_and_quit("scene_entered came before session_started")
			return
		if entered[0] != 1:
			peer.fail_and_quit("late client got scene_entered %d times, expected 1" % entered[0])
			return
	if project_scene != null:
		await peer.get_tree().process_frame
		if is_instance_valid(project_scene):
			project_scene.free()
			peer.fail_and_quit("late client still has its own scene after session_started")
			return
		if peer.get_tree().current_scene == project_scene:
			peer.fail_and_quit("current_scene is still the project scene")
			return
	if not await peer.wait_checkpoint("all", 30.0):
		peer.fail_and_quit("no all checkpoint")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_scene() != null and lobbysmith.get_scene().value == 8, 5.0):
		problem[0] = "client never saw value 8"
	peer.report("sum", problem[0] == "", checksum(lobbysmith) if problem[0] == "" else problem[0])
	await peer.get_tree().create_timer(0.5).timeout
	if problem[0] != "":
		peer.fail_and_quit(problem[0])
		return
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint")
		return
	peer.pass_and_quit()


## Never reports "scene stands": it must stay unannounced and unnoticed.
func run_extra(peer: Node, lobbysmith: Node) -> void:
	var result := [""]
	lobbysmith.join_failed.connect(func(error): result[0] = "join_failed:%d" % error)
	lobbysmith.session_started.connect(func(): result[0] = "session_started")
	lobbysmith.set_process(false)
	await peer.get_tree().process_frame
	var project_scene := make_project_scene(peer)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	await peer.get_tree().create_timer(2.0).timeout
	var problem := ""
	if lobbysmith.get_scene() == null:
		problem = "extra never received the scene"
	elif lobbysmith.is_active():
		problem = "extra is active without having reported the scene"
	lobbysmith.leave()
	await peer.get_tree().create_timer(1.0).timeout
	if problem == "" and result[0] != "":
		problem = "extra got %s" % result[0]
	elif problem == "" and (lobbysmith.is_active() or lobbysmith.get_scene() != null):
		problem = "extra still active or showing a scene after leave()"
	if problem == "" and not is_instance_valid(project_scene):
		problem = "extra lost its own scene although never admitted"
	elif problem == "" and peer.get_tree().current_scene != project_scene:
		problem = "extra's current_scene changed although never admitted"
	if is_instance_valid(project_scene):
		project_scene.free()
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


## Checked inside the session_started handler, without waiting a frame.
func late_problem(peer: Node, lobbysmith: Node) -> String:
	var scene: Node = lobbysmith.get_scene()
	if scene == null:
		return "get_scene() is null in session_started"
	if scene.name != "Room":
		return "scene is named %s" % scene.name
	if scene.value != 7 and scene.value != 8:
		return "scene value is %d in session_started" % scene.value
	if lobbysmith.state.get_value("count") != 5:
		return "state count is %s in session_started" % lobbysmith.state.get_value("count")
	if not lobbysmith.get_players().has(peer.multiplayer.get_unique_id()):
		return "own id missing from roster in session_started"
	if not lobbysmith.is_active():
		return "not active in session_started"
	return ""


## A plain node standing in for the project's own scene (menu). Call after one
## frame: peer.gd clears current_scene deferred.
func make_project_scene(peer: Node) -> Node:
	var scene := Node.new()
	scene.name = "ProjectScene"
	peer.get_tree().root.add_child(scene)
	peer.get_tree().current_scene = scene
	return scene


func ids(lobbysmith: Node) -> Array:
	var list: Array = lobbysmith.get_players().keys()
	list.sort()
	return list


func checksum(lobbysmith: Node) -> String:
	return str(hash("%d|%s|%s" % [lobbysmith.get_scene().value, lobbysmith.state.get_all(), ids(lobbysmith)]))
