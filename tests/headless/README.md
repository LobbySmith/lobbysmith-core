# Automatic run without a window

One Godot process starts one more Godot process per player over ENet on the same
machine, and evaluates their exit codes and logs.

```
godot --headless --path . -s tests/headless/run_all.gd            # everything
godot --headless --path . -s tests/headless/run_all.gd -- lobby_4 # one scenario or unit test
godot --headless --path . -s tests/headless/run_all.gd -- --jobs=4 --base-port=26000
```

The runner starts several scenarios at the same time. It has a budget of peer processes: a scenario costs
clients + 1 (the host) + extras, a unit test costs 1. A new scenario starts as soon as its price fits into the
free budget; a scenario that alone costs more than the whole budget runs alone. Switches after `--`:

- `--jobs=<n>`: size of the budget (default: number of cores). `--jobs=1` starts one scenario after the
  other. That is not the order of the list: entries that need only one process can come before
  earlier scenarios that need several processes.
- `--base-port=<n>` (default 24600, allowed 1024 to 60000): the scenario at position `i` of the list uses
  port `n + 10 * i`. With a value other than 24600 the logs are under
  `user://headless_logs_<n>`. Two runs with different base ports may run at the same time; with the same
  base port they may not. Exception: `quickstart` uses the fixed default port of the guide (24565), not the
  base port. Two runs at the same time can therefore meet at this port, even with different base
  ports.
- a name: only this scenario or this unit test.

The lines `PASS`, `FAIL` and `SKIP` appear in the order in which the scenarios finish,
not in the order of the list. Before the last line come `TIME total <s> s` and up to five lines
`TIME <name> <s> s` (the longest first).

Passed means: every process ends with exit code 0, and no log contains a line
with `ERROR` or `WARNING`. The last line is `ALL PASS` or `FAILED: <n>`.
Logs are under `user://headless_logs/`.

## New scenario

1. Create `scenarios/<name>.gd`: `extends RefCounted` with `func run(peer: Node) -> void`.
   `peer` (see `peer.gd`) knows `role`, `index`, `total`, `port` and `part` and offers
   `wait_until`, `broadcast`, `wait_checkpoint`, `report`, `collect_reports`,
   `pass_and_quit`, `fail_and_quit`.
2. Add it to `SCENARIOS` in `run_all.gd` (number of clients and extras, time limit).

An entry of the list may carry `"script": "res://…/<name>.gd"`; then `peer.gd` loads that file instead of `scenarios/<name>.gd`.

An entry may also carry `"part": "<part>"`. Then every peer of the scenario gets `--part=<part>`, and the
script reads it as `peer.part` (empty if the entry has no `part`). This lets a long scenario
be split over several entries with the same script, which then run side by side. `name` stays the label
in the result lines and the logs; what `part` means is up to the script.

The runner here lists only the Core scenarios and unit tests. This copy runs the Core list of scenarios.

## Scenarios

| Name | What it checks |
| --- | --- |
| `stage_guards` | One process: without a session `ERR_UNAVAILABLE`; missing file and non-scene `ERR_FILE_NOT_FOUND`; only `res://`: a real scene in `user://` and a `uid://` path give `ERR_FILE_NOT_FOUND`, and so do paths with `..` or `.`; the clients' spawn function (`make_scene`) gives `null` for them, for non-scenes and for data without a path or number, without an error line; a scene replaces the previous one; after `leave` the stage is empty; for a host alone `scene_entered` comes in the next frame (never inside the call), the old scene no longer hears it, two changes in one frame give one `scene_entered` |
| `stage_basic` | The host changes the scene, all players show the same scene; `change_scene` as a client gives `ERR_UNAUTHORIZED` |
| `state_basic` | `LobbySmith.state`: only the host changes it, everyone sees it, signal `changed`, clearing at the end |
| `rounds_basic` | Host and 3 clients: `LobbySmith.rounds` lives in the `state`; only the host starts and ends (`ERR_UNAUTHORIZED`, `ERR_BUSY`, `ERR_UNAVAILABLE`, invalid result `ERR_INVALID_PARAMETER`; keys with `lobbysmith:` are reserved for Core, `state.set_value` gives `ERR_INVALID_PARAMETER` for them); three rounds with a result, every peer hears `started` and `ended` exactly once per round, a scene change in the middle of round 2 does not end it; a malformed value under the round key (writable only through the host's internal path) counts as "no round" for all peers, without an error and without a signal; afterwards the host writes a valid running round (number 1) again through `start()` and all clients see it running; if the host then leaves, the round is gone on the clients (not running, number 0), without another `ended` |
| `rounds_late` | Host, 1 client and 1 late joiner while round 2 runs: number, running flag and result are right from `session_started`, no `started`; afterwards the late joiner hears `ended` with the result |
| `late_join` | A late joiner during a running scene gets the player list, state and scene, then the signals |
| `late_join_8` | like `late_join`, up to the maximum of 8, the ninth player is turned away |
| `join_stale` | Host (`max_players` 2, `join_timeout` 2 s), 1 client and 1 extra: the host disconnects a connection that never registers, and a joiner that never reports "scene is up"; the seats are free afterwards; an admitted player is never disconnected by the timer |
| `names` | Host and 3 clients: names are stripped of control characters (code below 32 and 127), zero-width and bidi characters, trimmed and cut to 24 characters, duplicates are allowed (the name is not an identity, the peer id is); `"\tEve\nX\u007f "` with zero-width, bidi and line-separator characters in between becomes `EveX`; a name made only of invisible characters becomes `Player N`, and so does a name made only of soft hyphens (U+00AD, tested only that way, not in the client name) |
| `join_held` | Host (`join_timeout` 2 s, `scene_timeout` 8 s), 1 client and 1 extra: the client hangs for 4 s, the change stays open; meanwhile the extra joins, reports the scene and waits longer than its `join_timeout`. The host does not disconnect it, after the change there are 3 players, `player_joined` comes exactly once, the extra never gets `join_failed` |
| `client_misbehaves` | Host and 2 clients: client 1 registers again twice (also with dirty names), reports the scene with a wrong number (999, -1, 0, the old number) and with the right one although it is already `ready`, and has registered with a name made of control, zero-width and bidi characters plus 10,000 characters. The host keeps session, player list, state and scene unchanged (name only cut and cleaned), emits no signal, and client 2 sees the same. Part 2: client 1 does not report the new scene itself; wrong numbers keep the change open and do not make it `ready`, only the right one ends it. Client 1 is ignored, not disconnected. **Not tested:** calls of host RPCs (`state._apply`, `_receive_roster`, `_player_added`, `_player_removed`, `_ready_set`, `_entered`, `_rejected`) by a client, on the host and on the other client. The engine rejects them itself and writes an `ERROR` line at the receiver, which the runner counts as a failure; Core relies on the engine's check there |
| `join_flood` | Host, 1 flooder (raw ENet connections without registration, a new one every 0.3 s, until all seats would be taken) and 1 extra: a real player still gets in, and the host holds fewer silent connections than `max_players`. No test checks the number 2 (at most two per address, the oldest are disconnected). Anyone who joins from one address at the same time (all scenarios with several clients run like this) is not disconnected |
| `lan_throttle` | Host, 1 client and 1 late joiner: every participant's ENet connections report throttle deceleration 0. Reason: otherwise ENet drops unreliable packets for seconds after a join or scene change |
| `state_stranger` | Host, 1 client and 1 stranger (connected, never registered): the stranger gets no state change and its `changed` handlers do not run |
| `window_close` | Host and 1 client: `NOTIFICATION_WM_CLOSE_REQUEST` ends the host's session, the client hears `HOST_LEFT` |
| `scene_02` | Test scene 02 (`tests/feature_scenes/02_nachzuegler/`) with host, clients and late joiners; then abuse: a sender who is not a player is refused; standing figures send no position for 1 s; one client sends 40 counts and 11 crate changes at once, the host accepts only 10 of each (counter 13, color 3); the same client sets its figure to NaN and to 1e9: the host and the two other clients check the figure's view in every frame (setter check of `figure.gd`) and never see it there, each got at least 3 updates; the host finally sees it at the good position again (the clients report only "never bad", not the end position); the rate table has no entry left after the client leaves |
| `scene_change` | Host and 3 clients, three changes in a row: `ready` is `false` for everyone except the host right after the call, `scene_entered` comes once per change, `ready_changed` comes, `change_scene` during a change gives `ERR_BUSY`, the scene is fresh when changing back, one client gets `ERR_UNAUTHORIZED` |
| `scene_change_timeout` | Host and 2 clients, `scene_timeout` 1 s: one client hangs for 3 s; `scene_entered` comes after the timeout only for the ready one, the hanging one becomes `ready` later and gets its own `scene_entered`; a timer that is still running does nothing after `leave` |
| `scene_change_leave` | Host and 2 clients: a player who leaves during a change does not hold it up; the host checks at once, long before `scene_timeout` |
| `scene_change_join` | Host, 1 client and 1 late joiner: whoever joins during a running change is announced only afterwards; the host hears `scene_entered` twice, then `player_joined`; the late joiner gets its `scene_entered` after `session_started` |
| `scene_change_chain` | like `scene_change_join`, but the host starts the next change right away in the `scene_entered` handler: the waiting late joiner is not admitted for the old scene; order at the host `scene_entered`, `scene_entered`, `player_joined`; its `scene_entered` comes once |
| `scene_change_8` | like `scene_change`, with host and 7 clients (8 players) |
| `scene_change_reentrant` | Host and 1 client: a `ready_changed` handler calls `leave()` in the middle of `change_scene`; no error in the log, `change_scene` gives `OK`, the stage is empty, the client hears `HOST_LEFT` |
| `scene_change_reentrant_join` | Host and 1 late joiner: a `player_joined` handler of the host calls `leave()` while the late joiner is being admitted; no error in the log, the late joiner does not get stuck |
| `scene_03` | Test scene 03 (`tests/feature_scenes/03_szenenwechsel/`) through its buttons, host and 2 clients: two changes (A, B, A), each time the list shows three players "ready", status "Everyone is here.", "Scene changes" is right, for clients "Go to" cannot be used; both menu buttons are locked while the join runs; at the end the host leaves and the clients show the menu with "The host left the session." |
| `scene_08` | Test scene 08 (`tests/feature_scenes/08_rundenablauf_minimal/`) through its buttons, host, 2 clients and 1 late joiner: at the start `No round yet.`, for clients start and end are locked; round 1 with two points each from three players (6), end, a point call after the end does not count; round 2: the late joiner shows `round=2 running=1 points=1` from `session_started` and one frame later; round 3: the late joiner scores; round 4: client 1 sends 30 point calls at once, the host counts 10, and a sender who is not a player is refused; at the end the host leaves and the others show the menu with "The host left the session." |
| `quickstart` | Host and 1 client run the guide's script (`tests/quickstart/quickstart.tscn`, the same text as in `addons/lobbysmith_core/README.md`) with its own `host()` and `join()` (fixed default port): within 10 s both show two names in `Players`, after the host's `LobbySmith.leave()` the client has no line left |

Not covered: real mouse clicks on the buttons of scenes 03 and 08 (the tests trigger them by signal).
That is checked only by hand (see the bullet on mouse clicks in the section "Not checked" in `addons/lobbysmith_core/README.md`). All scenarios run over LAN only,
not over Steam. For what was and was not checked by hand, including Steam, see that section.

`unit/test_docs.gd` keeps the public files honest: the script `tests/quickstart/quickstart.gd` appears verbatim in `addons/lobbysmith_core/README.md`, `LICENSE` begins with `MIT License`, `SECURITY.md` contains `Report a vulnerability`, the README has its sections.

`unit/test_steam_transport.gd` checks the lobby flow of `transport_steam.gd` (hosting, joining, search with 5 attempts, `ROOM_FULL`, cancel during search and join, orphaned lobby) against a **fake Steam**: a GDScript object registered as the singleton `Steam`, which records calls and sends the signals. None of this ran against real Steam. The test ends where `SteamMultiplayerPeer` would be created: a stand-in peer only remembers the lobby id.

Unit tests without a network are in `unit/test_*.gd` and are `SceneTree` scripts that end with
`quit(0)` or `quit(1)`.

`fail_demo` and `warn_demo` check the runner itself. They run in every full run and
count as passed when they fail in the intended way: the text of the error must contain the
word `intended` (`PASS fail_demo (failed as it must)`). If they pass, the runner reports
`FAIL <name>: should have failed`; if they fail for another reason (syntax error, timeout),
`FAIL <name>: failed, but not as intended: ...`. Starting one alone still works with
`-- fail_demo`; the result counts the same way then.
