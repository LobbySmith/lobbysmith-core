extends RefCounted
# Runs the README quickstart (tests/quickstart/quickstart.tscn) in two processes with the
# script's own host() and join(), which use Core's default port. This is the one scenario on a
# fixed port: safe within one run (no other scenario uses it), but two test runs at the same time
# can collide here even with different --base-port values. Both show two names within 10 s; when
# the host leaves, the client's list is empty.

const QUICKSTART := preload("res://tests/quickstart/quickstart.tscn")


func run(peer: Node) -> void:
	var quickstart: Control = QUICKSTART.instantiate()
	# Deferred: the root is still setting up its children while peer.gd runs _ready.
	peer.get_tree().root.add_child.call_deferred(quickstart)
	await peer.get_tree().process_frame
	var players: Label = quickstart.find_child("Players", true, false)
	if players == null:
		peer.fail_and_quit("no node named Players")
		return
	if peer.role == "host":
		quickstart.host()
	else:
		await peer.get_tree().create_timer(1.0).timeout
		quickstart.join()
	if not await peer.wait_until(func(): return lines(players) == 2, 10.0):
		peer.fail_and_quit("expected two lines, got %d: '%s'" % [lines(players), players.text])
		return
	if peer.role == "host":
		peer.broadcast("two")
		var problem: String = await peer.collect_reports("two", 1, 10.0)
		if problem != "":
			peer.fail_and_quit("report: " + problem)
			return
		LobbySmith.leave()
		await peer.get_tree().create_timer(1.0).timeout
		peer.pass_and_quit()
		return
	peer.report("two", true)
	if not await peer.wait_until(func(): return lines(players) == 0, 10.0):
		peer.fail_and_quit("list not empty after the host left: '%s'" % players.text)
		return
	peer.pass_and_quit()


func lines(label: Label) -> int:
	return 0 if label.text == "" else label.text.split("\n").size()
