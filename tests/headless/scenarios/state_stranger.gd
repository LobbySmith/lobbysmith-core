extends RefCounted
# A connection that never registered is no part of the session: it gets no state changes, and
# an _apply that reaches it anyway changes nothing there. Host, 1 client, 1 stranger (client 2:
# connects without registering, as join_stale does).


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		await run_host(peer, lobbysmith)
	elif peer.index == 1:
		await run_client(peer, lobbysmith)
	else:
		await run_stranger(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2 and peer.multiplayer.get_peers().size() == 2, 20.0):
		peer.fail_and_quit("client and stranger never both connected")
		return
	if lobbysmith.state.set_value("k", 1) != OK:
		peer.fail_and_quit("set_value failed")
		return
	var problem: String = await peer.collect_reports("seen", 1, 10.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	# The stranger is still connected (join_timeout is 15 s); it checks when the host is gone.
	await peer.get_tree().create_timer(2.0).timeout
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node) -> void:
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	var seen: bool = await peer.wait_until(func(): return lobbysmith.state.get_value("k") == 1, 20.0)
	peer.report("seen", seen, "the client never saw the state change")
	if not seen:
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit("never saw the state change")
		return
	await peer.get_tree().create_timer(2.0).timeout
	peer.pass_and_quit()


func run_stranger(peer: Node, lobbysmith: Node) -> void:
	var handler: Callable = lobbysmith._on_connected_to_server
	peer.multiplayer.connected_to_server.disconnect(handler)
	var changes := []
	lobbysmith.state.changed.connect(func(key): changes.append(key))
	var raw := ENetMultiplayerPeer.new()
	if raw.create_client("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("raw create_client failed")
		return
	peer.multiplayer.multiplayer_peer = raw
	await peer.wait_until(func(): return raw.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED, 30.0)
	if not changes.is_empty() or lobbysmith.state.has("k"):
		peer.fail_and_quit("the stranger got state changes %s" % [changes])
		return
	peer.pass_and_quit()
