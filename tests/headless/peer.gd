extends Node
# One test process. Loads a scenario script and gives it a few helpers to
# coordinate with the other processes of the same scenario.

signal checkpoint(tag: String)

var role := "host"       # host | client | extra
var index := 0
var total := 1           # host + clients
var port := 24600
var scenario_name := ""
var part := ""            # optional: the part of a scenario this peer runs (scenario defined)
var script_path := ""     # optional: replaces scenarios/<name>.gd

var _scenario: RefCounted
var _seen_tags := {}
var _reports := {}       # tag -> Array of [ok, message]


func _ready() -> void:
	# The stage replaces the project's main scene; the test node must survive.
	get_tree().set_deferred("current_scene", null)
	for arg in OS.get_cmdline_user_args():
		var pair := arg.trim_prefix("--").split("=", true, 1)
		if pair.size() != 2:
			continue
		match pair[0]:
			"scenario": scenario_name = pair[1]
			"role": role = pair[1]
			"index": index = int(pair[1])
			"total": total = int(pair[1])
			"port": port = int(pair[1])
			"script": script_path = pair[1]
			"part": part = pair[1]
	var path := script_path if script_path != "" else "res://tests/headless/scenarios/%s.gd" % scenario_name
	if not ResourceLoader.exists(path):
		fail_and_quit("unknown scenario '%s'" % scenario_name)
		return
	_scenario = load(path).new()
	_scenario.run(self)


func pass_and_quit() -> void:
	# Clients leave one after another. When two clients disconnect in the same
	# host frame, Godot's server relay tries to tell one about the other and
	# logs "Unable to send packet on channel 0" (engine noise, Godot 4.7.2).
	if role != "host":
		await get_tree().create_timer(0.15 * index).timeout
	print("RESULT: PASS")
	get_tree().quit(0)


func fail_and_quit(message: String) -> void:
	print("RESULT: FAIL ", message)
	get_tree().quit(1)


func wait_until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().process_frame
	return true


## Host only: every client gets `checkpoint(tag)`.
func broadcast(tag: String) -> void:
	_checkpoint.rpc(tag)


## Client: true once the host has broadcast `tag`, even if that happened earlier.
func wait_checkpoint(tag: String, seconds: float) -> bool:
	return await wait_until(func(): return _seen_tags.has(tag), seconds)


## Client to host.
func report(tag: String, ok: bool, message: String = "") -> void:
	_report.rpc_id(1, tag, ok, message)


## Host: "" when `count` clients reported ok for `tag`, else the first problem.
func collect_reports(tag: String, count: int, seconds: float) -> String:
	await wait_until(func(): return _reports.get(tag, []).size() >= count, seconds)
	var got: Array = _reports.get(tag, [])
	for entry in got:
		if not entry[0]:
			return entry[1] if entry[1] != "" else "a client reported failure"
	return "" if got.size() >= count else "timeout"


@rpc("authority", "call_remote", "reliable")
func _checkpoint(tag: String) -> void:
	_seen_tags[tag] = true
	checkpoint.emit(tag)


@rpc("any_peer", "call_remote", "reliable")
func _report(tag: String, ok: bool, message: String) -> void:
	if not _reports.has(tag):
		_reports[tag] = []
	_reports[tag].append([ok, message])
