# Security policy

## Supported versions

Only the latest release of LobbySmith Core is supported. Fixes go into a new release, not into old ones.

## Report a vulnerability

Please do not open a public issue for a security problem.

Open this repository's **Security** tab and choose **Report a vulnerability**. That creates a private report that only the maintainers can read. We aim to answer within 7 days.

Please include the Godot version, the steps to reproduce, and what an attacker gains.

## What to expect from the network model

- The host is the server and is trusted. A malicious host can send anything to its clients, so only join sessions of hosts you trust. The host also chooses which `res://` scene every client loads (`change_scene`), and a client loads it without asking: a host is trusted with that. Clients refuse any scene path that does not start with `res://` or that contains `..`, `./` or a doubled slash, so a host cannot make them load files from `user://` or outside the project. A refused path may make the engine log an error line on the client. The scene and the synchronizers in it (for example figure positions) are also sent to a connection that has not registered yet, until it registers or is dropped after `join_timeout`.
- Clients are checked. Core accepts a client's player name only for that client itself, strips control characters (including zero-width and bidirectional ones), cuts it to 24 characters, and turns away players beyond `max_players`. Names are not unique and not identities: use the peer id. Against silent connections the host keeps at most two per address that are still no player after a second and drops the oldest beyond that. This works only for ENet (LAN or direct IP), not over Steam. It is best effort: a continuous fast flood can still keep free seats blocked, and three or more honest players joining at the same moment from one address over a slow link (registration taking longer than about a second) can be dropped and must retry. Core does not limit the size of a packet, the engine reads it whole before Core sees it. Connections that never become a player are dropped after `join_timeout`.
- The Steam lobby is public. The room code is a search filter, not a secret and not a password: the host stores it as lobby data and never checks it when someone joins. Anyone who lists the lobbies of your app id can find and try to join your lobby without the code, until all seats are taken. With the default test app id 480 that is every developer who tests with it. Core has no password, no kick and no way to turn a player away after they joined; nothing like that is built in today. A game can only choose a small `max_players`, use its own `steam_app_id`, and share the code with friends only. Do not treat a Steam session as private. This is read from the code and one two-account check; it was not re-checked for this release.
- There is no encryption beyond what ENet (LAN) or Steam provides. Do not send secrets through a session.
