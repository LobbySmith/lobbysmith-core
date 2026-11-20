extends RefCounted
# The host's player_joined handler calls leave() while a late joiner is admitted
# with a scene running: no error on the host, and the joiner is never stuck.

const ROOM := "res://tests/headless/fixtures/room.tscn"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	if peer.role == "host":
		await run_host(peer, lobbysmith)
	else:
		await run_extra(peer, lobbysmith)


func run_host(peer: Node, lobbysmith: Node) -> void:
	# peer.gd clears current_scene deferred; wait so the stage does not free the test node.
	await peer.get_tree().process_frame
	if lobbysmith.host_lan(peer.port) != OK:
		peer.fail_and_quit("host_lan failed")
		return
	if lobbysmith.change_scene(ROOM) != OK:
		peer.fail_and_quit("change_scene failed")
		return
	var joined := [false]
	lobbysmith.player_joined.connect(func(_id):
		joined[0] = true
		lobbysmith.leave(), CONNECT_ONE_SHOT)
	if not await peer.wait_until(func(): return joined[0], 20.0):
		peer.fail_and_quit("late joiner was never admitted")
		return
	await peer.get_tree().create_timer(1.0).timeout
	if lobbysmith.is_active():
		peer.fail_and_quit("host still active after leave in player_joined")
		return
	peer.pass_and_quit()


func run_extra(peer: Node, lobbysmith: Node) -> void:
	var result := [""]
	lobbysmith.join_failed.connect(func(_error): result[0] = "failed")
	lobbysmith.session_ended.connect(func(reason):
		if reason == lobbysmith.EndReason.HOST_LEFT:
			result[0] = "host_left")
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	if not await peer.wait_until(func(): return result[0] != "", 20.0):
		peer.fail_and_quit("joiner is stuck: no session_ended(HOST_LEFT) and no join_failed")
		return
	peer.pass_and_quit()
