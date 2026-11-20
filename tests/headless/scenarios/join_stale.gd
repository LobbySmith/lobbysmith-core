extends RefCounted
# The host drops connections that do not become players within join_timeout:
# a client that connects but never registers, and a joiner that never reports
# its scene. Both free their seat (max_players is 2), and a player who is in
# is never dropped by the timer.
# Timeline: client starts 0.5 s after the host, the extra about 4.5 s after it.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const SECOND_JOIN_AT := 10.0   # seconds after the client's own start


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	match peer.role:
		"host":
			await run_host(peer, lobbysmith)
		"client":
			await run_client(peer, lobbysmith)
		"extra":
			await run_extra(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	var joined := [0]
	var left := [0]
	lobbysmith.player_joined.connect(func(_id): joined[0] += 1)
	lobbysmith.player_left.connect(func(_id): left[0] += 1)
	lobbysmith.max_players = 2
	lobbysmith.join_timeout = 2.0
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	await peer.get_tree().process_frame
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	if not await peer.wait_until(func(): return peer.multiplayer.get_peers().size() == 1, 6.0):
		peer.fail_and_quit("the silent client never connected")
		return
	if not await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 6.0):
		peer.fail_and_quit("silent connection was not dropped within 6 s")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2, 20.0):
		peer.fail_and_quit("second join never completed, players: %d" % lobbysmith.get_players().size())
		return
	var problem := ""
	if joined[0] != 1:
		problem = "player_joined came %d times, expected 1" % joined[0]
	elif left[0] != 0:
		problem = "player_left came %d times" % left[0]
	# Longer than join_timeout: the timer must leave an admitted player alone.
	await peer.get_tree().create_timer(3.0).timeout
	if problem == "":
		if lobbysmith.get_players().size() != 2:
			problem = "player list has %d entries after the timeout" % lobbysmith.get_players().size()
		elif peer.multiplayer.get_peers().size() != 1:
			problem = "expected 1 connection after the timeout, have %d" % peer.multiplayer.get_peers().size()
		elif left[0] != 0:
			problem = "player_left came after the timeout"
	peer.broadcast("done")
	var reported: String = await peer.collect_reports("count", 1, 10.0)
	if problem == "" and reported != "":
		problem = reported
	await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 10.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node) -> void:
	var started_at := Time.get_ticks_msec()
	# Part 1: connect without registering.
	var handler: Callable = lobbysmith._on_connected_to_server
	peer.multiplayer.connected_to_server.disconnect(handler)
	var raw := ENetMultiplayerPeer.new()
	if raw.create_client("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("raw create_client failed")
		return
	peer.multiplayer.multiplayer_peer = raw
	var dropped: bool = await peer.wait_until(
			func(): return raw.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED, 6.0)
	if not dropped:
		peer.fail_and_quit("host never dropped a silent connection")
		return
	peer.multiplayer.connected_to_server.connect(handler)
	peer.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	# Part 2: a proper join once the extra's seat is free again.
	var wait_left := SECOND_JOIN_AT - (Time.get_ticks_msec() - started_at) / 1000.0
	if wait_left > 0.0:
		await peer.get_tree().create_timer(wait_left).timeout
	var started := [false]
	lobbysmith.session_started.connect(func(): started[0] = true)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return started[0], 5.0):
		peer.fail_and_quit("no session_started: the freed seat was not usable")
		return
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint")
		return
	var count: int = lobbysmith.get_players().size()
	peer.report("count", count == 2, "client sees %d players, expected 2" % count)
	await peer.get_tree().create_timer(0.5).timeout
	peer.pass_and_quit()


## Never reports "scene stands": the host must drop it after its join_timeout.
func run_extra(peer: Node, lobbysmith: Node) -> void:
	var result := [""]
	lobbysmith.join_failed.connect(func(error): result[0] = "join_failed:%d" % error)
	lobbysmith.session_started.connect(func(): result[0] = "session_started")
	lobbysmith.set_process(false)
	lobbysmith.join_timeout = 10.0
	var started_at := Time.get_ticks_msec()
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	await peer.wait_until(func(): return result[0] != "", 8.0)
	var elapsed := (Time.get_ticks_msec() - started_at) / 1000.0
	var problem := ""
	if result[0] != "join_failed:%d" % lobbysmith.JoinError.TIMEOUT:
		problem = "extra got '%s', expected join_failed(TIMEOUT)" % result[0]
	elif elapsed < 1.0 or elapsed > 5.0:
		problem = "extra was dropped after %.1f s, expected 1 to 5 s" % elapsed
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()
