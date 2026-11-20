extends Node3D
## Feature scene 03: two rooms, A and B. The host changes between them; a list
## shows who already has the current room. Both rooms use this script.

const Menu := preload("../common/lan_menu.gd")

@export var title: String
@export var other_room: String


func _ready() -> void:
	%TitleLabel.text = title
	%StatusLabel.text = "Loading..."
	%GoButton.disabled = true   # opens on scene_entered, host only
	%GoButton.pressed.connect(_go)
	%LeaveButton.pressed.connect(LobbySmith.leave)
	LobbySmith.scene_entered.connect(_entered)
	LobbySmith.ready_changed.connect(func(_id: int): _show_players())
	LobbySmith.player_joined.connect(func(_id: int): _show_players())
	LobbySmith.player_left.connect(func(_id: int): _show_players())
	LobbySmith.state.changed.connect(func(_key: String): _show_changes())
	# A late joiner may get the player list and the state after this scene.
	LobbySmith.session_started.connect(func():
		_show_players()
		_show_changes())
	LobbySmith.session_ended.connect(func(reason: LobbySmith.EndReason):
		Menu.return_to_menu(LobbySmith.get_tree(), reason))   # this room is already off the tree
	_show_players()
	_show_changes()


## Runs when the room is in place for this player.
func _entered() -> void:
	%StatusLabel.text = "Everyone is here."
	%GoButton.disabled = not LobbySmith.is_host()


func _go() -> void:
	if LobbySmith.is_changing_scene():
		return
	%GoButton.disabled = true   # the next room opens it again on scene_entered
	# Count first: the next room reads the counter in its _ready.
	LobbySmith.state.set_value("changes", LobbySmith.state.get_value("changes", 0) + 1)
	LobbySmith.change_scene(other_room)


func _show_players() -> void:
	%ReadyList.clear()
	var players := LobbySmith.get_players()
	var ids := players.keys()
	ids.sort()
	for id: int in ids:
		var player: Dictionary = players[id]
		%ReadyList.add_item("%s: %s" % [player["name"], "ready" if player["ready"] else "loading"])


func _show_changes() -> void:
	%ChangesLabel.text = "Scene changes: %d" % LobbySmith.state.get_value("changes", 0)
