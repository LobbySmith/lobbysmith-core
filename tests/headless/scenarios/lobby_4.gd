extends RefCounted
# Lobby over LAN: everyone ends up with the same player list.
# Also used by lobby_8 through the runner (same script logic, more clients).

var joined_count := 0


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		lobbysmith.local_name = "Host"
		lobbysmith.player_joined.connect(func(_id): joined_count += 1)
		if lobbysmith.host_lan(peer.port) != OK:
			peer.fail_and_quit("host_lan failed")
			return
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
			peer.fail_and_quit("roster never reached %d, has %d" % [peer.total, lobbysmith.get_players().size()])
			return
		peer.broadcast("roster")
		var problem: String = await peer.collect_reports("roster", peer.total - 1, 10.0)
		if problem == "":
			problem = host_problem(peer, lobbysmith)
		if problem != "":
			peer.fail_and_quit(problem)
			return
		peer.pass_and_quit()
	else:
		var started := [false]
		lobbysmith.session_started.connect(func(): started[0] = true)
		if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("join_lan failed")
			return
		if not await peer.wait_until(func(): return started[0], 15.0):
			peer.fail_and_quit("no session_started")
			return
		if not await peer.wait_checkpoint("roster", 25.0):
			peer.fail_and_quit("no roster checkpoint")
			return
		var problem := client_problem(peer, lobbysmith)
		peer.report("roster", problem == "", problem)
		await peer.get_tree().create_timer(0.5).timeout
		if problem != "":
			peer.fail_and_quit(problem)
			return
		peer.pass_and_quit()


func host_problem(peer: Node, lobbysmith: Node) -> String:
	if not lobbysmith.is_host():
		return "host is not host"
	if lobbysmith.get_room_code() != "":
		return "LAN room code should be empty"
	var names := []
	for info in lobbysmith.get_players().values():
		if not info["ready"]:
			return "a player is not ready"
		names.append(info["name"])
	names.sort()
	var expected := ["Host"]
	for n in range(2, peer.total + 1):
		expected.append("Player %d" % n)
	expected.sort()
	if names != expected:
		return "names %s, expected %s" % [names, expected]
	if joined_count != peer.total - 1:
		return "player_joined came %d times" % joined_count
	return ""


func client_problem(peer: Node, lobbysmith: Node) -> String:
	var players: Dictionary = lobbysmith.get_players()
	if players.size() != peer.total:
		return "client sees %d players" % players.size()
	if lobbysmith.is_host():
		return "client thinks it is host"
	if not players.has(peer.multiplayer.get_unique_id()):
		return "own id missing from roster"
	if not players.has(1) or players[1]["name"] != "Host":
		return "id 1 is not named Host"
	return ""
