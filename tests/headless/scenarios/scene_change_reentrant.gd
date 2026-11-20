extends RefCounted
# A buyer's signal handler calls leave() in the middle of change_scene: the host
# must not log an error, the session is simply over, and the client hears HOST_LEFT.

const ROOM := "res://tests/headless/fixtures/room.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		await run_host(peer, lobbysmith)
	else:
		await run_client(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2, 20.0):
		peer.fail_and_quit("client never joined")
		return
	var ended := [-1]
	if await peer.collect_reports("up", 1, 20.0) != "":
		peer.fail_and_quit("client never reported being in the session")
		return
	lobbysmith.session_ended.connect(func(reason): ended[0] = reason)
	lobbysmith.ready_changed.connect(func(_id): lobbysmith.leave(), CONNECT_ONE_SHOT)
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene should return OK when the handler left")
		return
	var problem := ""
	if lobbysmith.is_active():
		problem = "host still active after leave in a handler"
	elif lobbysmith.is_changing_scene():
		problem = "still changing after the session ended"
	elif ended[0] != lobbysmith.EndReason.LEFT:
		problem = "host got session_ended %d" % ended[0]
	await peer.get_tree().process_frame
	if problem == "" and lobbysmith.get_scene() != null:
		problem = "scene still on the stage a frame later"
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node) -> void:
	var ended := [-1]
	lobbysmith.session_ended.connect(func(reason): ended[0] = reason)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.is_active(), 20.0):
		peer.fail_and_quit("never joined")
		return
	peer.report("up", true)
	if not await peer.wait_until(func(): return ended[0] == lobbysmith.EndReason.HOST_LEFT, 20.0):
		peer.fail_and_quit("no HOST_LEFT, got %d" % ended[0])
		return
	peer.pass_and_quit()
