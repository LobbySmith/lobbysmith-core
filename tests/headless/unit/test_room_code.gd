extends SceneTree

const RoomCode := preload("res://addons/lobbysmith_core/room_code.gd")


var _failures := 0


func _initialize() -> void:
	for i in 200:
		var code := RoomCode.generate()
		check(code.length() == 6, "length")
		check(RoomCode.is_valid(code), "generated code is valid")
	check(RoomCode.normalize(" ab-c 2x3 ") == "ABC2X3", "normalize")
	# Pasted codes: trailing newline, NBSP, en/em dash and a tab around the characters.
	check(RoomCode.normalize("ab\u00a0c\u20132x3\n") == "ABC2X3", "normalize: NBSP, en dash, newline")
	check(RoomCode.normalize("\tabc\u20142x3 ") == "ABC2X3", "normalize: em dash, tab")
	check(RoomCode.is_valid(RoomCode.normalize(" abc\u00a0-2x3\r\n")), "pasted code becomes valid")
	check(not RoomCode.is_valid(RoomCode.normalize("abc2x3z")), "normalize does not repair a wrong length")
	check(not RoomCode.is_valid("ABC0EF"), "0 is not allowed")
	check(not RoomCode.is_valid("ABCDE"), "too short")
	check(not RoomCode.is_valid("ABCDEFG"), "too long")
	check(not RoomCode.is_valid("abc2x3"), "lowercase needs normalize first")
	if _failures == 0:
		print("RESULT: PASS")
	quit(0 if _failures == 0 else 1)


func check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("RESULT: FAIL ", what)
