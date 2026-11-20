extends Node
## Shared state: a small dictionary only the host changes. Child of LobbySmith.
## Everyone reads it; every change arrives on everyone as a `changed` signal.

signal changed(key: String)

var _values := {}


## Keys that start with this belong to Core (for example the round of `LobbySmith.rounds`).
const RESERVED_PREFIX := "lobbysmith:"


## Host only. Values: bool, int, float, String, and Array/Dictionary of those
## (dictionary keys must be String). Keys that start with "lobbysmith:" are reserved for
## Core: ERR_INVALID_PARAMETER.
func set_value(key: String, value: Variant) -> Error:
	if not get_parent().is_host():
		return ERR_UNAUTHORIZED
	if key.begins_with(RESERVED_PREFIX):
		return ERR_INVALID_PARAMETER
	return _set_internal(key, value)


## Core's own write path (rounds.gd): same as set_value, but reserved keys are allowed.
func _set_internal(key: String, value: Variant) -> Error:
	if not get_parent().is_host():
		return ERR_UNAUTHORIZED
	if not _is_valid(value):
		return ERR_INVALID_PARAMETER
	_values[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	# Only to peers that have a roster: a connection that never registered hears nothing.
	for id in get_parent()._others(1):
		_apply.rpc_id(id, key, value)
	changed.emit(key)
	return OK


func get_value(key: String, default: Variant = null) -> Variant:
	if not _values.has(key):
		return default
	var value: Variant = _values[key]
	return value.duplicate(true) if value is Array or value is Dictionary else value


func has(key: String) -> bool:
	return _values.has(key)


## A copy; changing it changes nothing.
func get_all() -> Dictionary:
	return _values.duplicate(true)


## Replaces everything without signals (used when the full state is sent to a new player).
func _replace(values: Dictionary) -> void:
	_values = values.duplicate(true)


func _clear() -> void:
	_values = {}


func _is_valid(value: Variant) -> bool:
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return true
		TYPE_ARRAY:
			for item in value:
				if not _is_valid(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if typeof(key) != TYPE_STRING or not _is_valid(value[key]):
					return false
			return true
	return false


@rpc("authority", "call_remote", "reliable")
func _apply(key: String, value: Variant) -> void:
	var lobbysmith := get_parent()
	if not _is_valid(value) or not (lobbysmith._active or lobbysmith._joining):
		return   # not part of a session
	_values[key] = value
	# A joiner still waiting for the scene keeps the value but hears no signal, like a late joiner.
	if lobbysmith._active:
		changed.emit(key)
