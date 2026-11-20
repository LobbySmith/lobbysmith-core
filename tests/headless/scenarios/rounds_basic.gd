extends RefCounted
# LobbySmith.rounds keeps the round in LobbySmith.state: only the host starts and ends, everyone hears
# started/ended once per transition, a scene change does not end the round, and when the host
# leaves the state (and so the round) is gone without an `ended`. Host and 3 clients.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const ROOM_B := "res://tests/headless/fixtures/room_b.tscn"
const STARTED := [1, 2, 3]
const ENDED := [[1, {"points": 10}], [2, {"points": 20}], [3, {"points": 30}]]


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var rounds: Node = lobbysmith.rounds
	var started := []
	var ended := []
	var entered := [0]
	rounds.started.connect(func(number: int): started.append(number))
	rounds.ended.connect(func(number: int, result: Variant): ended.append([number, result]))
	lobbysmith.scene_entered.connect(func(): entered[0] += 1)
	if peer.role == "host":
		await _run_host(peer, lobbysmith, rounds, started, ended, entered)
	else:
		await _run_client(peer, lobbysmith, rounds, started, ended)


func _run_host(peer: Node, lobbysmith: Node, rounds: Node, started: Array, ended: Array, entered: Array) -> void:
	if rounds.start() != ERR_UNAUTHORIZED or rounds.get_number() != 0 or rounds.is_running():
		peer.fail_and_quit("before hosting: start should be ERR_UNAUTHORIZED, no round")
		return
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 20.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	if lobbysmith.change_scene(ROOM) != OK or not await peer.wait_until(func(): return entered[0] >= 1, 20.0):
		peer.fail_and_quit("room never entered")
		return
	if rounds.end() != ERR_UNAVAILABLE:
		peer.fail_and_quit("end without a round should be ERR_UNAVAILABLE")
		return
	# Keys that start with "lobbysmith:" belong to Core: game code cannot write them.
	for key in ["lobbysmith:round", "lobbysmith:other"]:
		if lobbysmith.state.set_value(key, 5) != ERR_INVALID_PARAMETER or lobbysmith.state.has(key):
			peer.fail_and_quit("state.set_value('%s') should be ERR_INVALID_PARAMETER and write nothing" % key)
			return
	if lobbysmith.state.set_value("lobbysmither", 1) != OK or lobbysmith.state.set_value("lobbysmith", 1) != OK:
		peer.fail_and_quit("keys without the 'lobbysmith:' prefix must stay free")
		return
	if rounds.start() != OK or rounds.start() != ERR_BUSY:
		peer.fail_and_quit("start should be OK, then ERR_BUSY")
		return
	if rounds.end(Vector3.ZERO) != ERR_INVALID_PARAMETER or not rounds.is_running():
		peer.fail_and_quit("end(Vector3.ZERO) should be ERR_INVALID_PARAMETER and keep the round running")
		return
	if rounds.end({"points": 10}) != OK:
		peer.fail_and_quit("end of round 1 failed")
		return
	for n in [2, 3]:
		if rounds.start() != OK:
			peer.fail_and_quit("start of round %d failed" % n)
			return
		if n == 2:
			if lobbysmith.change_scene(ROOM_B) != OK or not await peer.wait_until(func(): return entered[0] >= 2, 20.0):
				peer.fail_and_quit("room_b never entered")
				return
			if not rounds.is_running() or rounds.get_number() != 2:
				peer.fail_and_quit("the scene change disturbed round 2")
				return
		if rounds.end({"points": n * 10}) != OK:
			peer.fail_and_quit("end of round %d failed" % n)
			return
	var problem := _problem(rounds, started, ended)
	if problem != "":
		peer.fail_and_quit("host: " + problem)
		return
	peer.broadcast("check")
	problem = await peer.collect_reports("check", peer.total - 1, 20.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	if rounds.start() != OK:
		peer.fail_and_quit("start of round 4 failed")
		return
	peer.broadcast("four")
	problem = await peer.collect_reports("four", peer.total - 1, 20.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	# A malformed value under the round key (only Core's internal path can write it) is read
	# as "no round" on every peer, without errors and without signals.
	var malformed := [5, {"running": true}, {"n": 4}, {"n": "4", "running": true}, [1, 2]]
	for i in malformed.size():
		lobbysmith.state._set_internal("lobbysmith:round", malformed[i])
		peer.broadcast("bad%d" % i)
		problem = await peer.collect_reports("bad%d" % i, peer.total - 1, 20.0)
		if problem != "" or rounds.is_running() or rounds.get_number() != 0 or rounds.get_result() != null:
			peer.fail_and_quit("host: malformed round %s: %s" % [malformed[i], problem])
			return
	# The malformed loop left "no round", so the leave check below would pass on its own. A valid
	# running round is written again through the public API (round number 1, the internal value
	# counted as no round) and every client must see it running before the host leaves.
	if rounds.start() != OK or not rounds.is_running():
		peer.fail_and_quit("host: start after the malformed values failed")
		return
	peer.broadcast("five")
	problem = await peer.collect_reports("five", peer.total - 1, 20.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	lobbysmith.leave()
	if rounds.is_running() or rounds.get_number() != 0 or ended.size() != 3:
		peer.fail_and_quit("host: leave should empty the round without an ended")
		return
	await peer.get_tree().create_timer(1.0).timeout
	peer.pass_and_quit()


func _run_client(peer: Node, lobbysmith: Node, rounds: Node, started: Array, ended: Array) -> void:
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_checkpoint("check", 40.0):
		peer.fail_and_quit("no check checkpoint")
		return
	var problem := ""
	if not await peer.wait_until(func(): return ended.size() >= 3, 5.0):
		problem = "client heard %d ended" % ended.size()
	else:
		problem = _problem(rounds, started, ended)
	if problem == "" and (rounds.start() != ERR_UNAUTHORIZED or rounds.end() != ERR_UNAUTHORIZED):
		problem = "client start/end should be ERR_UNAUTHORIZED"
	peer.report("check", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	if not await peer.wait_checkpoint("four", 30.0):
		peer.fail_and_quit("no four checkpoint")
		return
	if not await peer.wait_until(func(): return rounds.is_running() and rounds.get_number() == 4, 5.0):
		problem = "client never saw round 4"
	peer.report("four", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	# The host writes malformed round values: no round, no errors, no signals.
	for i in 5:
		if not await peer.wait_checkpoint("bad%d" % i, 20.0):
			peer.fail_and_quit("no bad checkpoint %d" % i)
			return
		var ok: bool = await peer.wait_until(func(): return not rounds.is_running() and rounds.get_number() == 0, 5.0)
		ok = ok and rounds.get_result() == null and started.size() == 4 and ended.size() == 3
		peer.report("bad%d" % i, ok, "client sees a round or heard a signal after a malformed value")
	# The host started a valid round again: the client must see it running, so the check after the
	# leave can fail.
	if not await peer.wait_checkpoint("five", 20.0):
		peer.fail_and_quit("no five checkpoint")
		return
	if not await peer.wait_until(func(): return rounds.is_running() and rounds.get_number() == 1, 5.0):
		problem = "client never saw the new round after the malformed values"
	peer.report("five", problem == "", problem)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout
		peer.fail_and_quit(problem)
		return
	# The host leaves now: the state is emptied, the round is gone, and no ended comes for it.
	if not await peer.wait_until(func(): return not rounds.is_running() and rounds.get_number() == 0, 5.0):
		peer.fail_and_quit("the round survived the end of the session")
		return
	await peer.get_tree().create_timer(0.5).timeout
	if ended.size() != 3:
		peer.fail_and_quit("ended came after the session ended: %s" % [ended])
		return
	peer.pass_and_quit()


func _problem(rounds: Node, started: Array, ended: Array) -> String:
	if started != STARTED:
		return "started was %s" % [started]
	if ended != ENDED:
		return "ended was %s" % [ended]
	if rounds.is_running() or rounds.get_number() != 3 or rounds.get_result() != {"points": 30}:
		return "getters wrong: running %s, number %d, result %s" % [rounds.is_running(), rounds.get_number(), rounds.get_result()]
	return ""
