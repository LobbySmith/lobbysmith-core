extends Control
## Shared start screen of the feature scenes: host or join over LAN. Once the
## session runs, Core shows room_scene for everyone (and frees this screen).
## A scene makes its own menu by instancing lan_menu.tscn and setting the two
## exports.

const JOIN_ERROR_TEXT := {
	LobbySmith.JoinError.ROOM_FULL: "Room is full.",
	LobbySmith.JoinError.TIMEOUT: "Could not reach the host.",
}

## The room every player sees once the session runs.
@export var room_scene: String
## What the scene shows and which files to read.
@export_multiline var header: String

## The menu that opened the session, and the text for the next menu that opens
## (the room sets the text before it leaves).
static var _menu_path := ""
static var _notice := ""


## Called by the room when the session is over: back to the menu we came from.
static func return_to_menu(tree: SceneTree, reason: LobbySmith.EndReason) -> void:
	if _menu_path == "":
		return
	_notice = "The host left the session." if reason == LobbySmith.EndReason.HOST_LEFT else ""
	tree.change_scene_to_file(_menu_path)


func _ready() -> void:
	%HeaderLabel.text = header
	%HostButton.pressed.connect(_host)
	%JoinButton.pressed.connect(_join)
	LobbySmith.join_failed.connect(func(error: LobbySmith.JoinError):
		%StatusLabel.text = JOIN_ERROR_TEXT.get(error, "Could not join.")
		_set_buttons_disabled(false))
	%StatusLabel.text = _notice if _notice != "" else "Not connected."
	_notice = ""


func _host() -> void:
	_menu_path = scene_file_path
	var error := LobbySmith.host_lan(int(%PortSpin.value))
	if error != OK:
		%StatusLabel.text = "Could not start: %s." % error_string(error)
		return
	error = LobbySmith.change_scene(room_scene)
	if error != OK:
		LobbySmith.leave()   # hosting worked but the room did not: do not stay half open
		%StatusLabel.text = "Could not start: %s." % error_string(error)


func _join() -> void:
	_menu_path = scene_file_path
	%StatusLabel.text = "Joining..."
	_set_buttons_disabled(true)   # until the room appears or the join fails
	var error := LobbySmith.join_lan(%IpEdit.text, int(%PortSpin.value))
	if error != OK:
		%StatusLabel.text = "Could not start: %s." % error_string(error)
		_set_buttons_disabled(false)


func _set_buttons_disabled(disabled: bool) -> void:
	%HostButton.disabled = disabled
	%JoinButton.disabled = disabled
