extends RefCounted
# Runner self-check: proves that a failing process fails the run.

func run(peer: Node) -> void:
	peer.fail_and_quit("intended")
