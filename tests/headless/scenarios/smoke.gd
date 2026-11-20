extends RefCounted
# Runner self-check: raw ENet, no LobbySmith. One host, one client.

func run(peer: Node) -> void:
	var enet := ENetMultiplayerPeer.new()
	if peer.role == "host":
		if enet.create_server(peer.port, 4) != OK:
			peer.fail_and_quit("create_server failed")
			return
		peer.multiplayer.multiplayer_peer = enet
		if not await peer.wait_until(func(): return peer.multiplayer.get_peers().size() == 1, 10.0):
			peer.fail_and_quit("client never connected")
			return
		peer.broadcast("hello")
		var problem: String = await peer.collect_reports("hello", 1, 10.0)
		if problem != "":
			peer.fail_and_quit("report: " + problem)
			return
		peer.pass_and_quit()
	else:
		if enet.create_client("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("create_client failed")
			return
		peer.multiplayer.multiplayer_peer = enet
		if not await peer.wait_checkpoint("hello", 10.0):
			peer.fail_and_quit("no checkpoint from host")
			return
		peer.report("hello", true)
		await peer.get_tree().create_timer(0.5).timeout
		peer.pass_and_quit()
