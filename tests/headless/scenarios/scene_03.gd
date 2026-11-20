extends RefCounted
# Drives feature scene 03 through its buttons: the host changes the scene twice,
# everyone follows, the ready list is full each time, then the host leaves.

const MENU := "res://tests/feature_scenes/03_szenenwechsel/menu.tscn"
const HERE := "Everyone is here."


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
	menu.get_node("%PortSpin").value = peer.port
	if peer.role == "host":
		menu.get_node("%HostButton").pressed.emit()
		await run_host(peer, lobbysmith)
	else:
		menu.get_node("%IpEdit").text = "127.0.0.1"
		menu.get_node("%JoinButton").pressed.emit()
		if not menu.get_node("%JoinButton").disabled or not menu.get_node("%HostButton").disabled:
			peer.fail_and_quit("menu buttons not disabled while the join runs")
			return
		await run_client(peer, lobbysmith, tree)


func run_host(peer: Node, lobbysmith: Node) -> void:
	var room: Node = await wait_for_room(peer, lobbysmith, "RoomA", 20.0)
	if room == null:
		return
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == 3, 20.0):
		peer.fail_and_quit("roster never reached 3, has %d" % lobbysmith.get_players().size())
		return
	if not await peer.wait_until(func(): return room.get_node("%StatusLabel").text == HERE, 20.0):
		peer.fail_and_quit("room A never said everyone is here")
		return
	peer.broadcast("a1")
	var problem: String = await peer.collect_reports("a1", 2, 15.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	room.get_node("%GoButton").pressed.emit()
	room = await wait_for_room(peer, lobbysmith, "RoomB", 10.0)
	if room == null:
		return
	problem = await check_room(peer, room, "Room B", "Go to A", 1)
	if problem != "":
		peer.fail_and_quit("host: " + problem)
		return
	peer.broadcast("b")
	problem = await peer.collect_reports("b", 2, 15.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	room.get_node("%GoButton").pressed.emit()
	room = await wait_for_room(peer, lobbysmith, "RoomA", 10.0)
	if room == null:
		return
	problem = await check_room(peer, room, "Room A", "Go to B", 2)
	if problem != "":
		peer.fail_and_quit("host: " + problem)
		return
	peer.broadcast("a2")
	problem = await peer.collect_reports("a2", 2, 15.0)
	if problem != "":
		peer.fail_and_quit(problem)
		return
	room.get_node("%LeaveButton").pressed.emit()
	await peer.get_tree().create_timer(1.0).timeout
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node, tree: SceneTree) -> void:
	var steps := [["a1", "RoomA", "Room A", 0], ["b", "RoomB", "Room B", 1], ["a2", "RoomA", "Room A", 2]]
	for step in steps:
		if not await peer.wait_checkpoint(step[0], 60.0):
			peer.fail_and_quit("no checkpoint %s" % step[0])
			return
		var room: Node = await wait_for_room(peer, lobbysmith, step[1], 5.0)
		if room == null:
			return
		var problem: String = await check_room(peer, room, step[2], null, step[3])
		if problem == "" and not room.get_node("%GoButton").disabled:
			problem = "go button usable on a client"
		peer.report(step[0], problem == "", problem)
		if problem != "":
			await tree.create_timer(0.5).timeout
			peer.fail_and_quit(problem)
			return
	await tree.create_timer(0.5).timeout
	var back := func():
		var scene := tree.current_scene
		return scene != null and scene.scene_file_path == MENU \
				and scene.get_node("%StatusLabel").text == "The host left the session."
	if not await peer.wait_until(back, 5.0):
		peer.fail_and_quit("no menu with host-left notice after the host left")
		return
	peer.pass_and_quit()


## Waits for the room with this root name, "everyone is here" shown; null (after failing) if not.
func wait_for_room(peer: Node, lobbysmith: Node, room_name: String, seconds: float) -> Node:
	var shown := func():
		var scene: Node = lobbysmith.get_scene()
		return scene != null and scene.name == room_name and scene.get_node("%StatusLabel").text == HERE
	if not await peer.wait_until(shown, seconds):
		var scene: Node = lobbysmith.get_scene()
		peer.fail_and_quit("%s not ready (scene %s)" % [room_name, scene.name if scene else "null"])
		return null
	return lobbysmith.get_scene()


## "" if the room shows what it should, else what is wrong. go_text null: not checked.
func check_room(peer: Node, room: Node, title: String, go_text: Variant, changes: int) -> String:
	var list: ItemList = room.get_node("%ReadyList")
	var count_ok := func(): return list.item_count == 3
	if not await peer.wait_until(count_ok, 5.0):
		return "ready list has %d entries" % list.item_count
	if room.get_node("%TitleLabel").text != title:
		return "title '%s'" % room.get_node("%TitleLabel").text
	if go_text != null and room.get_node("%GoButton").text != go_text:
		return "go button '%s'" % room.get_node("%GoButton").text
	var counter: String = room.get_node("%ChangesLabel").text
	if counter != "Scene changes: %d" % changes:
		return "counter '%s'" % counter
	for i in list.item_count:
		if not list.get_item_text(i).ends_with(": ready"):
			return "list entry '%s'" % list.get_item_text(i)
	return ""
