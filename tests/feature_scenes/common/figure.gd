extends Node3D
## A player's figure. Its owner moves it (WASD); the synchronizer (set up in
## figure.tscn) belongs to the owner and copies the position to everyone else.
##
## The position belongs to the owning client, so every other peer treats it as untrusted input.
## The synchronizer sends `net_position` (not `position`): its setter is the one place that can
## refuse a value, which a synchronizer writing `position` directly cannot be stopped from.
## Checked: the value is finite and no coordinate is beyond MAX_COORD; anything else is ignored
## and the figure stays where it was. NOT checked: speed (a client can still jump anywhere inside
## the bound), walls, height, or who stands where. For that, move the figure on the host and let
## clients send only their input.

const SPEED := 4.0
## A coordinate beyond this (in metres) is refused. Sample value: set it to the size of your
## largest room; a figure beyond it stays at its last good position.
const MAX_COORD := 1000.0

var owner_id := 1

## What the synchronizer reads on the owner and writes on everyone else.
var net_position: Vector3:
	get:
		return position
	set(value):
		if value.is_finite() and maxf(absf(value.x), maxf(absf(value.y), absf(value.z))) <= MAX_COORD:
			position = value


func _enter_tree() -> void:
	$Sync.set_multiplayer_authority(owner_id)


func _process(delta: float) -> void:
	if not _is_mine():
		return
	var direction := Vector3(
			int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A)), 0,
			int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W)))
	position += direction.normalized() * SPEED * delta


## Puts the own figure somewhere (used by the tests; there is no real input headless).
func move_to(target: Vector3) -> void:
	if _is_mine():
		position = target


func _is_mine() -> bool:
	return multiplayer.get_unique_id() == owner_id
