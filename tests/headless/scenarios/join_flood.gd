extends RefCounted
# One machine opens as many silent connections as the host has seats and keeps reopening them.
# A real player who joins meanwhile must still get in: the host keeps at most two connections
# that are no player yet and older than a second per address and drops the oldest of them.
# Timeline: the flooder (client 1, no LobbySmith) starts 0.5 s after the host and floods for 16 s,
# the real joiner (extra) starts about 4.5 s after the host.

const FLOOD_SECONDS := 16.0


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	match peer.role:
		"host":
			await run_host(peer, lobbysmith)
		"client":
			await run_flooder(peer, lobbysmith)
		"extra":
			await run_joiner(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	lobbysmith.join_timeout = 6.0
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return peer.multiplayer.get_peers().size() >= 2, 6.0):
		peer.fail_and_quit("the flooder never connected")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2, 20.0):
		peer.fail_and_quit("the real player never got in, players: %d, connections: %d"
				% [lobbysmith.get_players().size(), peer.multiplayer.get_peers().size()])
		return
	await peer.get_tree().create_timer(1.0).timeout
	# What matters is that the real player got in. The silent connections held at this moment
	# depend on timing (fresh ones are in their grace second), so only the seat limit is checked.
	var silent: int = peer.multiplayer.get_peers().size() - (lobbysmith.get_players().size() - 1)
	if silent >= lobbysmith.max_players:
		peer.fail_and_quit("%d silent connections fill every seat" % silent)
		return
	if lobbysmith.get_players().size() != 2:
		peer.fail_and_quit("player list changed to %d entries" % lobbysmith.get_players().size())
		return
	peer.pass_and_quit()


# Not a LobbySmith client: raw ENet peers that connect and never register. One (re)connect every
# 0.3 s: the host's server relay logs an engine error when it tells a connection that is just
# being closed about a newcomer, which a faster flood would provoke.
func run_flooder(peer: Node, lobbysmith: Node) -> void:
	lobbysmith.set_process(false)
	var raws := []
	var end := Time.get_ticks_msec() + int(FLOOD_SECONDS * 1000.0)
	var next_connect := 0
	while Time.get_ticks_msec() < end:
		for raw in raws:
			if raw.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
				raw.poll()
		if Time.get_ticks_msec() >= next_connect:
			next_connect = Time.get_ticks_msec() + 300
			var slot := -1
			for i in raws.size():
				if raws[i].get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
					slot = i
					break
			if slot == -1 and raws.size() < lobbysmith.max_players:
				raws.append(null)
				slot = raws.size() - 1
			if slot != -1:
				var raw := ENetMultiplayerPeer.new()
				if raw.create_client("127.0.0.1", peer.port) != OK:
					peer.fail_and_quit("raw create_client failed")
					return
				raws[slot] = raw
		await peer.get_tree().process_frame
	for raw in raws:
		if raw.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			raw.close()
	peer.pass_and_quit()


func run_joiner(peer: Node, lobbysmith: Node) -> void:
	lobbysmith.join_timeout = 6.0
	var result := [""]
	lobbysmith.join_failed.connect(func(error): result[0] = "join_failed:%d" % error)
	lobbysmith.session_started.connect(func(): result[0] = "session_started")
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	await peer.wait_until(func(): return result[0] != "", 10.0)
	if result[0] != "session_started":
		peer.fail_and_quit("the real player got '%s', expected session_started" % result[0])
		return
	await peer.get_tree().create_timer(2.0).timeout
	peer.pass_and_quit()
