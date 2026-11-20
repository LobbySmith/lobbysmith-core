extends Control
## Feature scene 01: lobby with room code and LAN.
## Everything here goes through the LobbySmith autoload; there is no network code in this file.

const JOIN_ERROR_TEXT := {
	LobbySmith.JoinError.ROOM_FULL: "Room is full.",
	LobbySmith.JoinError.CODE_UNKNOWN: "No room with this code.",
	LobbySmith.JoinError.STEAM_MISSING: "Steam is not available.",
	LobbySmith.JoinError.TIMEOUT: "Could not reach the host.",
}


func _ready() -> void:
	if not LobbySmith.is_steam_available():
		%Tabs.current_tab = 1
		%SteamInfoLabel.text = "GodotSteam is not installed. LAN works without it."
	%SteamHostButton.pressed.connect(func(): _start("Opening room...", LobbySmith.host_steam))
	%SteamJoinButton.pressed.connect(func():
		_start("Joining...", LobbySmith.join_steam.bind(%SteamCodeEdit.text)))
	%LanHostButton.pressed.connect(func():
		_start("Opening room...", LobbySmith.host_lan.bind(int(%LanPortSpin.value))))
	%LanJoinButton.pressed.connect(func():
		_start("Joining...", LobbySmith.join_lan.bind(%LanIpEdit.text, int(%LanPortSpin.value))))
	%LeaveButton.pressed.connect(LobbySmith.leave)

	LobbySmith.session_started.connect(func():
		_show("Hosting." if LobbySmith.is_host() else "Connected."))
	LobbySmith.session_ended.connect(func(reason: LobbySmith.EndReason):
		_show("The host left the session." if reason == LobbySmith.EndReason.HOST_LEFT
				else "You left the session."))
	LobbySmith.join_failed.connect(func(error: LobbySmith.JoinError): _show(JOIN_ERROR_TEXT[error]))
	LobbySmith.player_joined.connect(func(_id: int): _refresh())
	LobbySmith.player_left.connect(func(_id: int): _refresh())
	_show("Not connected.")


## Sets the waiting text first: hosting on LAN finishes inside the call.
func _start(waiting_text: String, action: Callable) -> void:
	LobbySmith.local_name = %NameEdit.text
	_show(waiting_text)
	var error: Error = action.call()
	if error != OK:
		_show("Could not start: %s." % error_string(error))


func _show(status: String) -> void:
	%StatusLabel.text = status
	_refresh()


func _refresh() -> void:
	var active := LobbySmith.is_active()
	%LeaveButton.disabled = not active
	for button: Button in [%SteamHostButton, %SteamJoinButton, %LanHostButton, %LanJoinButton]:
		button.disabled = active
	%RoomCodeLabel.text = LobbySmith.get_room_code()
	%PlayerList.clear()
	var players := LobbySmith.get_players()
	var ids := players.keys()
	ids.sort()   # the host is always id 1, so it comes first
	for id: int in ids:
		%PlayerList.add_item(players[id]["name"] + (" (host)" if id == 1 else ""))
