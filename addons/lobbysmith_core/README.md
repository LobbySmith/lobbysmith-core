# LobbySmith Core

LobbySmith Core is a small co-op framework for Godot 4.7: host or join a session over LAN or a Steam lobby, share a player list, a small shared state, one scene for everyone and a minimal round flow, all with GDScript only. It needs the standard Godot 4.7 build, no custom engine and no online service. GodotSteam is optional and is not included.

Paid building blocks (proximity voice, carrying, an example game) are planned as "LobbySmith Pro". Core stays free and MIT licensed.

## Your first two-player run in five minutes

1. Copy the folder `addons/lobbysmith_core` into your project's `addons/` folder.
2. Enable the plugin under Project > Project Settings > Plugins. This adds the autoload `LobbySmith`.
3. Create a new scene with a `Control` as its root node and attach a new script with this text:

```gdscript
extends Control

var players := Label.new()


func _ready() -> void:
	var box := VBoxContainer.new()
	add_child(box)
	var hint := Label.new()
	hint.text = "H: host    J: join 127.0.0.1"
	box.add_child(hint)
	players.name = "Players"
	box.add_child(players)
	LobbySmith.session_started.connect(refresh)
	LobbySmith.player_joined.connect(refresh.unbind(1))
	LobbySmith.player_left.connect(refresh.unbind(1))
	LobbySmith.session_ended.connect(refresh.unbind(1))


func host() -> void:
	LobbySmith.host_lan()


func join(ip: String = "127.0.0.1") -> void:
	LobbySmith.join_lan(ip)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key.pressed and not key.echo:
		match key.keycode:
			KEY_H: host()
			KEY_J: join()


func refresh() -> void:
	var names := PackedStringArray()
	for player in LobbySmith.get_players().values():
		names.append(player["name"])
	players.text = "\n".join(names)
```

4. Save the scene. Set the Debug menu's Customize Run Instances to 2 instances. Then run the scene with Run Current Scene (F6), or set it as the main scene first and use Run Project (F5).
5. In one window press H (host), in the other press J (join). Both windows now list two names. The two windows can open exactly on top of each other; drag one aside.

The same script lives in this repository as `tests/quickstart/quickstart.gd`, and an automatic test runs it with two processes.

## API

Everything is on the autoload `LobbySmith`. Players are identified by a peer id; the host always has id 1.

### Session

| Member | Returns | What it does |
| --- | --- | --- |
| `host_lan(port := DEFAULT_PORT)` | `Error` | Starts a LAN server and emits `session_started`. Returns `ERR_ALREADY_IN_USE` if you are already in a session or joining, or the engine's error if the server cannot start (for example the port is taken). |
| `join_lan(ip, port := DEFAULT_PORT)` | `Error` | Starts joining; the result arrives as `session_started` or `join_failed`. Returns `ERR_ALREADY_IN_USE` if you are already in a session or joining, or the engine's error if the client cannot start. |
| `host_steam()` | `Error` | Opens a Steam lobby with a room code; `OK` means started, the result arrives as `session_started` or `join_failed`. The only error returned is `ERR_ALREADY_IN_USE`; missing GodotSteam comes as `join_failed(STEAM_MISSING)`. |
| `join_steam(code)` | `Error` | Joins the Steam lobby with this room code. Typed or pasted input like `ab-c 2x3` is fine: case, spaces (also non-breaking), tabs, line breaks, hyphens, en dashes and em dashes are ignored. `OK` means started. The only error returned is `ERR_ALREADY_IN_USE`; missing GodotSteam or an unknown code come as `join_failed`. |
| `is_steam_available()` | `bool` | True when GodotSteam is loaded. |
| `leave()` | `void` | Leaves the session or cancels a join attempt. |
| `is_active()` | `bool` | True while you are in a session. |
| `is_host()` | `bool` | True if you are in a session and its host. |
| `get_room_code()` | `String` | The Steam room code, empty on LAN. |
| `get_players()` | `Dictionary` | `id -> {"name": String, "ready": bool}`, a copy. Names are cleaned by the host (control, zero-width and bidirectional characters removed, trimmed, at most 24 characters; a name that stays empty becomes `Player N`). Zero-width joiners (U+200C, U+200D) are stripped too, which alters some Persian and Indic names and emoji sequences. Names are not unique and not identities: two players can have the same name. The peer id is the identity, use it as the key. |

### Scenes

| Member | Returns | What it does |
| --- | --- | --- |
| `change_scene(path)` | `Error` | Host only: shows this scene to everyone, including late joiners. `OK` means started. Errors: `ERR_UNAVAILABLE` without a session, `ERR_UNAUTHORIZED` if you are not the host, `ERR_BUSY` while a change is running, `ERR_FILE_NOT_FOUND` if the path is not a scene or does not start with `res://` or contains `..`, `./` or a doubled slash (`//`). Clients only load `res://` scenes, so a scene in `user://` is refused. |
| `is_changing_scene()` | `bool` | True from `change_scene` until everyone has the scene or `scene_timeout` passed. |
| `get_scene()` | `Node` | The scene on the stage, or null. |

### Signals

| Signal | What it tells you |
| --- | --- |
| `session_started()` | Host: after hosting. Client: after receiving the player list. |
| `session_ended(reason: EndReason)` | The session is over. |
| `join_failed(error: JoinError)` | A join or host attempt failed. |
| `player_joined(id: int)` | A player joined; emitted on everyone who was already there. |
| `player_left(id: int)` | A player left. |
| `scene_entered()` | The current scene is in place for everyone (or `scene_timeout` passed). Start the game here. |
| `ready_changed(id: int)` | A player's `ready` flag changed. |

### Enums

| Enum | Values |
| --- | --- |
| `EndReason` | `LEFT`, `HOST_LEFT` |
| `JoinError` | `ROOM_FULL`, `CODE_UNKNOWN`, `STEAM_MISSING`, `TIMEOUT` |

### Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `max_players` | `8` | Seats in a session. |
| `join_timeout` | `15.0` | Seconds a join attempt may take. |
| `scene_timeout` | `15.0` | Seconds a scene change waits for players who have not reported the scene. |
| `steam_app_id` | `480` | Valve's test app; use your own for a released game. |
| `local_name` | `""` | Name shown to others. Empty: the Steam name on Steam, "Player N" on LAN. |
| `DEFAULT_PORT` | `24565` | Default LAN port (constant). |

### Shared state: `LobbySmith.state`

A small dictionary only the host changes. Values are bool, int, float, String, and Array or Dictionary of those (dictionary keys must be String). Keys that start with `lobbysmith:` are reserved for Core (`LobbySmith.rounds` keeps its round under `lobbysmith:round`): `set_value` refuses them.

| Member | Returns | What it does |
| --- | --- | --- |
| `set_value(key, value)` | `Error` | Host only: sets a value for everyone. Errors: `ERR_UNAUTHORIZED` if you are not the host (including without a session), `ERR_INVALID_PARAMETER` for a value the state does not accept or a key that starts with `lobbysmith:`. |
| `get_value(key, default := null)` | `Variant` | Reads a value. |
| `has(key)` | `bool` | True if the key is set. |
| `get_all()` | `Dictionary` | A copy of everything. |
| `changed(key: String)` | signal | A value changed, on everyone. |

### Rounds: `LobbySmith.rounds`

A minimal round flow, kept in `LobbySmith.state`.

| Member | Returns | What it does |
| --- | --- | --- |
| `start()` | `Error` | Host only: starts the next round. Errors: `ERR_UNAUTHORIZED` if you are not the host (including without a session), `ERR_BUSY` while a round runs. |
| `end(result := null)` | `Error` | Host only: ends the running round with an optional result. Errors: `ERR_UNAUTHORIZED` if you are not the host (including without a session), `ERR_UNAVAILABLE` if no round runs, `ERR_INVALID_PARAMETER` for a result the state does not accept (the round keeps running). |
| `is_running()` | `bool` | True while a round runs. |
| `get_number()` | `int` | The round number; 0 before the first round and without a session. |
| `get_result()` | `Variant` | null while a round runs or when none ended with a result. |
| `started(number: int)` | signal | A round started. |
| `ended(number: int, result: Variant)` | signal | A round ended. |

## Silent connections

On LAN (ENet) the host keeps at most two connections per address that are still no player after one second (`MAX_SILENT_PER_ADDRESS`, `SILENT_GRACE`) and drops the oldest ones beyond that, so one machine that opens connections and never registers does not hold every seat. This is best effort: a continuous fast flood can still keep free seats blocked, it does not apply to Steam, and three or more honest players joining at the same moment from one address over a slow link (registration taking longer than about a second) can be dropped and must retry. Connections that never register are dropped after `join_timeout` in any case.

Core switches ENet's packet throttle off on LAN connections (`THROTTLE_*` in `lobbysmith.gd`): under congestion an unreliable packet arrives late instead of being dropped.

## Steam

Steam is optional. Put GodotSteam (a GDExtension) into `addons/godotsteam/` yourself; LobbySmith does not ship it. Start Steam, then call `LobbySmith.host_steam()` on one machine and `LobbySmith.join_steam(code)` with the room code from `LobbySmith.get_room_code()` on the others. Without GodotSteam both report `JoinError.STEAM_MISSING`.

`steam_app_id` defaults to 480, Valve's test app. That is for testing only; set your own app id for a released game.

The lobby is public and the room code is only a search filter: it is not a password. Anyone who finds the lobby can try to join until the seats are full, and Core has no password or kick (see `SECURITY.md`).

## Tests

From the project root:

```
godot --headless --path . -s tests/headless/run_all.gd
godot --headless --path . -s tests/headless/run_all.gd -- <name>
```

The first line runs everything, the second one scenario or unit test. A run passes when the last line is `ALL PASS` and the exit code is 0; a log line containing `ERROR` or `WARNING` fails it. Each scenario starts one Godot process per player on the same machine. The runs cover up to 8 players (1 host and 7 clients), all over LAN. Hosting and joining a Steam lobby by room code, a late joiner and a scene change were checked with two Steam accounts. Run one test at a time: the ports are fixed.

## Not checked

- Steam: hosting, joining by room code, a late joiner and a scene change were checked with two Steam accounts on two machines (macOS and Linux, both directions, one run each, with a check scene). Not checked: more than two accounts, bad connections, rounds over Steam. The lobby state machine (`transport_steam.gd`) is tested in the automatic run only against a fake Steam object (`test_steam_transport`); nothing automatic ran against real Steam, and the `SteamMultiplayerPeer` is not tested in the automatic run. Open edge: a reply to a cancelled search or lobby creation that arrives after a new attempt started is taken as the new attempt's (Steam gives these replies no id; a late reply to a cancelled join is matched by lobby id and left).
- Linux: the automatic suite ran once on Linux (in a container) and passed. Windows: not checked.
- The quickstart test calls `host()` and `join()` directly; it never presses the H and J keys.
- Real mouse clicks on the buttons of the test scenes are not covered by the automatic runs (the tests trigger the buttons by signal); they are checked by hand.
- Real network latency: all automatic runs are LAN on one machine.
- The five-minute quickstart is estimated at 3 to 4.5 minutes for someone who knows the editor; it was not timed with a stopwatch.
- The three editor menu names in quickstart step 4 appear as text in the Godot 4.7.2 program; they were not clicked in the editor.

## How this is built

Most of this code was written by AI agents. A human reviews it, plays each test scene by hand before a release and decides what ships. The tests are in this repository; run them yourself.

## License

MIT. See `LICENSE`.
