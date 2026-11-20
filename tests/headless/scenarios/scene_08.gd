extends RefCounted
# Drives feature scene 08 (round flow) through its buttons: host, 2 clients and 1 extra (joins
# about 4.5 s after the host). Round 1: all three players press the point button twice, 6 points,
# the host ends it, and a point request sent after the end changes nothing. Round 2: the host
# starts, a client presses once, then the extra joins late and shows round 2 running with 1 point
# at session_started and one frame later. Round 3: the extra presses once. Round 4: a client sends
# a burst of 30 point requests and the host counts only 10 (the rate limit); a sender that is no
# player is refused. Then the host leaves and the others see the menu. Mouse clicks cannot be sent headless: buttons are driven with
# pressed.emit().
# shortcut: round 1 must finish before the late joiner arrives (about 4.5 s after the host); on a slow machine the test fails loudly ("the extra joined before round 2 had a point") instead of passing without testing the late path.

const MENU := "res://tests/feature_scenes/08_rundenablauf_minimal/menu.tscn"
const SETTLE := 1.0   # seconds to let a change reach everyone
const NO_ROUND := "No round yet."
const LATE_VIEW := "round=2 running=1 points=1"


func run(peer: Node) -> void:
	var lobbysmith: Node = peer.get_node("/root/LobbySmith")
	var tree := peer.get_tree()
	var early := {}   # extra: the summary at session_started (deferred) and one frame later
	if peer.role == "extra":
		lobbysmith.session_started.connect(func():
			# Deferred: this handler was connected before the room's own, so wait until all ran.
			(func(): early["at"] = view(lobbysmith)).call_deferred()
			await tree.process_frame
			early["frame"] = view(lobbysmith))
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
	else:
		menu.get_node("%IpEdit").text = "127.0.0.1"
		menu.get_node("%JoinButton").pressed.emit()
	var room: Node = await wait_for_room(peer, lobbysmith, menu)
	if room == null:
		return
	match peer.role:
		"host":
			await run_host(peer, lobbysmith, room)
		"client":
			await run_client(peer, lobbysmith, room, tree)
		"extra":
			await run_extra(peer, lobbysmith, room, tree, early)


func run_host(peer: Node, lobbysmith: Node, room: Node) -> void:
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 30.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	var problem := await wait_texts(peer, room, NO_ROUND, "Points: 0")
	if problem == "":
		problem = buttons_problem(room, true, false, false)
	if problem == "":
		problem = await peer.collect_reports("start", 2, 30.0)
	# Round 1.
	if problem == "":
		press(room, "%StartButton")
		problem = await wait_texts(peer, room, "Round 1 is running.", "Points: 0")
	if problem == "":
		problem = buttons_problem(room, false, true, true)
	if problem == "":
		press(room, "%PointButton", 2)
		problem = await wait_texts(peer, room, "Round 1 is running.", "Points: 6")
	if problem == "":
		problem = await peer.collect_reports("p1", 2, 30.0)
	if problem == "":
		press(room, "%EndButton")
		problem = await wait_texts(peer, room, "Round 1 ended. Points: 6", "Points: 6")
	if problem == "":
		problem = await peer.collect_reports("e1", 2, 30.0)
	if problem == "":
		problem = await settled_report_problem(peer, "e1", room, "round=1 running=0 points=6")
	# Round 2, with the late joiner.
	if problem == "":
		press(room, "%StartButton")
		problem = await wait_texts(peer, room, "Round 2 is running.", "Points: 0")
	if problem == "":
		problem = await peer.collect_reports("r2", 2, 30.0)
	if problem == "" and lobbysmith.get_players().size() != peer.total:
		problem = "the extra joined before round 2 had a point: the late path was not tested"
	if problem == "":
		problem = await settled_report_problem(peer, "r2", room, "round=2 running=1 points=1")
	if problem == "":
		problem = await peer.collect_reports("late", 1, 40.0)
	if problem == "" and lobbysmith.get_players().size() != peer.total + 1:
		problem = "the extra did not join"
	if problem == "":
		press(room, "%EndButton")
		problem = await wait_texts(peer, room, "Round 2 ended. Points: 1", "Points: 1")
	if problem == "":
		problem = await peer.collect_reports("e2", 3, 30.0)
	if problem == "":
		problem = await settled_report_problem(peer, "e2", room, "round=2 running=0 points=1")
	# Round 3: the extra scores.
	if problem == "":
		press(room, "%StartButton")
		problem = await wait_texts(peer, room, "Round 3 is running.", "Points: 1")
	if problem == "":
		press(room, "%EndButton")
		problem = await wait_texts(peer, room, "Round 3 ended. Points: 1", "Points: 1")
	if problem == "":
		problem = await peer.collect_reports("e3", 3, 30.0)
	if problem == "":
		problem = await settled_report_problem(peer, "e3", room, "round=3 running=0 points=1")
	# Round 4: a burst from client 1 is capped at 10 per second.
	if problem == "" and room._may_ask(99999):
		problem = "a sender that is no player may ask"
	if problem == "":
		press(room, "%StartButton")
		problem = await wait_texts(peer, room, "Round 4 is running.", "Points: 0")
	if problem == "":
		problem = await wait_texts(peer, room, "Round 4 is running.", "Points: 10")
	if problem == "":
		await peer.get_tree().create_timer(0.5).timeout   # a late request would show now
		if room.summary() != "round=4 running=1 points=10":
			problem = "after a burst of 30 the host shows '%s', wanted 10 points" % room.summary()
	if problem == "":
		press(room, "%EndButton")
		problem = await wait_texts(peer, room, "Round 4 ended. Points: 10", "Points: 10")
	if problem == "":
		problem = await peer.collect_reports("e4", 3, 30.0)
	if problem == "":
		problem = await settled_report_problem(peer, "e4", room, "round=4 running=0 points=10")
	if problem != "":
		peer.fail_and_quit(problem)
		return
	await peer.get_tree().create_timer(0.5).timeout
	room.get_node("%LeaveButton").pressed.emit()
	await peer.get_tree().create_timer(1.0).timeout
	peer.pass_and_quit()


func run_client(peer: Node, lobbysmith: Node, room: Node, tree: SceneTree) -> void:
	if not await peer.wait_until(func(): return lobbysmith.get_players().size() == peer.total, 30.0):
		peer.fail_and_quit("roster never reached %d" % peer.total)
		return
	var problem := await wait_texts(peer, room, NO_ROUND, "Points: 0")
	if problem == "":
		problem = buttons_problem(room, false, false, false)
	if not await report_phase(peer, "start", problem, view(lobbysmith)):
		return
	# Round 1.
	# No points check yet: the host presses at once, so a client may already see points.
	problem = await wait_texts(peer, room, "Round 1 is running.", "")
	if problem == "":
		problem = buttons_problem(room, false, false, true)
	if problem == "":
		press(room, "%PointButton", 2)
		problem = await wait_texts(peer, room, "Round 1 is running.", "Points: 6")
	if not await report_phase(peer, "p1", problem, view(lobbysmith)):
		return
	problem = await wait_texts(peer, room, "Round 1 ended. Points: 6", "Points: 6")
	if problem == "" and peer.index == 1:
		room._request_point.rpc_id(1)   # the round is over: the host must not count it
	if problem == "":
		await tree.create_timer(SETTLE).timeout
		problem = buttons_problem(room, false, false, false)
	if not await report_phase(peer, "e1", problem, view(lobbysmith)):
		return
	# Round 2.
	# Only client 1 scores in round 2, so only it can be sure to see 0 first. A slow player may
	# get the reset, the start and the point in one frame: it must not wait for the 0.
	# The reset itself is proven by the final 1 (a missed reset would show 7).
	problem = await wait_texts(peer, room, "Round 2 is running.", "Points: 0" if peer.index == 1 else "")
	if problem == "" and peer.index == 1:
		press(room, "%PointButton")
	if problem == "":
		problem = await wait_texts(peer, room, "Round 2 is running.", "Points: 1")
	if not await report_phase(peer, "r2", problem, view(lobbysmith)):
		return
	problem = await wait_texts(peer, room, "Round 2 ended. Points: 1", "Points: 1")
	if not await report_phase(peer, "e2", problem, view(lobbysmith)):
		return
	problem = await wait_texts(peer, room, "Round 3 ended. Points: 1", "Points: 1")
	if not await report_phase(peer, "e3", problem, view(lobbysmith)):
		return
	# Round 4: client 1 sends a burst of 30 requests, the host counts 10.
	problem = await wait_texts(peer, room, "Round 4 is running.", "")
	if problem == "" and peer.index == 1:
		for i in 30:
			room._request_point.rpc_id(1)
	if problem == "":
		problem = await wait_texts(peer, room, "Round 4 ended. Points: 10", "Points: 10")
	if not await report_phase(peer, "e4", problem, view(lobbysmith)):
		return
	if await wait_for_menu(peer, "The host left the session.", tree):
		peer.pass_and_quit()


func run_extra(peer: Node, lobbysmith: Node, room: Node, tree: SceneTree, early: Dictionary) -> void:
	if not await peer.wait_until(func(): return early.has("frame"), 20.0):
		peer.fail_and_quit("extra: no session_started")
		return
	await tree.create_timer(SETTLE).timeout
	room = lobbysmith.get_scene()   # fetched late: the stage may have replaced the first one
	var problem := ""
	for key: String in ["at", "frame"]:
		if problem == "" and early[key] != LATE_VIEW:
			problem = "the extra's view at '%s' is '%s', wanted '%s'" % [key, early[key], LATE_VIEW]
	if problem == "":
		problem = await wait_texts(peer, room, "Round 2 is running.", "Points: 1")
	if problem == "":
		problem = buttons_problem(room, false, false, true)
	if not await report_phase(peer, "late", problem, view(lobbysmith)):
		return
	problem = await wait_texts(peer, room, "Round 2 ended. Points: 1", "Points: 1")
	if not await report_phase(peer, "e2", problem, view(lobbysmith)):
		return
	room = lobbysmith.get_scene()
	problem = await wait_texts(peer, room, "Round 3 is running.", "Points: 0")
	if problem == "":
		press(room, "%PointButton")   # the host ends the round as soon as it sees the point
		problem = await wait_texts(peer, room, "Round 3 ended. Points: 1", "Points: 1")
	if not await report_phase(peer, "e3", problem, view(lobbysmith)):
		return
	problem = await wait_texts(peer, room, "Round 4 ended. Points: 10", "Points: 10")
	if not await report_phase(peer, "e4", problem, view(lobbysmith)):
		return
	if await wait_for_menu(peer, "The host left the session.", tree):
		peer.pass_and_quit()


## What a peer shows right now: the room's summary line.
func view(lobbysmith: Node) -> String:
	var room: Node = lobbysmith.get_scene()
	if room == null or not room.has_method("summary"):
		return "no room"
	return room.summary()


func press(room: Node, path: String, times: int = 1) -> void:
	for i in times:
		room.get_node(path).pressed.emit()


## "" when the three buttons are in the wanted usable (not disabled) state; else the problem.
func buttons_problem(room: Node, start_usable: bool, end_usable: bool, point_usable: bool) -> String:
	var wanted := {"%StartButton": start_usable, "%EndButton": end_usable, "%PointButton": point_usable}
	for path: String in wanted:
		if not room.get_node(path).disabled != wanted[path]:
			return "%s usable: %s, wanted %s" % [path, not room.get_node(path).disabled, wanted[path]]
	return ""


## Waits up to 20 s until the round label and the points label show these texts ("": any points);
## returns "" or the problem.
func wait_texts(peer: Node, room: Node, round_text: String, points_text: String) -> String:
	var room_id := room.get_instance_id()   # a lambda cannot capture a room that is freed meanwhile
	var shown := func():
		var current := instance_from_id(room_id) as Node
		return current != null and current.get_node("%RoundLabel").text == round_text \
				and (points_text == "" or current.get_node("%PointsLabel").text == points_text)
	if not await peer.wait_until(shown, 20.0):
		if not is_instance_valid(room):
			return "the room is gone (session over) while waiting for '%s' / '%s'" % [round_text, points_text]
		return "labels show '%s' / '%s', wanted '%s' / '%s'" % [room.get_node("%RoundLabel").text, room.get_node("%PointsLabel").text, round_text, points_text]
	return ""


## Host: after a short wait, "" when the host's summary and every report of `tag` equal `want`; else the problem.
func settled_report_problem(peer: Node, tag: String, room: Node, want: String) -> String:
	await peer.get_tree().create_timer(0.3).timeout   # the players waited SETTLE s themselves
	var mine: String = room.summary()
	if mine != want:
		return "'%s': the host shows '%s', wanted '%s'" % [tag, mine, want]
	for report: Array in peer.get("_reports")[tag]:
		if report[1] != want:
			return "'%s': a player shows '%s', wanted '%s'" % [tag, report[1], want]
	return ""


## Reports a phase to the host. False (after failing) if the phase had a problem.
func report_phase(peer: Node, tag: String, problem: String, message: String) -> bool:
	peer.report(tag, problem == "", problem if problem != "" else message)
	if problem != "":
		await peer.get_tree().create_timer(0.5).timeout   # the report must arrive before a quit
		peer.fail_and_quit(tag + ": " + problem)
		return false
	return true


## The room for everyone replaces the menu: Core frees the current scene.
func wait_for_room(peer: Node, lobbysmith: Node, menu: Control) -> Node:
	var menu_id := menu.get_instance_id()   # a lambda cannot capture the menu once it is freed
	var shown := func():
		var scene: Node = lobbysmith.get_scene()
		return scene != null and scene.name == "Room" and not is_instance_id_valid(menu_id)
	if not await peer.wait_until(shown, 20.0):
		peer.fail_and_quit("room not shown or menu not freed")
		return null
	return lobbysmith.get_scene()


## Waits until the menu is the current scene with this status text; false (after failing) if not.
func wait_for_menu(peer: Node, text: String, tree: SceneTree) -> bool:
	var there := func():
		var scene := tree.current_scene
		return scene != null and scene.scene_file_path == MENU and scene.get_node("%StatusLabel").text == text
	if not await peer.wait_until(there, 10.0):
		peer.fail_and_quit("no menu with status '%s'" % text)
		return false
	return true
