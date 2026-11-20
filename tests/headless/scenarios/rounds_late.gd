extends RefCounted
# A player who joins while round 2 runs gets the round state without signals: from session_started
# on the getters are right and `started` did not come. Then the host ends the round and the late
# player hears `ended` once. Host, 1 client and 1 extra (about 4.5 s after the host).

const ROOM := "res://tests/headless/fixtures/room.tscn"
const RUNNING := "2 true <null>"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var rounds: Node = lobbysmith.rounds
	var started := []
	var ended := []
	rounds.started.connect(func(number: int): started.append(number))
	rounds.ended.connect(func(number: int, result: Variant): ended.append([number, result]))
	match peer.role:
		"host":
			await _run_host(peer, lobbysmith, rounds)
		"client":
			if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
				peer.fail_and_quit("join_lan failed")
				return
			if not await peer.wait_checkpoint("done", 40.0):
				peer.fail_and_quit("no done checkpoint")
				return
			peer.pass_and_quit()
		"extra":
			await _run_extra(peer, lobbysmith, rounds, started, ended)


func summary(rounds: Node) -> String:
	return "%d %s %s" % [rounds.get_number(), rounds.is_running(), rounds.get_result()]


func _run_host(peer: Node, lobbysmith: Node, rounds: Node) -> void:
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	if rounds.start() != OK or rounds.end({"points": 5}) != OK or rounds.start() != OK:
		peer.fail_and_quit("rounds 1 and 2 did not start as planned")
		return
	if lobbysmith.get_players().size() != peer.total:
		peer.fail_and_quit("the extra joined too early: the late path was not tested")
		return
	var problem: String = await peer.collect_reports("late", 1, 40.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	if rounds.end({"points": 7}) != OK:
		peer.fail_and_quit("end of round 2 failed")
		return
	problem = await peer.collect_reports("ended", 1, 20.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.broadcast("done")
	await peer.get_tree().create_timer(1.0).timeout
	lobbysmith.leave()
	peer.pass_and_quit()


func _run_extra(peer: Node, lobbysmith: Node, rounds: Node, started: Array, ended: Array) -> void:
	var early := {}
	lobbysmith.session_started.connect(func():
		early["at"] = summary(rounds)
		await peer.get_tree().process_frame
		early["frame"] = summary(rounds))
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return early.has("frame"), 20.0):
		peer.fail_and_quit("extra never started the session")
		return
	await peer.get_tree().create_timer(0.5).timeout
	var problem := ""
	if early["at"] != RUNNING or early["frame"] != RUNNING:
		problem = "late state was '%s' / '%s'" % [early["at"], early["frame"]]
	elif not started.is_empty() or not ended.is_empty():
		problem = "signals came for the late player: %s %s" % [started, ended]
	peer.report("late", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	if not await peer.wait_until(func(): return not ended.is_empty(), 20.0):
		peer.fail_and_quit("extra never heard ended")
		return
	await peer.get_tree().create_timer(0.5).timeout
	if ended != [[2, {"points": 7}]] or not started.is_empty():
		problem = "ended was %s, started %s" % [ended, started]
	peer.report("ended", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	await peer.wait_checkpoint("done", 30.0)
	peer.pass_and_quit()
