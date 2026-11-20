extends RefCounted
## Room codes for Steam lobbies: short, easy to read aloud, no look-alikes.

const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I
const LENGTH := 6
# What a pasted code may contain besides the code: spaces (also non-breaking), tab and line
# breaks, hyphen, en dash, em dash.
const SEPARATORS := [" ", "\u00a0", "\t", "\r", "\n", "-", "\u2013", "\u2014"]


static func generate() -> String:
	var code := ""
	for i in LENGTH:
		code += ALPHABET[randi() % ALPHABET.length()]
	return code


## Turns typed or pasted input ("ab-c 2x3") into the stored form ("ABC2X3").
static func normalize(text: String) -> String:
	for separator in SEPARATORS:
		text = text.replace(separator, "")
	return text.to_upper()


static func is_valid(code: String) -> bool:
	if code.length() != LENGTH:
		return false
	for character in code:
		if not ALPHABET.contains(character):
			return false
	return true
