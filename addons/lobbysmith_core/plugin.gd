@tool
extends EditorPlugin


func _enable_plugin() -> void:
	add_autoload_singleton("LobbySmith", "res://addons/lobbysmith_core/lobbysmith.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton("LobbySmith")
