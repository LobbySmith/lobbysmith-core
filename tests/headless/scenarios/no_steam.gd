extends RefCounted
# Single process, no GodotSteam in the project: Steam calls fail cleanly, LAN still works.

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var failures := []
	lobbysmith.join_failed.connect(func(error): failures.append(error))
	if lobbysmith.is_steam_available():
		peer.fail_and_quit("GodotSteam is installed in the main project; this test needs it absent")
		return
	if lobbysmith.host_steam() != OK:
		peer.fail_and_quit("host_steam should return OK and report through the signal")
		return
	await peer.wait_until(func(): return failures.size() == 1, 1.0)
	if failures != [lobbysmith.JoinError.STEAM_MISSING] or lobbysmith.is_active():
		peer.fail_and_quit("host_steam: failures=%s" % [failures])
		return
	if lobbysmith.join_steam("abc 234") != OK:
		peer.fail_and_quit("join_steam should return OK and report through the signal")
		return
	await peer.wait_until(func(): return failures.size() == 2, 1.0)
	if failures != [lobbysmith.JoinError.STEAM_MISSING, lobbysmith.JoinError.STEAM_MISSING]:
		peer.fail_and_quit("join_steam: failures=%s" % [failures])
		return
	if lobbysmith.host_lan(peer.port) != OK or not lobbysmith.is_active():
		peer.fail_and_quit("LAN should still work without GodotSteam")
		return
	if lobbysmith.host_steam() != ERR_ALREADY_IN_USE:
		peer.fail_and_quit("host_steam during a session should be ERR_ALREADY_IN_USE")
		return
	lobbysmith.leave()
	# A failure queued by an attempt that was cancelled must not end the next attempt.
	failures.clear()
	lobbysmith.join_timeout = 1.0
	if lobbysmith.host_steam() != OK:
		peer.fail_and_quit("host_steam should return OK")
		return
	lobbysmith.leave()   # cancels the attempt, no signal
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:   # nobody listens there
		peer.fail_and_quit("join_lan should return OK")
		return
	await peer.get_tree().create_timer(0.5).timeout
	if not failures.is_empty():
		peer.fail_and_quit("stale failure hit the new attempt: %s" % [failures])
		return
	await peer.wait_until(func(): return failures.size() == 1, 3.0)
	if failures != [lobbysmith.JoinError.TIMEOUT]:
		peer.fail_and_quit("new attempt should time out: failures=%s" % [failures])
		return
	peer.pass_and_quit()
