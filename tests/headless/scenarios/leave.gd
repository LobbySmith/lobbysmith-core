extends RefCounted
# A client leaves, then the host leaves. Everyone hears about it.

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var left_ids := []
	var ended := []
	lobbysmith.player_left.connect(func(id): left_ids.append(id))
	lobbysmith.session_ended.connect(func(reason): ended.append(reason))
	if peer.role == "host":
		if lobbysmith.host_lan(peer.port) != OK:
			peer.fail_and_quit("host_lan failed")
			return
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 4, 20.0):
			peer.fail_and_quit("roster never reached 4")
			return
		var before: Array = lobbysmith.get_players().keys()
		peer.broadcast("go")
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 3, 10.0):
			peer.fail_and_quit("roster did not shrink to 3")
			return
		var gone := before.filter(func(id): return not lobbysmith.get_players().has(id))
		if left_ids != gone:
			peer.fail_and_quit("player_left %s, expected %s" % [left_ids, gone])
			return
		peer.broadcast("after_leave")
		var problem: String = await peer.collect_reports("after_leave", 2, 10.0)
		if problem != "":
			peer.fail_and_quit(problem)
			return
		lobbysmith.leave()
		if ended != [lobbysmith.EndReason.LEFT] or lobbysmith.is_active() or not lobbysmith.get_players().is_empty():
			peer.fail_and_quit("host leave: ended=%s active=%s" % [ended, lobbysmith.is_active()])
			return
		# Stay alive briefly so the clients see a clean close, not a vanished process.
		await peer.get_tree().create_timer(1.0).timeout
		peer.pass_and_quit()
	else:
		if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("join_lan failed")
			return
		if not await peer.wait_checkpoint("go", 30.0):
			peer.fail_and_quit("no go checkpoint")
			return
		if peer.index == 1:
			lobbysmith.leave()
			if ended != [lobbysmith.EndReason.LEFT] or lobbysmith.is_active() or not lobbysmith.get_players().is_empty():
				peer.fail_and_quit("client leave: ended=%s active=%s" % [ended, lobbysmith.is_active()])
				return
			peer.pass_and_quit()
			return
		if not await peer.wait_checkpoint("after_leave", 20.0):
			peer.fail_and_quit("no after_leave checkpoint")
			return
		var ok: bool = lobbysmith.get_players().size() == 3 and left_ids.size() == 1
		peer.report("after_leave", ok, "client sees %d players, %d left signals" % [lobbysmith.get_players().size(), left_ids.size()])
		if not await peer.wait_until(func(): return not ended.is_empty(), 15.0):
			peer.fail_and_quit("no session_ended after host left")
			return
		if ended != [lobbysmith.EndReason.HOST_LEFT] or lobbysmith.is_active() \
				or not (peer.multiplayer.multiplayer_peer is OfflineMultiplayerPeer) \
				or not lobbysmith.get_players().is_empty():
			peer.fail_and_quit("after host left: ended=%s active=%s" % [ended, lobbysmith.is_active()])
			return
		peer.pass_and_quit()
