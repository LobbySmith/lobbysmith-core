extends Node
## Minimal round flow. Child of LobbySmith. Keeps no state of its own: the round lives in
## LobbySmith.state under KEY as {"n": int, "running": bool}, plus "result" after end(result)
## with a non-null result. Every change of that key is one transition: running emits
## `started`, otherwise `ended`. A late joiner gets the state without signals, and when the
## session ends the state is emptied: get_number() is 0 and nothing is emitted.

const KEY := "lobbysmith:round"

signal started(number: int)
signal ended(number: int, result: Variant)


func _ready() -> void:
	get_parent().state.changed.connect(_on_state_changed)


## Host only. Starts the next round (number = previous + 1).
func start() -> Error:
	if not get_parent().is_host():
		return ERR_UNAUTHORIZED
	if is_running():
		return ERR_BUSY
	return get_parent().state._set_internal(KEY, {"n": get_number() + 1, "running": true})


## Host only. `result` must be null or a value the shared state accepts, otherwise
## ERR_INVALID_PARAMETER and the round keeps running.
func end(result: Variant = null) -> Error:
	if not get_parent().is_host():
		return ERR_UNAUTHORIZED
	if not is_running():
		return ERR_UNAVAILABLE
	var value := {"n": get_number(), "running": false}
	if result != null:
		value["result"] = result
	return get_parent().state._set_internal(KEY, value)


func is_running() -> bool:
	return _round().get("running", false)


## 0 before the first round and without a session.
func get_number() -> int:
	return _round().get("n", 0)


## null while a round runs or when none ended with a result.
func get_result() -> Variant:
	return _round().get("result")


# A value of the wrong shape (not written by this class) counts as "no round".
func _round() -> Dictionary:
	var value: Variant = get_parent().state.get_value(KEY, {})
	if value is Dictionary and typeof(value.get("n")) == TYPE_INT and typeof(value.get("running")) == TYPE_BOOL:
		return value
	return {}


func _on_state_changed(key: String) -> void:
	if key != KEY:
		return
	var current := _round()
	if current.is_empty():
		return
	if current["running"]:
		started.emit(current["n"])
	else:
		ended.emit(current["n"], current.get("result"))
