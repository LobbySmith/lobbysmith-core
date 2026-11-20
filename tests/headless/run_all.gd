extends SceneTree
# Headless test runner. Starts one Godot process per player and judges the
# scenario by exit codes and logs.
#   godot --headless --path . -s tests/headless/run_all.gd            (everything)
#   godot --headless --path . -s tests/headless/run_all.gd -- <name>  (one scenario or unit test)
# Options after "--":
#   --jobs=<n>        process budget (default: the CPU core count); scenarios run in parallel
#                     as long as the sum of their processes (clients + host + extras) fits
#   --base-port=<n>   first port (default 24600, range 1024..60000); scenario i uses base + 10 * i
# Result lines (PASS/FAIL/SKIP) appear as scenarios finish, so not in list order. Then come
# the lines "TIME total" and up to five "TIME <name>" (longest first), then the final line
# ALL PASS or FAILED: <n>.
# A scenario with "needs_voice": true and a unit test the optional scenarios_pro.gd lists as
# needing voice are skipped when that file reports that voice is not available.
# A scenario entry may carry "script": a res:// path that replaces scenarios/<name>.gd.
# A scenario entry may carry "part": every peer gets --part=<part>; "name" stays the label.

const SCENARIOS := [
	{"name": "smoke", "clients": 1, "extras": 0, "default": true, "timeout": 30.0},
	{"name": "session_guards", "clients": 0, "extras": 0, "default": true, "timeout": 20.0},
	{"name": "lobby_4", "clients": 3, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "lobby_8", "clients": 7, "extras": 1, "default": true, "timeout": 90.0},
	{"name": "leave", "clients": 3, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "join_timeout", "clients": 0, "extras": 0, "default": true, "timeout": 30.0},
	{"name": "no_steam", "clients": 0, "extras": 0, "default": true, "timeout": 20.0},
	{"name": "names", "clients": 3, "extras": 0, "default": true, "timeout": 40.0},
	{"name": "scene_01", "clients": 1, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "stage_guards", "clients": 0, "extras": 0, "default": true, "timeout": 20.0},
	{"name": "stage_basic", "clients": 2, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "state_basic", "clients": 2, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "late_join", "clients": 3, "extras": 1, "default": true, "timeout": 90.0},
	{"name": "late_join_8", "clients": 7, "extras": 1, "default": true, "timeout": 120.0},
	{"name": "scene_02", "clients": 3, "extras": 0, "default": true, "timeout": 90.0},
	{"name": "scene_change", "clients": 3, "extras": 0, "default": true, "timeout": 90.0},
	{"name": "scene_03", "clients": 2, "extras": 0, "default": true, "timeout": 90.0},
	{"name": "scene_change_timeout", "clients": 2, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "scene_change_leave", "clients": 2, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "scene_change_join", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "scene_change_chain", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "scene_change_8", "clients": 7, "extras": 0, "default": true, "timeout": 120.0},
	{"name": "scene_change_reentrant", "clients": 1, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "scene_change_reentrant_join", "clients": 0, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "join_stale", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "join_held", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "window_close", "clients": 1, "extras": 0, "default": true, "timeout": 30.0},
	{"name": "rounds_basic", "clients": 3, "extras": 0, "default": true, "timeout": 90.0},
	{"name": "rounds_late", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "scene_08", "clients": 2, "extras": 1, "default": true, "timeout": 120.0},
	{"name": "quickstart", "clients": 1, "extras": 0, "default": true, "timeout": 40.0},
	{"name": "state_stranger", "clients": 2, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "join_flood", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	{"name": "client_misbehaves", "clients": 2, "extras": 0, "default": true, "timeout": 60.0},
	{"name": "lan_throttle", "clients": 1, "extras": 1, "default": true, "timeout": 60.0},
	# Self-check of the runner: these must fail, a pass would mean the runner is blind.
	{"name": "fail_demo", "clients": 0, "extras": 0, "default": true, "expect_fail": "intended", "timeout": 15.0},
	{"name": "warn_demo", "clients": 0, "extras": 0, "default": true, "expect_fail": "intended", "timeout": 15.0},
]
const UNIT_DIR := "res://tests/headless/unit"
const PRO_SCENARIOS := "res://tests/headless/scenarios_pro.gd"
const PRO_UNIT_DIR := "res://tests/headless/unit_pro"
const BAD_WORDS := ["ERROR", "WARNING"]   # "SCRIPT ERROR" contains "ERROR"

const DEFAULT_PORT := 24600

var _project_dir := ProjectSettings.globalize_path("res://")
var _log_dir := ""
var _free := 0         # process budget not in use
var _running := 0      # entries started and not yet finished
var _failed := 0
var _times := []       # [name, seconds] per finished entry


func _initialize() -> void:
	_run()


# Returns {"only", "jobs", "base_port", "error"}; error is "" when the arguments are fine.
static func parse_args(args: PackedStringArray, cores: int) -> Dictionary:
	var result := {"only": "", "jobs": cores, "base_port": DEFAULT_PORT, "error": ""}
	for arg in args:
		if arg.begins_with("--jobs="):
			var text := arg.trim_prefix("--jobs=")
			if not text.is_valid_int() or int(text) < 1:
				result["error"] = "bad --jobs value '%s'" % text
			else:
				result["jobs"] = int(text)
		elif arg.begins_with("--base-port="):
			var text := arg.trim_prefix("--base-port=")
			if not text.is_valid_int() or int(text) < 1024 or int(text) > 60000:
				result["error"] = "bad --base-port value '%s'" % text
			else:
				result["base_port"] = int(text)
		elif arg.begins_with("--"):
			result["error"] = "unknown option '%s'" % arg
		elif result["only"] != "":
			result["error"] = "more than one name: '%s' and '%s'" % [result["only"], arg]
		else:
			result["only"] = arg
	return result


# Number of processes a scenario needs: clients, the host and the extras.
static func cost(scenario: Dictionary) -> int:
	return scenario["clients"] + 1 + scenario["extras"]


# Index of the first pending cost that fits into free; an oversized one runs alone.
static func pick_next(costs: Array, free: int, running: int) -> int:
	for i in costs.size():
		if costs[i] <= free:
			return i
	return 0 if running == 0 and not costs.is_empty() else -1


func _run() -> void:
	var started := Time.get_ticks_msec()
	var parsed := parse_args(OS.get_cmdline_user_args(), OS.get_processor_count())
	if parsed["error"] != "":
		print("FAIL: %s" % parsed["error"])
		quit(1)
		return
	var only: String = parsed["only"]
	var base_port: int = parsed["base_port"]
	_free = parsed["jobs"]
	_log_dir = ProjectSettings.globalize_path("user://headless_logs" if base_port == DEFAULT_PORT
			else "user://headless_logs_%d" % base_port)
	DirAccess.make_dir_recursive_absolute(_log_dir)
	var ran := 0
	var skipped := 0
	var scenarios: Array = SCENARIOS.duplicate()
	var has_voice := false
	var needs_voice_units := []   # unit tests the optional scenario list says need voice
	if ResourceLoader.exists(PRO_SCENARIOS):
		var pro = load(PRO_SCENARIOS)
		if pro == null or not pro.can_instantiate():
			print("FAIL: could not load the Pro scenario list")
			quit(1)
			return
		scenarios.append_array(pro.SCENARIOS)
		if pro.has_method("more"):
			scenarios.append_array(pro.more())   # further entries, same format
		has_voice = pro.has_voice()
		needs_voice_units = pro.UNIT_NEEDS_VOICE
	var pending := []   # work entries in list order: scenarios first, then unit tests
	for i in scenarios.size():
		var scenario: Dictionary = scenarios[i]
		if (only == "" and scenario["default"]) or only == scenario["name"]:
			ran += 1
			if scenario.get("needs_voice", false) and not has_voice:
				skipped += 1
				print("SKIP %s (voice not available)" % scenario["name"])
				continue
			pending.append({"name": scenario["name"], "cost": cost(scenario), "scenario": scenario,
					"port": base_port + 10 * i, "expect_fail": scenario.get("expect_fail", "")})
	for path in _unit_tests():
		var file: String = path.get_file()
		if only == "" or only == file.get_basename():
			ran += 1
			if needs_voice_units.has(file.get_basename()) and not has_voice:
				skipped += 1
				print("SKIP %s (voice not available)" % file.get_basename())
				continue
			pending.append({"name": file.get_basename(), "cost": 1, "path": path, "expect_fail": ""})
	if ran == 0:
		print("FAIL: nothing named '%s'" % only)
		quit(1)
		return
	while not pending.is_empty() or _running > 0:
		while not pending.is_empty():
			var costs := []
			for entry in pending:
				costs.append(entry["cost"])
			var next := pick_next(costs, _free, _running)
			if next < 0:
				break
			var entry: Dictionary = pending.pop_at(next)
			_free -= entry["cost"]
			_running += 1
			_execute(entry)   # not awaited: it reports back through _finish
		await create_timer(0.1).timeout
	if skipped > 0:
		print("SKIPPED: %d" % skipped)
	print("TIME total %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	_times.sort_custom(func(a, b): return a[1] > b[1])
	for t in _times.slice(0, 5):
		print("TIME %s %.1f s" % [t[0], t[1]])
	print("ALL PASS" if _failed == 0 else "FAILED: %d" % _failed)
	quit(0 if _failed == 0 else 1)


func _execute(entry: Dictionary) -> void:
	var begin := Time.get_ticks_msec()
	var problem: String
	if entry.has("scenario"):
		problem = await _run_scenario(entry["scenario"], entry["port"])
	else:
		problem = await _run_unit(entry["path"])
	_times.append([entry["name"], (Time.get_ticks_msec() - begin) / 1000.0])
	_failed += _judge(entry["name"], problem, entry["expect_fail"])
	_free += entry["cost"]
	_running -= 1


# expect_fail: text that must appear in the problem (the run must fail in this way).
func _judge(name: String, problem: String, expect_fail := "") -> int:
	if expect_fail != "":
		if problem == "":
			print("FAIL %s: should have failed" % name)
			return 1
		if not problem.contains(expect_fail):
			print("FAIL %s: failed, but not as intended: %s" % [name, problem])
			return 1
		print("PASS %s (failed as it must)" % name)
		return 0
	print("PASS %s" % name if problem == "" else "FAIL %s: %s" % [name, problem])
	return 0 if problem == "" else 1


func _unit_tests() -> Array:
	var files := []
	for dir in [UNIT_DIR, PRO_UNIT_DIR]:
		var found := []
		for file in DirAccess.get_files_at(dir):   # empty when the folder is missing
			if file.begins_with("test_") and file.ends_with(".gd"):
				found.append(dir.path_join(file))
		found.sort()
		files.append_array(found)
	return files


func _run_scenario(scenario: Dictionary, port: int) -> String:
	var procs := []   # [label, pid, log]
	var total: int = scenario["clients"] + 1
	procs.append(_start_peer(scenario, "host", 0, total, port))
	await create_timer(0.5).timeout
	for i in scenario["clients"]:
		procs.append(_start_peer(scenario, "client", i + 1, total, port))
	if scenario["extras"] > 0:
		await create_timer(4.0).timeout
		for i in scenario["extras"]:
			procs.append(_start_peer(scenario, "extra", total + i, total, port))
	return await _wait_and_check(procs, scenario["timeout"])


func _run_unit(path: String) -> String:
	var log := _log_dir.path_join("unit_%s.log" % path.get_file().get_basename())
	var pid := _spawn(["-s", path], log)
	return await _wait_and_check([[path.get_file(), pid, log]], 30.0)


func _start_peer(scenario: Dictionary, role: String, index: int, total: int, port: int) -> Array:
	var label := "%s_%s_%d" % [scenario["name"], role, index]
	var log := _log_dir.path_join(label + ".log")
	var args := ["res://tests/headless/peer.tscn", "--", "--scenario=" + scenario["name"],
			"--role=" + role, "--index=%d" % index, "--total=%d" % total, "--port=%d" % port]
	if scenario.has("script"):
		args.append("--script=" + scenario["script"])
	if scenario.has("part"):
		args.append("--part=" + scenario["part"])
	var pid := _spawn(args, log)
	return [label, pid, log]


func _spawn(args: Array, log: String) -> int:
	if FileAccess.file_exists(log):
		DirAccess.remove_absolute(log)
	return OS.create_process(OS.get_executable_path(),
			["--headless", "--path", _project_dir, "--log-file", log] + args)


func _wait_and_check(procs: Array, timeout: float) -> String:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var running := false
		for proc in procs:
			if OS.is_process_running(proc[1]):
				running = true
		if not running:
			break
		await create_timer(0.1).timeout
	var problems := []
	for proc in procs:
		if OS.is_process_running(proc[1]):
			OS.kill(proc[1])
			problems.append("%s timed out" % proc[0])
			continue
		var code := OS.get_process_exit_code(proc[1])
		if code != 0:
			problems.append("%s exit %d%s" % [proc[0], code, _result_line(proc[2])])
		var bad := _bad_line(proc[2])
		if bad != "":
			problems.append("%s log: %s" % [proc[0], bad])
	return "; ".join(problems)


func _result_line(log: String) -> String:
	for line in FileAccess.get_file_as_string(log).split("\n"):
		if line.begins_with("RESULT: FAIL"):
			return " (%s)" % line.trim_prefix("RESULT: FAIL").strip_edges()
	return ""


func _bad_line(log: String) -> String:
	for line in FileAccess.get_file_as_string(log).split("\n"):
		for word in BAD_WORDS:
			if line.contains(word):
				return line.strip_edges()
	return ""
