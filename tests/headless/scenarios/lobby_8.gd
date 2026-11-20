extends "res://tests/headless/scenarios/lobby_4.gd"
# Full room: 8 players share one list, a ninth is turned away with a reason.

func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	match peer.role:
		"host":
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
			# Give the ninth player time to try (the runner starts it after 4 s).
			await peer.get_tree().create_timer(8.0).timeout
			if problem == "":
				problem = host_problem(peer, lobbysmith)
			if problem == "" and lobbysmith.get_players().size() != 8:
				problem = "roster changed to %d after the ninth tried" % lobbysmith.get_players().size()
			peer.broadcast("done")
			await peer.wait_until(func(): return peer.multiplayer.get_peers().is_empty(), 10.0)
			if problem != "":
				peer.fail_and_quit(problem)
				return
			peer.pass_and_quit()
		"client":
			var joined := [0]
			lobbysmith.player_joined.connect(func(_id): joined[0] += 1)
			if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
				peer.fail_and_quit("join_lan failed")
				return
			if not await peer.wait_checkpoint("roster", 30.0):
				peer.fail_and_quit("no roster checkpoint")
				return
			var problem := client_problem(peer, lobbysmith)
			peer.report("roster", problem == "", problem)
			if not await peer.wait_checkpoint("done", 30.0):
				peer.fail_and_quit("no done checkpoint")
				return
			if problem == "" and lobbysmith.get_players().size() != 8:
				problem = "client roster changed to %d" % lobbysmith.get_players().size()
			if problem != "":
				peer.fail_and_quit(problem)
				return
			peer.pass_and_quit()
		"extra":
			var result := [""]
			lobbysmith.join_failed.connect(func(error): result[0] = "failed:%d" % error)
			lobbysmith.session_started.connect(func(): result[0] = "started")
			if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
				peer.fail_and_quit("join_lan failed")
				return
			await peer.wait_until(func(): return result[0] != "", 10.0)
			if result[0] != "failed:%d" % lobbysmith.JoinError.ROOM_FULL:
				peer.fail_and_quit("ninth player got '%s', expected ROOM_FULL" % result[0])
				return
			if lobbysmith.is_active():
				peer.fail_and_quit("ninth player is active after rejection")
				return
			peer.pass_and_quit()
