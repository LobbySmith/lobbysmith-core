extends RefCounted
# Single process: what change_scene accepts and refuses.

const ROOM := "res://tests/headless/fixtures/room.tscn"
const LISTENER := "res://tests/headless/fixtures/listener.tscn"

var problems := []


func check(ok: bool, text: String) -> void:
	if not ok:
		problems.append(text)


func run(peer: Node) -> void:
	# peer.gd clears current_scene deferred; wait so the stage does not free the test node.
	await peer.get_tree().process_frame
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	check(lobbysmith.change_scene(ROOM) == ERR_UNAVAILABLE, "no session: ERR_UNAVAILABLE")
	check(lobbysmith.get_scene() == null, "no session: no scene")
	check(lobbysmith.host_lan(peer.port) == OK, "host_lan")
	var entered := [0]
	lobbysmith.scene_entered.connect(func(): entered[0] += 1)
	check(lobbysmith.change_scene("res://" + "nope.tscn") == ERR_FILE_NOT_FOUND, "missing file")
	check(lobbysmith.change_scene("res://tests/headless/peer.gd") == ERR_FILE_NOT_FOUND, "not a scene")
	check(lobbysmith.get_scene() == null, "refused calls leave the stage empty")
	check_res_only(lobbysmith)
	check(lobbysmith.change_scene(ROOM) == OK, "change_scene OK")
	check(lobbysmith.get_scene() != null and lobbysmith.get_scene().name == "Room", "scene is Room")
	check(entered[0] == 0, "host alone: scene_entered must not come inside change_scene")
	check(not lobbysmith.is_changing_scene(), "host alone: not changing after the call")
	await peer.get_tree().process_frame
	await peer.get_tree().process_frame
	check(entered[0] == 1, "host alone: scene_entered comes on the next frame, %d times" % entered[0])
	var first: Node = lobbysmith.get_scene()
	check(lobbysmith.change_scene(ROOM) == OK, "second change_scene OK")
	await peer.get_tree().process_frame
	await peer.get_tree().process_frame
	check(lobbysmith.get_node("Stage").get_child_count() == 1, "one scene after replacing")
	check(lobbysmith.get_scene() != first, "scene was replaced")
	check(lobbysmith.is_active() and lobbysmith.get_players().size() == 1, "session unchanged")
	check(peer.is_inside_tree(), "test node survived")
	await check_listener(peer, lobbysmith, entered)
	lobbysmith.leave()
	await peer.get_tree().process_frame
	check(lobbysmith.get_scene() == null, "leave empties the stage")
	if problems.is_empty():
		peer.pass_and_quit()
	else:
		peer.fail_and_quit("; ".join(problems))


# scene_entered on a host with nobody else: never for a scene that is gone.
func check_listener(peer: Node, lobbysmith: Node, entered: Array) -> void:
	var listener_calls: Array = load("res://tests/headless/fixtures/listener.gd").calls
	listener_calls.clear()
	lobbysmith.change_scene(LISTENER)
	await peer.get_tree().process_frame
	await peer.get_tree().process_frame
	check(listener_calls.size() == 1 and listener_calls[0]["inside"], "listener called once inside the tree")
	var first_id: int = listener_calls[0]["id"] if listener_calls.size() > 0 else 0
	var before: int = entered[0]
	lobbysmith.change_scene(ROOM)
	await peer.get_tree().process_frame
	await peer.get_tree().process_frame
	check(not is_instance_id_valid(first_id), "first listener instance was freed")
	check(listener_calls.size() == 1, "old listener heard scene_entered again (%d calls)" % listener_calls.size())
	check(entered[0] == before + 1, "scene_entered once more for the second scene, got %d" % (entered[0] - before))
	# Two changes in one frame: one scene_entered, for the second scene.
	listener_calls.clear()
	before = entered[0]
	check(lobbysmith.change_scene(ROOM) == OK, "change before the double change")
	check(lobbysmith.change_scene(LISTENER) == OK, "second change in the same frame is not busy")
	await peer.get_tree().process_frame
	await peer.get_tree().process_frame
	check(entered[0] == before + 1, "two changes in a frame gave %d scene_entered" % (entered[0] - before))
	check(listener_calls.size() == 1 and listener_calls[0]["inside"], "second scene's listener heard it once")


# Only res:// scenes: a real scene saved outside res:// is refused by change_scene, and the
# spawn function every client runs refuses it too (null, no engine error).
func check_res_only(lobbysmith: Node) -> void:
	var packed := PackedScene.new()
	var node := Node.new()
	packed.pack(node)
	node.free()
	var user_path := "user://lobbysmith_guard_scene.tscn"
	check(ResourceSaver.save(packed, user_path) == OK, "saved a scene to user://")
	check(lobbysmith.change_scene(user_path) == ERR_FILE_NOT_FOUND, "user:// scene refused by change_scene")
	check(lobbysmith.get_scene() == null, "refused user:// scene is not shown")
	# Paths that leave res:// through "..": refused by both, whether or not they would resolve.
	for dotted in ["res://" + "../x.tscn", "res://" + "tests/../tests/headless/fixtures/room.tscn", "res://" + "./tests/headless/fixtures/room.tscn"]:
		check(lobbysmith.change_scene(dotted) == ERR_FILE_NOT_FOUND, "change_scene refuses " + dotted)
	check(lobbysmith.get_scene() == null, "refused dotted paths are not shown")
	var stage: Node = lobbysmith.get_node("Stage")
	for dotted in ["res://" + "../x.tscn", "res://" + "tests/../tests/headless/fixtures/room.tscn"]:
		check(stage.make_scene({"path": dotted, "serial": 1}) == null, "make_scene refuses " + dotted)
	check(stage.make_scene({"path": user_path, "serial": 1}) == null, "make_scene refuses user://")
	check(stage.make_scene({"path": "uid://nothing", "serial": 1}) == null, "make_scene refuses uid://")
	check(stage.make_scene({"path": "res://tests/headless/peer.gd", "serial": 1}) == null, "make_scene refuses a non-scene")
	check(stage.make_scene({"path": "res://" + "nope.tscn", "serial": 1}) == null, "make_scene refuses a missing scene")
	check(stage.make_scene({"serial": 1}) == null, "make_scene refuses data without a path")
	check(stage.make_scene({"path": 5, "serial": 1}) == null, "make_scene refuses a path that is no string")
	check(stage.make_scene({"path": ROOM}) == null, "make_scene refuses data without a serial")
	var good: Node = stage.make_scene({"path": ROOM, "serial": 7})
	check(good != null and good.get_meta("lobbysmith_serial") == 7, "make_scene still builds a res:// scene")
	if good != null:
		good.free()
	DirAccess.remove_absolute(user_path)
