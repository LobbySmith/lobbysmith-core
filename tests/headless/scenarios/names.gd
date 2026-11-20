extends RefCounted
# Names sent by clients are untrusted: control, zero-width and bidirectional characters removed, trimmed,
# cut to 24 characters, duplicates allowed (a name is no identity, the peer id is).

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		lobbysmith.local_name = "Host"
		if lobbysmith.host_lan(peer.port) != OK:
			peer.fail_and_quit("host_lan failed")
			return
		if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 4, 20.0):
			peer.fail_and_quit("roster never reached 4")
			return
		var names := []
		for info in lobbysmith.get_players().values():
			names.append(info["name"])
		names.sort()
		var expected := ["A".repeat(24), "EveX", "Host", "Host"]
		# A name made only of invisible characters is empty: the player gets "Player N".
		var blank: String = lobbysmith._new_player("\u200b\u202e\u2066 \ufeff")["name"]
		var soft: String = lobbysmith._new_player("\u00ad\u00ad")["name"]
		if not soft.begins_with("Player "):
			peer.fail_and_quit("soft-hyphen-only name became '%s'" % soft)
			return
		if not blank.begins_with("Player "):
			peer.fail_and_quit("invisible-only name became '%s'" % blank)
			return
		peer.broadcast("done")
		await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 10.0)
		if names != expected:
			peer.fail_and_quit("names %s" % [names])
			return
		peer.pass_and_quit()
	else:
		match peer.index:
			1: lobbysmith.local_name = "A".repeat(5000)
			2: lobbysmith.local_name = "  Host  "
			_: lobbysmith.local_name = "\tEve\u200b\u202e\nX\u007f\u2066\u2028\ufeff "
		if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
			peer.fail_and_quit("join_lan failed")
			return
		if not await peer.wait_checkpoint("done", 25.0):
			peer.fail_and_quit("no done checkpoint")
			return
		peer.pass_and_quit()
