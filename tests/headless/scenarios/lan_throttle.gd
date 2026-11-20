extends RefCounted
# ENet drops unreliable packets when a connection's throttle sinks. Core switches the throttle
# off (deceleration 0) on every LAN connection; every peer checks its own connections.


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		await run_host(peer, lobbysmith)
	else:
		await run_guest(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	# The extra joins about 4 s after the client.
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() >= 3, 30.0):
		peer.fail_and_quit("roster never reached 3, has %d" % lobbysmith.get_players().size())
		return
	var problem := throttle_problem(peer, 2)
	var others: String = await peer.collect_reports("throttle", 2, 20.0)
	if problem == "":
		problem = others
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.broadcast("done")
	await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 10.0)
	lobbysmith.leave()
	peer.pass_and_quit()


func run_guest(peer: Node, lobbysmith: Node) -> void:
	var started := [false]
	lobbysmith.session_started.connect(func(): started[0] = true)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return started[0], 20.0):
		peer.fail_and_quit("no session_started")
		return
	var problem := throttle_problem(peer, 1)
	peer.report("throttle", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	# Stay until the host has seen all three players, or the client would be gone before the extra joins.
	if not await peer.wait_checkpoint("done", 40.0):
		peer.fail_and_quit("no done checkpoint")
		return
	peer.pass_and_quit()


func throttle_problem(peer: Node, want_connections: int) -> String:
	var enet := peer.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null or enet.host == null:
		return "no ENet host"
	var connected := 0
	for packet_peer: ENetPacketPeer in enet.host.get_peers():
		if packet_peer.get_state() != ENetPacketPeer.STATE_CONNECTED:
			continue
		connected += 1
		var deceleration := int(packet_peer.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_DECELERATION))
		if deceleration != 0:
			return "a connection has throttle deceleration %d, wanted 0 (ENet may drop unreliable packets)" % deceleration
	if connected != want_connections:
		return "%d connected ENet peers, wanted %d" % [connected, want_connections]
	return ""
