extends SceneTree

const Runner := preload("res://tests/headless/run_all.gd")


var _failures := 0


func _initialize() -> void:
	# parse_args
	var d := Runner.parse_args(PackedStringArray([]), 14)
	check(d == {"only": "", "jobs": 14, "base_port": 24600, "error": ""}, "defaults")
	d = Runner.parse_args(PackedStringArray(["--jobs=1", "lobby_4", "--base-port=26000"]), 14)
	check(d["only"] == "lobby_4" and d["jobs"] == 1 and d["base_port"] == 26000 and d["error"] == "", "all three")
	for bad in [["--jobs=0"], ["--jobs=abc"], ["--jobs=-2"], ["--base-port=70000"], ["--base-port=80"], ["--nope=1"], ["a", "b"]]:
		check(Runner.parse_args(PackedStringArray(bad), 14)["error"] != "", "error for %s" % [bad])
	# cost
	check(Runner.cost({"clients": 7, "extras": 1}) == 9, "cost")
	# pick_next
	check(Runner.pick_next([], 14, 0) == -1, "nothing pending")
	check(Runner.pick_next([9, 2], 4, 3) == 1, "skips what does not fit")
	check(Runner.pick_next([9, 8], 4, 3) == -1, "waits while something runs")
	check(Runner.pick_next([9, 8], 4, 0) == 0, "an oversized scenario runs alone")
	check(Runner.pick_next([2, 2], 2, 5) == 0, "first that fits")
	if _failures == 0:
		print("RESULT: PASS")
	quit(0 if _failures == 0 else 1)


func check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("RESULT: FAIL ", what)
