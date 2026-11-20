extends RefCounted
# A player who leaves during a scene change must not hold it up: the host
# checks again at once, long before scene_timeout (15 s).

const ROOM := "res://tests/headless/fixtures/room.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var entered := [0]
	lobbysmith.scene_entered.connect(func(): entered[0] += 1)
	if peer.role == "host":
		await run_host(peer, lobbysmith, entered)
	else:
		await run_client(peer, lobbysmith, entered)


func run_host(peer: Node, lobbysmith: Node, entered: Array) -> void:
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	peer.broadcast("freeze")
	await peer.get_tree().create_timer(0.3).timeout
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	if not await peer.wait_until(func(): return entered[0] >= 1, 6.0):
		peer.fail_and_quit("no scene_entered after the player left")
		return
	var players: Dictionary = lobbysmith.get_players()
	if players.size() != 2:
		peer.fail_and_quit("%d players, expected 2" % players.size())
		return
	for id in players:
		if not players[id]["ready"]:
			peer.fail_and_quit("player %d not ready" % id)
			return
	if lobbysmith.is_changing_scene():
		peer.fail_and_quit("still changing")
		return
	peer.broadcast("done")
	var problem: String = await peer.collect_reports("done", 1, 10.0)
	if problem != "":
		peer.fail_and_quit("done: " + problem)
		return
	lobbysmith.leave()
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node, entered: Array) -> void:
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_checkpoint("freeze", 30.0):
		peer.fail_and_quit("no freeze checkpoint")
		return
	if peer.index == 2:
		OS.delay_msec(1500)
		lobbysmith.leave()
		peer.pass_and_quit()
		return
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint")
		return
	var problem := ""
	if entered[0] != 1:
		problem = "scene_entered came %d times" % entered[0]
	elif lobbysmith.get_players().size() != 2:
		problem = "%d players, expected 2" % lobbysmith.get_players().size()
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()
