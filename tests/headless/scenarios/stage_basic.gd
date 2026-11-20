extends RefCounted
# The host shows a scene; clients already in the session get it and its state.
# When the host leaves, the stage is empty again.

const ROOM := "res://tests/headless/fixtures/room.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		if lobbysmith.host_lan(peer.port) != OK:
			peer.fail_and_quit("host_lan failed")
			return
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
			peer.fail_and_quit("roster never reached %d" % peer.total)
			return
		if lobbysmith.change_scene(ROOM) != OK:
			peer.fail_and_quit("change_scene failed")
			return
		lobbysmith.get_scene().value = 42
		peer.broadcast("shown")
		var problem: String = await peer.collect_reports("shown", peer.total - 1, 10.0)
		if problem != "":
			peer.fail_and_quit(problem)
			return
		lobbysmith.leave()
		peer.pass_and_quit()
	else:
		var ended := [-1]
		lobbysmith.session_ended.connect(func(reason): ended[0] = reason)
		if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("join_lan failed")
			return
		if not await peer.wait_checkpoint("shown", 30.0):
			peer.fail_and_quit("no shown checkpoint")
			return
		var problem := ""
		if not await peer.wait_until(func(): return lobbysmith.get_scene() != null and lobbysmith.get_scene().value == 42, 5.0):
			problem = "client never saw the scene with value 42"
		elif lobbysmith.change_scene(ROOM) != ERR_UNAUTHORIZED:
			problem = "client change_scene should be ERR_UNAUTHORIZED"
		elif not peer.is_inside_tree():
			problem = "test node was removed"
		peer.report("shown", problem == "", problem)
		if problem != "":
			await peer.get_tree().create_timer(0.5).timeout
			peer.fail_and_quit(problem)
			return
		if not await peer.wait_until(func(): return ended[0] == lobbysmith.EndReason.HOST_LEFT, 10.0):
			peer.fail_and_quit("no HOST_LEFT, got %d" % ended[0])
			return
		await peer.get_tree().process_frame
		if lobbysmith.get_scene() != null:
			peer.fail_and_quit("stage not empty after the host left")
			return
		peer.pass_and_quit()
