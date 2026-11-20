extends Control

var players := Label.new()


func _ready() -> void:
	var box := VBoxContainer.new()
	add_child(box)
	var hint := Label.new()
	hint.text = "H: host    J: join 127.0.0.1"
	box.add_child(hint)
	players.name = "Players"
	box.add_child(players)
	LobbySmith.session_started.connect(refresh)
	LobbySmith.player_joined.connect(refresh.unbind(1))
	LobbySmith.player_left.connect(refresh.unbind(1))
	LobbySmith.session_ended.connect(refresh.unbind(1))


func host() -> void:
	LobbySmith.host_lan()


func join(ip: String = "127.0.0.1") -> void:
	LobbySmith.join_lan(ip)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key.pressed and not key.echo:
		match key.keycode:
			KEY_H: host()
			KEY_J: join()


func refresh() -> void:
	var names := PackedStringArray()
	for player in LobbySmith.get_players().values():
		names.append(player["name"])
	players.text = "\n".join(names)
