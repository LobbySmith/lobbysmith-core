extends RefCounted
# Runner self-check: a process that exits 0 but logs an error must fail the run.

func run(peer: Node) -> void:
	push_error("intended error line")
	peer.pass_and_quit()
