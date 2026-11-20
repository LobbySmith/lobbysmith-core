extends RefCounted
# A joiner that reported its scene while a scene change is running is held until
# the change ends. If the change outlasts the joiner's join_timeout window, the
# host's stranger timer must not drop it: the joiner is announced once the change
# ends, and never gets join_failed.
# Timing: host join_timeout 2 s; the extra starts about 4.5 s after the host; the
# host broadcasts freeze at about 3.0 s and changes scene 0.3 s later; the client
# freezes for 4 s, so the change is open from 3.3 s to about 7 s and the extra
# (connected at about 4.5 s, window 2 s) is held past its window.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const ROOM_B := "res://tests/headless/fixtures/room_b.tscn"


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
	var begin := Time.get_ticks_msec()
	var joined := [0]
	lobbysmith.player_joined.connect(func(_id): joined[0] += 1)
	lobbysmith.join_timeout = 2.0
	lobbysmith.scene_timeout = 8.0
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	await peer.get_tree().process_frame
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 2 and not lobbysmith.is_changing_scene(), 20.0):
		peer.fail_and_quit("client never joined")
		return
	var wait_msec := 3000 - (Time.get_ticks_msec() - begin)
	if wait_msec > 0:
		await peer.get_tree().create_timer(wait_msec / 1000.0).timeout
	joined[0] = 0
	peer.broadcast("freeze")
	await peer.get_tree().create_timer(0.3).timeout
	if lobbysmith.change_scene(ROOM_B) != OK:
		peer.fail_and_quit("change_scene to room B failed")
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 3, 5.0 + 10.0):
		peer.fail_and_quit("extra was never admitted (dropped while held?), %d peers" % peer.multiplayer.get_peers().size())
		return
	await peer.get_tree().create_timer(0.5).timeout
	var problem := ""
	if joined[0] != 1:
		problem = "player_joined came %d times, expected 1" % joined[0]
	elif peer.multiplayer.get_peers().size() != 2:
		problem = "expected 2 connections, have %d" % peer.multiplayer.get_peers().size()
	if problem == "":
		peer.broadcast("done")
		problem = await peer.collect_reports("done", 2, 10.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node) -> void:
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_checkpoint("freeze", 30.0):
		peer.fail_and_quit("no freeze checkpoint")
		return
	OS.delay_msec(4000)
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint")
		return
	var problem := ""
	if lobbysmith.get_players().size() != 3:
		problem = "%d players, expected 3" % lobbysmith.get_players().size()
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()


func run_extra(peer: Node, lobbysmith: Node) -> void:
	var failed := [-1]
	var started := [false]
	lobbysmith.join_failed.connect(func(error): failed[0] = error)
	lobbysmith.session_started.connect(func(): started[0] = true)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return started[0] or failed[0] >= 0, 15.0):
		peer.fail_and_quit("neither session_started nor join_failed")
		return
	if failed[0] >= 0:
		peer.fail_and_quit("join_failed(%d) for a joiner that did everything right" % failed[0])
		return
	if not await peer.wait_checkpoint("done", 30.0):
		peer.fail_and_quit("no done checkpoint (disconnected?)")
		return
	var problem := ""
	if failed[0] >= 0:
		problem = "join_failed(%d)" % failed[0]
	elif lobbysmith.get_players().size() != 3:
		problem = "%d players, expected 3" % lobbysmith.get_players().size()
	elif lobbysmith.get_scene() == null or lobbysmith.get_scene().name != "RoomB":
		problem = "scene is not RoomB"
	peer.report("done", problem == "", problem)
	await peer.get_tree().create_timer(0.5).timeout
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()
