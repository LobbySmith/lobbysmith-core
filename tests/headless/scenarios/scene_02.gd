extends RefCounted
# Drives feature scene 02 through its buttons: host, early and late joiners see
# the same room. Then abuse: a standing figure sends nothing; one client sends a burst of requests
# (the host caps it at 10 per second per sender and node) and moves its figure to NaN and to an
# absurd place (the host and the other clients keep its last good position: each watches every frame). A sender that is no player is refused.
# Then one client leaves and the host leaves; the host hosts once more from the menu.

const MENU := "res://tests/feature_scenes/02_nachzuegler/menu.tscn"
const EXPECTED := "count=3 crates=[1, 3, 2]"
const GOOD_SPOT := Vector3(-2, 0, 4)   # where client 1 put its figure


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var tree := peer.get_tree()
	# The menu is the tree's current scene, as in a real game.
	await tree.process_frame
	tree.change_scene_to_file(MENU)
	if not await peer.wait_until(func(): return tree.current_scene != null, 5.0):
		peer.fail_and_quit("menu never became the current scene")
		return
	var menu: Control = tree.current_scene
	var status: Label = menu.get_node("%StatusLabel")
	if status.text != "Not connected.":
		peer.fail_and_quit("start status '%s'" % status.text)
		return
	menu.get_node("%PortSpin").value = peer.port
	if peer.role == "host":
		menu.get_node("%HostButton").pressed.emit()
	else:
		if peer.index > 1:
			await tree.create_timer(4.0).timeout   # late joiners
		menu.get_node("%IpEdit").text = "127.0.0.1"
		menu.get_node("%JoinButton").pressed.emit()
		if status.text != "Joining...":
			peer.fail_and_quit("status after pressing join '%s'" % status.text)
			return
	var room: Node = await wait_for_room(peer, lobbysmith, menu)
	if room == null:
		return
	if peer.role == "host":
		await run_host(peer, lobbysmith, room)
	else:
		await run_client(peer, lobbysmith, room, tree)


func run_host(peer: Node, lobbysmith: Node, room: Node) -> void:
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() >= 2, 20.0):
		peer.fail_and_quit("first client never joined")
		return
	room.get_node("Crate0").request_cycle()
	for i in 3:
		room.get_node("Crate1").request_cycle()
	room.request_count()
	room.request_count()
	if not await peer.wait_until(func(): return room.has_node("Players/1"), 5.0):
		peer.fail_and_quit("host figure missing")
		return
	room.get_node("Players/1").move_to(Vector3(1, 0, 3))
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 40.0):
		peer.fail_and_quit("roster never reached %d, has %d" % [peer.total, lobbysmith.get_players().size()])
		return
	await peer.get_tree().create_timer(1.0).timeout
	peer.broadcast("compare")
	var problem: String = await peer.collect_reports("compare", peer.total - 1, 15.0)
	var mine: String = room.summary()
	if problem == "" and not mine.begins_with(EXPECTED):
		problem = "host summary is '%s'" % mine
	if problem == "" and mine.count("(") != peer.total:
		problem = "host summary has wrong figure count: '%s'" % mine
	if problem == "":
		for entry in peer._reports["compare"]:
			if entry[1] != mine:
				problem = "client saw '%s', host '%s'" % [entry[1], mine]
	if problem != "":
		peer.fail_and_quit(problem)
		return
	problem = await abuse_host(peer, room)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	# One client leaves: the others must lose exactly its figure.
	peer.broadcast("leave_one")
	problem = await peer.collect_reports("leaving_id", 1, 10.0)
	if problem == "":
		var left_id: int = peer._reports["leaving_id"][0][1].to_int()
		if not await peer.wait_until(func(): return figure_ids(room).size() == peer.total - 1 and not figure_ids(room).has(left_id), 5.0):
			problem = "host still shows %s after client %d left" % [figure_ids(room), left_id]
		elif lobbysmith.get_players().has(left_id):
			problem = "left client still in get_players()"
		elif room._rate.has(left_id) or room.get_node("Crate1")._rate.has(left_id):
			problem = "the rate table still has an entry of the client that left"
		else:
			problem = await peer.collect_reports("left", peer.total - 2, 10.0)
		if problem == "":
			for entry in peer._reports["left"]:
				if entry[1] != str([left_id]):
					problem = "a client lost %s, expected [%d]" % [entry[1], left_id]
	if problem != "":
		peer.fail_and_quit(problem)
		return
	room.get_node("%LeaveButton").pressed.emit()
	var menu: Control = await wait_for_menu(peer, "Not connected.")
	if menu == null:
		return
	# Host again from the same menu: nothing of the old room may be left over.
	menu.get_node("%PortSpin").value = peer.port
	menu.get_node("%HostButton").pressed.emit()
	room = await wait_for_room(peer, lobbysmith, menu)
	if room == null:
		return
	var again: String = room.summary()
	if not again.begins_with("count=0 crates=[0, 0, 0] figures=[1:(-7.0, 0.0)]") or figure_ids(room).size() != 1:
		peer.fail_and_quit("re-hosted room shows '%s'" % again)
		return
	if not lobbysmith.is_host() or lobbysmith.get_players().size() != 1:
		peer.fail_and_quit("re-hosted session has %d players" % lobbysmith.get_players().size())
		return
	room.get_node("%LeaveButton").pressed.emit()
	if await wait_for_menu(peer, "Not connected.") == null:
		return
	await peer.get_tree().create_timer(1.0).timeout
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node, room: Node, tree: SceneTree) -> void:
	var my_path := "Players/%d" % peer.multiplayer.get_unique_id()
	if not await peer.wait_until(func(): return room.has_node(my_path), 10.0):
		peer.fail_and_quit("own figure never appeared")
		return
	if peer.index == 1:
		room.get_node(my_path).move_to(GOOD_SPOT)
		room.get_node("Crate2").request_cycle()
		room.get_node("Crate2").request_cycle()
		room.request_count()
	if not await peer.wait_checkpoint("compare", 60.0):
		peer.fail_and_quit("no compare checkpoint")
		return
	var ready := func():
		var text: String = room.summary()
		return text.count("(") == peer.total and text.begins_with(EXPECTED)
	if not await peer.wait_until(ready, 5.0):
		peer.fail_and_quit("summary never complete: '%s'" % room.summary())
		return
	peer.report("compare", true, room.summary())
	if not await peer.wait_checkpoint("abuse", 60.0):
		peer.fail_and_quit("no abuse checkpoint")
		return
	if peer.index == 1:
		await abuse_client(peer, room, tree)
	else:
		await abuse_watch(peer, room, tree)
	var before := figure_ids(room)
	if not await peer.wait_checkpoint("leave_one", 30.0):
		peer.fail_and_quit("no leave_one checkpoint")
		return
	if peer.index == 3:
		room.request_count()   # the host now has a rate entry for this client, in the room and the crate
		room.get_node("Crate1").request_cycle()
		await tree.create_timer(0.3).timeout
		peer.report("leaving_id", true, str(peer.multiplayer.get_unique_id()))
		await tree.create_timer(0.5).timeout
		room.get_node("%LeaveButton").pressed.emit()
		if await wait_for_menu(peer, "Not connected.") != null:
			peer.pass_and_quit()
		return
	if not await peer.wait_until(func(): return figure_ids(room).size() == peer.total - 1, 5.0):
		peer.fail_and_quit("figures after a client left: %s" % [figure_ids(room)])
		return
	var missing := before.filter(func(id): return not figure_ids(room).has(id))
	peer.report("left", true, str(missing))
	await tree.create_timer(0.5).timeout
	var back := func():
		var scene := tree.current_scene
		return scene != null and scene.scene_file_path == MENU \
				and scene.get_node("%StatusLabel").text == "The host left the session."
	if not await peer.wait_until(back, 5.0):
		peer.fail_and_quit("no menu with host-left notice after the host left")
		return
	peer.pass_and_quit()


## Host: "" or the problem. Everything the host sees while client 1 misbehaves.
func abuse_host(peer: Node, room: Node) -> String:
	if room.request_allowed(99999) or room.get_node("Crate0")._allowed(99999):
		return "a sender that is no player was allowed"
	var tree := peer.get_tree()
	await tree.create_timer(1.2).timeout   # the rate windows of the earlier requests are over
	var others := figure_ids(room).filter(func(id: int): return id != 1)
	var received := [0]   # position updates that reached the host
	var count := func(): received[0] += 1
	for id: int in others:
		var sync: MultiplayerSynchronizer = room.get_node("Players/%d/Sync" % id)
		sync.synchronized.connect(count)
		sync.delta_synchronized.connect(count)
	await tree.create_timer(1.0).timeout
	if received[0] != 0:
		return "standing figures sent %d position updates in 1 s, wanted 0" % received[0]
	# Every frame: no figure may be anywhere but at a finite, sane place.
	var watch := {"bad": ""}
	var look := func():
		for id: int in others:
			var figure: Node3D = room.get_node_or_null("Players/%d" % id)
			if figure != null and not is_sane(figure.position):
				watch["bad"] = "figure %d was at %s" % [id, figure.position]
	tree.process_frame.connect(look)
	peer.broadcast("abuse")
	var problem: String = await peer.collect_reports("abuse", 1, 20.0)
	await tree.create_timer(0.5).timeout
	tree.process_frame.disconnect(look)
	peer.broadcast("abuse_done")
	var seen: String = await peer.collect_reports("abuse_seen", peer.total - 2, 20.0)
	if problem == "":
		problem = seen   # the other clients saw the bad position, or the attack never reached them
	if problem != "":
		return problem
	if watch["bad"] != "":
		return watch["bad"]
	if received[0] < 3:
		return "the host got %d position updates of the abusing client, wanted at least 3 (the attack did not arrive)" % received[0]
	var id: int = peer._reports["abuse"][0][1].to_int()
	var spot: Vector3 = room.get_node("Players/%d" % id).position
	if not spot.is_equal_approx(GOOD_SPOT):
		return "the figure of the abusing client is at %s, wanted %s" % [spot, GOOD_SPOT]
	if room._current_count() != 13:
		return "40 count requests in a burst gave count %d, wanted 13 (3 before plus the 10 the host allows)" % room._current_count()
	if room.get_node("Crate0").color_index != 3:
		return "11 crate requests in a burst gave colour %d, wanted 3 (10 are allowed, 1 + 10 = 11, mod 4 = 3)" % room.get_node("Crate0").color_index
	return ""


## A client that is not the attacker: every frame, no other figure may be at a bad place in its
## own view (the position reaches it through the host's relay, so only its own setter can refuse).
## Reports to the host when the host says the attack is over.
func abuse_watch(peer: Node, room: Node, tree: SceneTree) -> void:
	var own: int = peer.multiplayer.get_unique_id()
	var watch := {"bad": "", "received": 0}
	var count := func(): watch["received"] += 1
	for figure in room.get_node("%Players").get_children():
		if figure.name.to_int() not in [own, 1]:
			figure.get_node("Sync").synchronized.connect(count)
			figure.get_node("Sync").delta_synchronized.connect(count)
	var look := func():
		for figure in room.get_node("%Players").get_children():
			if figure.name.to_int() != own and not is_sane(figure.position):
				watch["bad"] = "client %d saw figure %s at %s" % [peer.index, figure.name, figure.position]
	tree.process_frame.connect(look)
	var done: bool = await peer.wait_checkpoint("abuse_done", 30.0)
	tree.process_frame.disconnect(look)
	var problem: String = watch["bad"]
	if not done:
		problem = "no abuse_done checkpoint"
	elif problem == "" and watch["received"] < 3:
		problem = "client %d got %d position updates of the attacker, wanted at least 3 (the attack did not arrive)" % [peer.index, watch["received"]]
	peer.report("abuse_seen", problem == "", problem if problem != "" else "ok")


## True for a finite place within 1000 m of the origin.
func is_sane(spot: Vector3) -> bool:
	return spot.is_finite() and maxf(absf(spot.x), maxf(absf(spot.y), absf(spot.z))) <= 1000.0


## Client 1: a burst of requests, then its own figure to NaN, to an absurd place, and back.
func abuse_client(peer: Node, room: Node, tree: SceneTree) -> void:
	await tree.create_timer(0.3).timeout
	for i in 40:
		room.request_count()
	for i in 11:
		room.get_node("Crate0").request_cycle()
	var mine: Node = room.get_node("Players/%d" % peer.multiplayer.get_unique_id())
	mine.get_node("Mesh").free()   # a NaN place would make this client's own renderer log an error
	for spot: Vector3 in [Vector3(NAN, 0, 0), Vector3(1e9, 0, 0), GOOD_SPOT]:
		mine.move_to(spot)
		await tree.create_timer(0.4).timeout
	peer.report("abuse", true, str(peer.multiplayer.get_unique_id()))


## The room for everyone replaces the menu: Core frees the current scene.
func wait_for_room(peer: Node, lobbysmith: Node, menu: Control) -> Node:
	var menu_id := menu.get_instance_id()   # a lambda cannot capture the menu once it is freed
	var shown := func():
		var scene: Node = lobbysmith.get_scene()
		return scene != null and scene.name == "Room" and not is_instance_id_valid(menu_id)
	if not await peer.wait_until(shown, 20.0):
		var scene: Node = lobbysmith.get_scene()
		peer.fail_and_quit("room not shown or menu not freed (scene %s, menu valid %s)"
				% [scene.name if scene else "null", is_instance_id_valid(menu_id)])
		return null
	return lobbysmith.get_scene()


## Waits until the menu is the current scene with this status text; null (after failing) if not.
func wait_for_menu(peer: Node, text: String) -> Control:
	var tree := peer.get_tree()
	var there := func():
		var scene := tree.current_scene
		return scene != null and scene.scene_file_path == MENU and scene.get_node("%StatusLabel").text == text
	if not await peer.wait_until(there, 5.0):
		peer.fail_and_quit("no menu with status '%s'" % text)
		return null
	return tree.current_scene


func figure_ids(room: Node) -> Array:
	var ids := []
	for figure in room.get_node("%Players").get_children():
		ids.append(figure.name.to_int())
	ids.sort()
	return ids
