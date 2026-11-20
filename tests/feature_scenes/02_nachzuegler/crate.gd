extends StaticBody3D
## A crate that changes colour when clicked. The host owns the colour and the
## synchronizer (set up in crate.tscn) copies it to everyone, late joiners too.

const COLORS := [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW]
## Host: at most this many requests from one player in RATE_WINDOW_MS.
const RATE_LIMIT := 10
const RATE_WINDOW_MS := 1000

var color_index := 0:
	set(value):
		color_index = value
		_material.albedo_color = COLORS[value]

var _material := StandardMaterial3D.new()
var _rate := {}   # host: sender id -> [window start (ms), requests in it]


func _ready() -> void:
	$Mesh.material_override = _material
	LobbySmith.player_left.connect(func(id: int): _rate.erase(id))   # a player who left keeps no entry
	_material.albedo_color = COLORS[color_index]


func _input_event(_camera: Camera3D, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		request_cycle()


## Anyone may ask; only the host changes the colour.
func request_cycle() -> void:
	_cycle.rpc_id(1)


## Any peer may call this, so the host checks who asks and how often before it changes anything.
@rpc("any_peer", "call_local", "reliable")
func _cycle() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()   # the host's own call_local call
	if multiplayer.is_server() and _allowed(sender):
		color_index = (color_index + 1) % COLORS.size()


## Host: true for a player who has not asked too often.
func _allowed(sender: int) -> bool:
	if not LobbySmith.get_players().has(sender):
		return false
	# shortcut: fixed one-second window per sender and per crate, no cap across crates; add a
	# global cap per sender if strangers can join.
	var now := Time.get_ticks_msec()
	var slot: Array = _rate.get(sender, [now, 0])
	if now - int(slot[0]) >= RATE_WINDOW_MS:
		slot = [now, 0]
	slot[1] += 1
	_rate[sender] = slot
	return slot[1] <= RATE_LIMIT
