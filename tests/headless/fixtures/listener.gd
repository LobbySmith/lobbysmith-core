extends Node3D
# Counts LobbySmith.scene_entered. The records live in a static variable so they
# outlive the node: one entry per call, with whether the node was in the tree.

static var calls := []   # [{"id": instance id, "inside": bool}]


func _ready() -> void:
	LobbySmith.scene_entered.connect(_on_entered)


func _on_entered() -> void:
	calls.append({"id": get_instance_id(), "inside": is_inside_tree()})
