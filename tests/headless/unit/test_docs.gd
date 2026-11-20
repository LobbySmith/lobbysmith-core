extends SceneTree
# Keeps the public Core files honest: the quickstart in the README is the runnable script,
# the license and the security policy exist, the README has its sections.

const README := "res://addons/lobbysmith_core/README.md"
const LICENSE := "res://addons/lobbysmith_core/LICENSE"
const SECURITY := "res://SECURITY.md"
const TESTS_README := "res://tests/headless/README.md"
const QUICKSTART := "res://tests/quickstart/quickstart.gd"
const HEADINGS := [
	"## Your first two-player run in five minutes",
	"## API",
	"## Tests",
	"## How this is built",
	"## License",
]

const AI_NOTE := "Most of this code was written by AI agents. A human reviews it, plays each test scene by hand before a release and decides what ships. The tests are in this repository; run them yourself."
const MAX_QUICKSTART_LINES := 40
# Built from parts so this public file does not contain them itself.
const FORBIDDEN := ["lobbysmith" + "_pro", "two" + "voip", "flood" + "_shift", "@", "/" + "users" + "/"]

var _failures := 0


func _initialize() -> void:
	var readme := read(README)
	var script := read(QUICKSTART).trim_suffix("\n")
	check(script != "", "quickstart.gd exists and is not empty")
	check(readme.contains(script), "README contains the exact text of quickstart.gd")
	check(readme.contains(AI_NOTE), "README has the AI note verbatim")
	check(script.split("\n").size() <= MAX_QUICKSTART_LINES, "quickstart.gd has at most 40 lines")
	for path in [README, LICENSE, SECURITY, QUICKSTART, TESTS_README]:
		var text := read(path).to_lower()
		for word in FORBIDDEN:
			check(not text.contains(word), "%s contains '%s'" % [path, word])
	check(read(LICENSE).begins_with("MIT License"), "LICENSE starts with MIT License")
	check(read(SECURITY).contains("Report a vulnerability"), "SECURITY.md names 'Report a vulnerability'")
	for heading in HEADINGS:
		check(readme.contains("\n" + heading + "\n"), "README heading " + heading)
	if _failures == 0:
		print("RESULT: PASS")
	quit(0 if _failures == 0 else 1)


func read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("RESULT: FAIL ", what)
