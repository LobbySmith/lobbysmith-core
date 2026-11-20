extends RefCounted
# Drives feature scene 01 through its buttons: host, join, player list, host leaves.

const LOBBY := "res://tests/feature_scenes/01_lobby_raumcode_lan/lobby.tscn"


func run(peer: Node) -> void:
	var lobby: Control = load(LOBBY).instantiate()
	peer.add_child(lobby)
	var status: Label = lobby.get_node("%StatusLabel")
	var list: ItemList = lobby.get_node("%PlayerList")
	if status.text != "Not connected.":
		peer.fail_and_quit("start status '%s'" % status.text)
		return
	lobby.get_node("%LanPortSpin").value = peer.port
	if peer.role == "host":
		lobby.get_node("%NameEdit").text = "Hosty"
		lobby.get_node("%LanHostButton").pressed.emit()
		if status.text != "Hosting.":
			peer.fail_and_quit("host status '%s'" % status.text)
			return
		if not await peer.wait_until(func(): return list.item_count == 2, 20.0):
			peer.fail_and_quit("host list never showed 2 players")
			return
		peer.broadcast("listed")
		var problem: String = await peer.collect_reports("listed", 1, 10.0)
		var host_marks := 0
		for i in list.item_count:
			if list.get_item_text(i).ends_with(" (host)"):
				host_marks += 1
		if problem == "" and host_marks != 1:
			problem = "%d entries marked as host" % host_marks
		if problem == "" and list.get_item_text(0) != "Hosty (host)":
			problem = "first entry is '%s'" % list.get_item_text(0)
		if problem != "":
			peer.fail_and_quit(problem)
			return
		lobby.get_node("%LeaveButton").pressed.emit()
		if status.text != "You left the session." or list.item_count != 0:
			peer.fail_and_quit("after leave: '%s', %d entries" % [status.text, list.item_count])
			return
		await peer.get_tree().create_timer(1.0).timeout
		peer.pass_and_quit()
	else:
		lobby.get_node("%LanIpEdit").text = "127.0.0.1"
		lobby.get_node("%LanJoinButton").pressed.emit()
		if status.text != "Joining...":
			peer.fail_and_quit("client status after pressing join '%s'" % status.text)
			return
		if not await peer.wait_until(func(): return status.text == "Connected.", 15.0):
			peer.fail_and_quit("client status never 'Connected.', is '%s'" % status.text)
			return
		if not await peer.wait_checkpoint("listed", 20.0):
			peer.fail_and_quit("no listed checkpoint")
			return
		peer.report("listed", list.item_count == 2, "client list shows %d" % list.item_count)
		if not await peer.wait_until(func(): return status.text == "The host left the session.", 15.0):
			peer.fail_and_quit("client status after host left '%s'" % status.text)
			return
		if list.item_count != 0:
			peer.fail_and_quit("client list not empty after host left")
			return
		peer.pass_and_quit()
