extends "res://tests/headless/scenarios/late_join.gd"
# Full room while a scene runs: the ninth player is turned away and keeps no scene.


func run_extra(peer: Node, lobbysmith: Node) -> void:
	var result := [""]
	lobbysmith.join_failed.connect(func(error): result[0] = "failed:%d" % error)
	lobbysmith.session_started.connect(func(): result[0] = "started")
	await peer.get_tree().process_frame
	var project_scene := make_project_scene(peer)
	if lobbysmith.join_lan("127.0.0.1", peer.port) != OK:
		peer.fail_and_quit("join_lan failed")
		return
	await peer.wait_until(func(): return result[0] != "", 10.0)
	if result[0] != "failed:%d" % lobbysmith.JoinError.ROOM_FULL:
		peer.fail_and_quit("ninth player got '%s', expected ROOM_FULL" % result[0])
		return
	await peer.get_tree().process_frame
	var problem := ""
	if lobbysmith.get_scene() != null:
		problem = "ninth player still shows a scene"
	elif not is_instance_valid(project_scene):
		problem = "ninth player lost its own scene"
	elif peer.get_tree().current_scene != project_scene:
		problem = "ninth player's current_scene changed"
	if is_instance_valid(project_scene):
		project_scene.free()
	if problem != "":
		peer.fail_and_quit(problem)
		return
	peer.pass_and_quit()
