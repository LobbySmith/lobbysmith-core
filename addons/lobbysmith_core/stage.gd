extends Node
## The stage: one scene that everyone in the session sees. Child of LobbySmith.
## The host shows a scene; a MultiplayerSpawner copies it to every player,
## including players who join later.

## A scene arrived on the stage. LobbySmith decides what that means for the
## project's own scene.
signal scene_arrived()

const SERIAL_META := "lobbysmith_serial"

var spawner: MultiplayerSpawner
var _serial := 0   # host only: number of the scene shown last


func _ready() -> void:
	child_entered_tree.connect(_on_child_entered)


## Host only. Replaces the scene that is shown now and returns its number.
## The number travels in the spawn data, so every peer can tell which scene it has.
func show_scene(path: String) -> int:
	clear()
	_serial += 1
	spawner.spawn({"path": path, "serial": _serial})
	return _serial


## True for a path a scene may be loaded from: only the game's own res:// files (no ".."), never a
## file in user:// (mods, downloads) or anything else.
static func is_scene_path(path: Variant) -> bool:
	if typeof(path) != TYPE_STRING or not path.begins_with("res://"):
		return false
	# No "..", "." or doubled slashes: in a project that is not exported, res:// is the folder on disk.
	if path.contains("..") or path.simplify_path() != path:
		return false
	# The type hint of exists() does not filter (a .gd file passes), so check the loaded type too.
	return ResourceLoader.exists(path, "PackedScene") and load(path) is PackedScene


## The spawner's spawn_function, on every peer. The host's data is not trusted blindly:
## anything but a clean res:// scene path gives null (the spawner drops it and the engine may log an error line for it; not verified on a client).
func make_scene(data: Dictionary) -> Node:
	if not is_scene_path(data.get("path")) or typeof(data.get("serial")) != TYPE_INT:
		return null
	var scene: Node = load(data["path"]).instantiate()
	scene.set_meta(SERIAL_META, data["serial"])
	return scene


## Number of the scene on this peer's stage, 0 when it is empty.
func get_serial() -> int:
	var scene := get_scene()
	return scene.get_meta(SERIAL_META, 0) if scene != null else 0


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


## The newest scene, or null when the stage is empty. An old scene that is
## still a child for a moment (queued for deletion) does not count.
func get_scene() -> Node:
	for i in range(get_child_count() - 1, -1, -1):
		var child := get_child(i)
		if not child.is_queued_for_deletion():
			return child
	return null


func _on_child_entered(_child: Node) -> void:
	scene_arrived.emit()
