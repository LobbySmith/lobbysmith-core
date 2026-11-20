extends RefCounted
# A joiner is held during a scene change. When that change ends, the host's
# scene_entered handler starts another change at once (Room -> RoomB -> Room).
# The held joiner must not be admitted for the old scene: the host hears
# scene_entered (RoomB), scene_entered (chained Room), and only then
# player_joined. The joiner's scene_entered comes once, for Room.
# Timing as in scene_change_join (extra about 4.5 s after the host, client frozen
# from about 3.0 s for 4 s).

const ROOM := "res://tests/headless/fixtures/room.tscn"
const ROOM_B := "res://tests/headless/fixtures/room_b.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var events := []
	lobbysmith.scene_entered.connect(func(): events.append("scene_entered"))
	lobbysmith.player_joined.connect(func(_id): events.append("player_joined"))
	match peer.role:
		"host":
			await run_host(peer, lobbysmith, events)
		"client":
			await run_client(peer, lobbysmith, events)
		"extra":
			await run_extra(peer, lobbysmith, events)


func run_host(peer: Node, lobbysmith: Node, events: Array) -> void:
	var begin := Time.get_ticks_msec()
	# [armed, chained, error]
	var chain := [false, false, ""]
	lobbysmith.scene_entered.connect(func():
		if chain[0] and not chain[1]:
			chain[1] = true
			if lobbysmith.change_scene(ROOM) != OK:
				chain[2] = "chained change_scene failed")
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2, 20.0):
		peer.fail_and_quit("client never joined")
		return
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	if not await peer.wait_until(func(): return events.count("scene_entered") >= 1, 10.0):
		peer.fail_and_quit("no first scene_entered")
		return
	var wait_msec := 3000 - (Time.get_ticks_msec() - begin)
	if wait_msec > 0:
		await peer.get_tree().create_timer(wait_msec / 1000.0).timeout
	peer.broadcast("freeze")
	await peer.get_tree().create_timer(0.3).timeout
	events.clear()
	chain[0] = true
	if lobbysmith.change_scene(ROOM_B) != OK:
		peer.fail_and_quit("change_scene to room B failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 3, 20.0):
		peer.fail_and_quit("extra never joined, events %s" % [events])
		return
	if not await peer.wait_until(func(): return events.count("scene_entered") >= 2 and not lobbysmith.is_changing_scene(), 20.0):
		peer.fail_and_quit("chained change never ended, events %s" % [events])
		return
	if chain[2] != "":
		peer.fail_and_quit(chain[2])
		return
	if events != ["scene_entered", "scene_entered", "player_joined"]:
		peer.fail_and_quit("events were %s" % [events])
		return
	var all_ready := func():
		for p in lobbysmith.get_players().values():
			if not p["ready"]:
				return false
		return true
	if not await peer.wait_until(all_ready, 5.0):
		peer.fail_and_quit("not all players ready at the end")
		return
	if lobbysmith.is_changing_scene() or lobbysmith.get_scene().name != "Room":
		peer.fail_and_quit("still changing or scene is not Room")
		return
	peer.broadcast("done")
	var problem: String = await peer.collect_reports("done", 2, 10.0)
	if problem != "":
		peer.fail_and_quit("done: " + problem)
		return
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node, events: Array) -> void:
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_checkpoint("freeze", 30.0):
		peer.fail_and_quit("no freeze checkpoint")
		return
	OS.delay_msec(4000)
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint")
		return
	var problem := ""
	if lobbysmith.get_players().size() != 3:
		problem = "%d players, expected 3" % lobbysmith.get_players().size()
	elif lobbysmith.get_scene() == null or lobbysmith.get_scene().name != "Room":
		problem = "scene is not Room"
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_extra(peer: Node, lobbysmith: Node, events: Array) -> void:
	# Name of the scene on the stage at each scene_entered.
	var scenes := []
	var started := [false]
	lobbysmith.session_started.connect(func(): started[0] = true)
	lobbysmith.scene_entered.connect(func():
		var scene: Node = lobbysmith.get_scene()
		scenes.append(str(scene.name) if scene != null else "null"))
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return started[0], 15.0):
		peer.fail_and_quit("no session_started")
		return
	if not await peer.wait_until(func(): return not scenes.is_empty(), 20.0):
		peer.fail_and_quit("extra never got scene_entered")
		return
	await peer.get_tree().create_timer(0.5).timeout
	var problem := ""
	if scenes != ["Room"]:
		problem = "scene_entered fired with scenes %s, expected [Room]" % [scenes]
	elif lobbysmith.get_scene().name != "Room":
		problem = "final scene is not Room"
	if problem == "" and not await peer.wait_checkpoint("done", 30.0):
		problem = "no done checkpoint"
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()
