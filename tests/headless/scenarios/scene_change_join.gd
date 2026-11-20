extends RefCounted
# A player who joins while a scene change is running (the client hangs, so the
# change stays open) is announced only after the change ended. The host hears
# scene_entered twice and then player_joined; the joiner gets its own
# scene_entered after session_started.
# Timing: the extra starts about 4.5 s after the host; the client freezes at
# about 3.0 s for 4 s, so the change is open from 3.3 s to about 7 s.

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
	# [peers on network level at the second scene_entered, players then]
	var at_second := [-1, -1]
	lobbysmith.scene_entered.connect(func():
		if events.count("scene_entered") == 2:
			at_second[0] = peer.multiplayer.get_peers().size()
			at_second[1] = lobbysmith.get_players().size())
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2, 20.0):
		peer.fail_and_quit("client never joined")
		return
	events.clear()
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
	if lobbysmith.change_scene(ROOM_B) != OK:
		peer.fail_and_quit("change_scene to room B failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 3, 5.0 + 10.0):
		peer.fail_and_quit("extra never joined, events %s" % [events])
		return
	if events != ["scene_entered", "scene_entered", "player_joined"]:
		peer.fail_and_quit("events were %s" % [events])
		return
	if at_second[0] != 2:
		peer.fail_and_quit("at the second scene_entered %d peers were connected, expected 2 (the extra must come mid-change)" % at_second[0])
		return
	if at_second[1] != 2:
		peer.fail_and_quit("at the second scene_entered %d players were announced, expected 2" % at_second[1])
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
	elif lobbysmith.get_scene() == null or lobbysmith.get_scene().name != "RoomB":
		problem = "scene is not RoomB"
	elif events.count("scene_entered") != 2 or events.find("player_joined") < events.rfind("scene_entered"):
		problem = "events were %s, player_joined must come after the second scene_entered" % [events]
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_extra(peer: Node, lobbysmith: Node, events: Array) -> void:
	# [scene_entered count at session_started]
	var at_start := [-1]
	lobbysmith.session_started.connect(func(): at_start[0] = events.count("scene_entered"))
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return at_start[0] >= 0, 15.0):
		peer.fail_and_quit("no session_started")
		return
	# The change is still running here: scene_entered comes when it ends.
	if not await peer.wait_until(func(): return events.count("scene_entered") >= 1, 15.0):
		peer.fail_and_quit("extra never got scene_entered")
		return
	await peer.get_tree().create_timer(0.5).timeout
	var problem := ""
	if at_start[0] != 0:
		problem = "scene_entered came before session_started"
	elif events.count("scene_entered") != 1:
		problem = "scene_entered came %d times after session_started, expected 1" % events.count("scene_entered")
	elif lobbysmith.get_scene() == null or lobbysmith.get_scene().name != "RoomB":
		problem = "scene is not RoomB"
	if problem == "" and not await peer.wait_checkpoint("done", 30.0):
		problem = "no done checkpoint"
	if problem == "":
		var players: Dictionary = lobbysmith.get_players()
		if players.size() != 3:
			problem = "%d players, expected 3" % players.size()
		for id in players:
			if not players[id]["ready"]:
				problem = "player %d not ready" % id
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()
