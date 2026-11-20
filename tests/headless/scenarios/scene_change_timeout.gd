extends RefCounted
# A scene change ends at scene_timeout for everyone who is ready. A client that
# hangs (frozen for 3 s) becomes ready later and gets its own scene_entered.

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
	lobbysmith.scene_timeout = 1.0
	# [msec of first scene_entered, ready clients then, not ready clients then, changing then]
	var first := [0, [], [], true]
	lobbysmith.scene_entered.connect(func():
		if first[0] != 0:
			return
		first[0] = Time.get_ticks_msec()
		first[3] = lobbysmith.is_changing_scene()
		var players: Dictionary = lobbysmith.get_players()
		for id in players:
			if id != 1:
				(first[1] if players[id]["ready"] else first[2]).append(id))
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	peer.broadcast("freeze")
	await peer.get_tree().create_timer(0.3).timeout
	var started := Time.get_ticks_msec()
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	if not await peer.wait_until(func(): return entered[0] >= 1, 6.0):
		peer.fail_and_quit("no scene_entered at all")
		return
	var elapsed: int = first[0] - started
	if elapsed < 800 or elapsed > 2500:
		peer.fail_and_quit("first scene_entered after %d ms, expected 800..2500" % elapsed)
		return
	if first[3]:
		peer.fail_and_quit("still changing inside scene_entered")
		return
	if first[1].size() != 1 or first[2].size() != 1:
		peer.fail_and_quit("at timeout %d clients ready, %d not" % [first[1].size(), first[2].size()])
		return
	var straggler: int = first[2][0]
	if not await peer.wait_until(func(): return lobbysmith.get_players()[straggler]["ready"], 6.0):
		peer.fail_and_quit("straggler never became ready")
		return
	if entered[0] != 1:
		peer.fail_and_quit("host scene_entered came %d times, expected 1" % entered[0])
		return
	peer.broadcast("settled")
	var problem: String = await peer.collect_reports("settled", peer.total - 1, 10.0)
	if problem != "":
		peer.fail_and_quit("settled: " + problem)
		return
	# A timeout that is still running must not end anything after leave().
	if lobbysmith.change_scene(ROOM_B) != OK:
		peer.fail_and_quit("change_scene to room B failed")
		return
	lobbysmith.leave()
	# Longer than scene_timeout (1.0 s): the timer is still running and must do nothing.
	await peer.get_tree().create_timer(1.3).timeout
	if entered[0] != 1:
		peer.fail_and_quit("scene_entered after leave: %d" % entered[0])
		return
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node, entered: Array) -> void:
	var ended := [-1]
	lobbysmith.session_ended.connect(func(reason): ended[0] = reason)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_checkpoint("freeze", 30.0):
		peer.fail_and_quit("no freeze checkpoint")
		return
	if peer.index == 2:
		OS.delay_msec(3000)
	if not await peer.wait_checkpoint("settled", 30.0):
		peer.fail_and_quit("no settled checkpoint")
		return
	var problem := ""
	if not await peer.wait_until(func(): return entered[0] >= 1, 5.0):
		problem = "no scene_entered"
	else:
		await peer.get_tree().create_timer(0.3).timeout
		var players: Dictionary = lobbysmith.get_players()
		for id in players:
			if not players[id]["ready"]:
				problem = "player %d not ready" % id
		if entered[0] != 1:
			problem = "scene_entered came %d times" % entered[0]
		elif lobbysmith.get_scene() == null or lobbysmith.get_scene().name != "Room":
			problem = "scene is not Room"
	peer.report("settled", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	if not await peer.wait_until(func(): return ended[0] == lobbysmith.EndReason.HOST_LEFT, 10.0):
		peer.fail_and_quit("no HOST_LEFT, got %d" % ended[0])
		return
	await peer.get_tree().process_frame
	if lobbysmith.get_scene() != null:
		peer.fail_and_quit("scene still there after the session ended")
		return
	peer.pass_and_quit()
