# Contributing

Describe the user-visible problem, a minimal reproduction, and the behavior you expect. Use synthetic sessions and remove credentials, prompts, hostnames, and local paths from logs.

For server changes, run the server commands in the root README, including the packaged-consumer verification. For app changes, run `mise run check` and `mise run verify` from `app/`. API or hook changes must also pass `python3 scripts/contract_check.py`.

Keep the versioned protocol compatible when possible. Include a migration and an upgrade test for schema changes. Never modify a released SQL migration. State changes must preserve event ordering, duplicate handling, cursors, and read markers.

Submit changes to the shared application, server, hooks and protocol directly to this repository. Consumers can pin a reviewed revision of the Flutter package at `app/flutter_app`. Read LICENSE before submitting and contribute only code you are entitled to license under its terms.


Contributions are accepted under the repository license with your copyright
retained. This does not automatically grant the maintainer a separate right to
relicense your contribution for a commercial offering. If a contribution needs
such a grant, it will be agreed separately before it is included in that offering.
