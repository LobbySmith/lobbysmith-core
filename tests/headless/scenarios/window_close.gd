extends RefCounted
# Closing the window is leaving: the host's session ends and the client hears HOST_LEFT.

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		if lobbysmith.host_lan(peer.port) != OK:
			peer.fail_and_quit("host_lan failed")
			return
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2, 20.0):
			peer.fail_and_quit("roster never reached 2")
			return
		peer.broadcast("up")
		var problem: String = await peer.collect_reports("up", 1, 10.0)
		if problem != "":
			peer.fail_and_quit(problem)
			return
		# Sends the notification to the autoload only; it does not quit this process.
		lobbysmith.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
		if lobbysmith.is_active():
			peer.fail_and_quit("session still active after close request")
			return
		await peer.get_tree().create_timer(1.0).timeout   # let the client hear it
		peer.pass_and_quit()
	else:
		var reasons := []
		lobbysmith.session_ended.connect(func(reason): reasons.append(reason))
		if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("join_lan failed")
			return
		if not await peer.wait_checkpoint("up", 20.0):
			peer.fail_and_quit("no up checkpoint")
			return
		peer.report("up", true, "")
		await peer.get_tree().create_timer(0.5).timeout   # let the report arrive
		if not await peer.wait_until(func(): return not reasons.is_empty(), 5.0) \
				or reasons != [lobbysmith.EndReason.HOST_LEFT]:
			peer.fail_and_quit("expected HOST_LEFT, got %s" % [reasons])
			return
		peer.pass_and_quit()
