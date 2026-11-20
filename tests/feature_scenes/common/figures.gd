extends Node3D
## One figure per player, shared by the feature scenes. Put this on the node that holds
## the figures; a MultiplayerSpawner next to it (spawn path to this node) is `spawner`.
## The host spawns a figure for every player, also late joiners, and removes it when the
## player leaves. A figure's node name is its player's id.

## The figure to spawn. It needs a settable `owner_id`.
@export var figure_scene: PackedScene
@export var spawner: MultiplayerSpawner

var _slots := {}   # host only: player id -> where the figure stands


func _ready() -> void:
	spawner.spawn_function = _make_figure
	if LobbySmith.is_host():
		_add_present_players.call_deferred()   # the spawner finds its spawn node in its own _ready, which runs after ours
		LobbySmith.player_joined.connect(_add_figure)
		LobbySmith.player_left.connect(_remove_figure)


## The figure of a player, or null.
func figure_of(id: int) -> Node3D:
	return get_node_or_null(str(id))


## The ids of all figures, sorted.
func ids() -> Array:
	var result := []
	for figure in get_children():
		result.append(figure.name.to_int())
	result.sort()
	return result


func _add_present_players() -> void:
	for id: int in LobbySmith.get_players().keys():
		_add_figure(id)


func _add_figure(id: int) -> void:
	if figure_of(id) == null:
		var slot := 0
		while _slots.values().has(slot):   # the lowest free place
			slot += 1
		_slots[id] = slot
		spawner.spawn({"id": id, "slot": slot})


func _remove_figure(id: int) -> void:
	_slots.erase(id)
	var figure := figure_of(id)
	if figure:
		figure.queue_free()


## Runs on every player when the host spawns a figure.
func _make_figure(data: Dictionary) -> Node:
	var figure := figure_scene.instantiate()
	figure.name = str(data["id"])
	figure.owner_id = data["id"]
	figure.position = Vector3(2.0 * data["slot"] - 7.0, 0, 0)
	return figure
