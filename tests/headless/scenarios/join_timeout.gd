extends RefCounted
# Single process: leave() without a session is a no-op; joining a dead address times out.

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var signals := []
	lobbysmith.session_ended.connect(func(reason): signals.append("ended:%d" % reason))
	lobbysmith.join_failed.connect(func(error): signals.append("failed:%d" % error))
	lobbysmith.leave()
	await peer.get_tree().create_timer(0.5).timeout
	if not signals.is_empty():
		peer.fail_and_quit("leave() without a session emitted %s" % [signals])
		return
	lobbysmith.join_timeout = 2.0
	if lobbysmith.join_lan("127.0.0.1", peer.port + 5) != OK:
		peer.fail_and_quit("join_lan should start")
		return
	await peer.wait_until(func(): return not signals.is_empty(), 5.0)
	if signals != ["failed:%d" % lobbysmith.JoinError.TIMEOUT]:
		peer.fail_and_quit("expected TIMEOUT, got %s" % [signals])
		return
	if lobbysmith.is_active():
		peer.fail_and_quit("active after timeout")
		return
	if lobbysmith.join_lan("127.0.0.1", peer.port + 5) != OK:
		peer.fail_and_quit("second join_lan should start again")
		return
	lobbysmith.leave()
	await peer.get_tree().create_timer(0.2).timeout
	if signals.size() != 1:
		peer.fail_and_quit("leave() during a join attempt emitted %s" % [signals])
		return
	peer.pass_and_quit()
