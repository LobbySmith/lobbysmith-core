extends RefCounted
# Single process: calls that must be refused while a session is active.

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var problems := []
	if lobbysmith.host_lan(peer.port) != OK:
		problems.append("first host_lan should be OK")
	if not (lobbysmith.is_active() and lobbysmith.is_host()):
		problems.append("should be active host")
	if lobbysmith.get_players().size() != 1:
		problems.append("host alone should be 1 player")
	if lobbysmith.get_players()[1]["name"] != "Player 1":
		problems.append("unnamed host should be Player 1, is %s" % lobbysmith.get_players()[1]["name"])
	if lobbysmith.host_lan(peer.port + 1) != ERR_ALREADY_IN_USE:
		problems.append("second host_lan should be ERR_ALREADY_IN_USE")
	if lobbysmith.join_lan("127.0.0.1", peer.port) != ERR_ALREADY_IN_USE:
		problems.append("join_lan while hosting should be ERR_ALREADY_IN_USE")
	var copy: Dictionary = lobbysmith.get_players()
	copy[1]["name"] = "changed"
	copy[99] = {}
	if lobbysmith.get_players().size() != 1 or lobbysmith.get_players()[1]["name"] != "Player 1":
		problems.append("get_players must return a copy")
	lobbysmith.leave()
	lobbysmith.local_name = "\u0001\n\t\u007f"   # only control characters: the name is empty
	if lobbysmith.host_lan(peer.port) != OK:
		problems.append("host_lan with a control-character name should be OK")
	elif lobbysmith.get_players()[1]["name"] != "Player 1":
		problems.append("control-character host name should be Player 1, is %s" % lobbysmith.get_players()[1]["name"])
	lobbysmith.leave()
	if problems.is_empty():
		peer.pass_and_quit()
	else:
		peer.fail_and_quit("; ".join(problems))
