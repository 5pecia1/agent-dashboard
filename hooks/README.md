# Agent hooks

The server package serves `GET /setup.sh` and `GET /hooks/files/:name`. Its build reads the hook source files in this directory, so the installer and event hooks match that server release.

## Install from your server

Requirements: `curl`, `jq`, and `python3`. [Deploy your own server](../docs/quickstart.md#set-up-your-cloudflare-server) first, then replace `https://YOUR_SERVER` with its HTTPS origin:

```sh
curl -fsSL https://YOUR_SERVER/setup.sh | bash
```

Supply your dedicated ingest token when the terminal prompts you. The prompt reads from the terminal, not the script's piped input. The setup script installs Claude Code, Codex, Devin, and Antigravity CLI integrations and prints the configuration backup paths. It prepares each agent's configuration even if that agent is not installed yet. Codex requires trusting the new hooks through its `/hooks` command.

The common installer offers the same server-matched setup:

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- hooks --server-url https://YOUR_SERVER
```

There is no independent `--version` for hooks: upgrade the server, then obtain its setup script again. To inspect the script and preview changes before installing:

```sh
curl -fsSL https://YOUR_SERVER/setup.sh -o setup.sh
less setup.sh
bash setup.sh --dry-run
bash setup.sh
```

## Install from source

From a source checkout, create the hook environment before registering integrations. Choose any of `--claude`, `--codex`, `--devin`, or `--antigravity`:

```sh
mkdir -p ~/.config/my-dashboard
test -f ~/.config/my-dashboard/env || cp hooks/env.example ~/.config/my-dashboard/env
# Edit MY_DASHBOARD_URL and MY_DASHBOARD_TOKEN (the ingest token) in that file.
bash hooks/install.sh --claude --codex --devin --antigravity
```

Keep that file local. [env.example](env.example) documents content collection, optional project/host aliases, and the opt-in to report Antigravity CLI print-mode runs.

Agent state events use `POST /dashboard/events`. `GET /dashboard/auth/ingest-check` validates an ingest token without writing an event. A client token is not an ingest token. If the installer reports an unsupported endpoint, update the server and obtain its installer again.

By default, hooks send state metadata, including actual project paths and host identifiers (set `MY_DASHBOARD_PROJECT_LABEL` and `MY_DASHBOARD_HOST_LABEL` to aliases when desired), without prompt/message content, task titles, or the original event body. Detailed content — and Herdr task titles, when present — requires both hook `MY_DASHBOARD_INCLUDE_CONTENT=1` and server `DASHBOARD_STORE_MESSAGE=1`. For `message`, Grok sends its last assistant reply as camelCase `lastAssistantMessage`; the hook reads it only when the source is `grok` and only after snake-case `last_assistant_message` — it never reads transcripts or infers messages from other fields. See [the server guide](../server/README.md) for the full collection policy. Do not send secret values in event messages. Ingest and client tokens grant access to one dashboard instance; this is not a multi-tenant authorization system.

## Task titles (optional Herdr enrichment)

When a hook runs inside a Herdr pane, it can attach the session's task title as `display_title` on each event. The dashboard uses it to tell apart concurrent sessions of the same project: cards, tray items, and notifications render the canonical display name `{project} · {display_title}` (contract `i18n` → `push.title_titled`), while event-history rows show the captured title itself. It is presentation metadata only — it changes neither session identity nor state resolution, and it is not pane-click navigation.

- **Prerequisite**: the matching official Herdr hook integration must already report the session as a native `herdr:<agent>` session whose `kind=id` value equals the dashboard `session_id`. The installer never registers a second Herdr hook — nothing is installed automatically. Without that integration, before the session is first reported (so the first event may carry no title), or with path-only identity, the lookup falls back and the event goes out untitled.
- **Opt-in**: a title is personal content like `message`/`raw`. Hooks query Herdr only when `MY_DASHBOARD_INCLUDE_CONTENT=1`, and the server stores and pushes titles only when `DASHBOARD_STORE_MESSAGE=1`. Both stay off by default. Opting out re-filters the on-disk spool — including old queued lines — but does not retroactively erase rows already stored; those persist until normal retention.
- **Fail-open**: the optional `herdr-context.py` helper (Python standard library only) makes one `pane.current` Unix-socket request with a 0.25s budget. Missing helper, missing `python3`, a dead socket, a malformed reply, or a timeout all mean "no title" — the original event still ships and the hook exits 0. Throttled heartbeats and events the Antigravity hook discards never query.
- **Title source**: the first non-empty of pane `title` → `label` → `terminal_title_stripped`, normalized (folded whitespace, control/format characters removed, 120 codepoints max). Terminal text is never scraped.
- **Coverage**: claude-code, codex, devin, grok, and antigravity, including the legacy Codex `notify` fallback. `send-generic.sh` (generic) never enriches.
- **Timing**: the title is captured just before send, so a spooled line keeps its capture-time title and is not re-queried on replay.
- **Sync note**: a title-only change does not create a state transition. Clients that follow only sync deltas may not see a renamed session until the next real transition or a reset snapshot — the protocol documents this as the name-only sync limitation.

## Antigravity CLI

Antigravity CLI (`agy`) runs the lifecycle hooks in `~/.gemini/config/hooks.json`. Each top-level key in that file is one hook bundle, and `agy` runs all bundles. Use version 1.2.4 or later (check with `agy --version`, upgrade with `agy update`). According to its release notes, `Stop` hooks do not run before version 1.1.10, and versions before 1.2.4 could silently drop `hooks.json` settings when the customization token budget was exceeded. `bash hooks/install.sh --antigravity` (which the setup script runs for you) adds one bundle named `my-dashboard`:

- If the file does not exist or is empty (including a file that holds only whitespace or a UTF-8 byte order mark), it is treated as new. A byte order mark is removed when the file is read and is not written back. If the file is not valid JSON or its top level is not an object, the installer stops without writing.
- Other bundles keep their values and order, but the file is rewritten with 2-space indentation, so its formatting can change. The `my-dashboard` bundle is independent of them: this integration does not use or depend on any other tool's hooks, and removing either one does not affect the other.
- Running the command again changes nothing. An existing file is backed up next to itself as `hooks.json.bak.TIMESTAMP` before it is written.
- To preview, run `bash hooks/install.sh --dry-run` without target flags: the Antigravity step then prints the bundle without creating any file or folder. A target flag such as `--antigravity` always writes, even together with `--dry-run`.
- Set `MY_DASHBOARD_ANTIGRAVITY_HOOKS` to write a different file.

`agy` does not put the event name on stdin, so each registered command passes it as a second argument (`agent-event-hook.sh antigravity <event>`). `agy` reads each hook's stdout as a JSON answer and stops the run if a hook exits with an error. The hook therefore prints its answer first and always exits with 0, and the installed command answers by itself whenever the hook cannot be run: the path is not a regular readable file, the file is empty or not executable, or bash is not on `PATH`. The command also clears `BASH_ENV` before it starts the hook. The exact bundle and answers are defined by `event_state_map.antigravity_hook_translation` in `contracts/dashboard-protocol.v1.json`.

To check the registration, run the following command. It answers without starting a model turn, so it uses no quota. Typing `/hooks` in the interactive terminal UI shows the same list. The output should include `my-dashboard`.

```sh
agy -p "/hooks" --output-format json
```

What the dashboard shows:

- **Working** when a turn starts, and again when `agy` makes its next model call after a stop. This includes turns that `agy` starts on its own, for example after a background task finishes.
- **Waiting for input** when `agy` asks a question with its `ask_question` or `ask_permission` tool, and **Working** again once you answer.
- **Turn finished** whenever `agy` stops running a turn, including turns that end while background work such as a subagent is still running.

Two kinds of runs are deliberately not reported. Subagent conversations are skipped because each one is a separate conversation that cannot be linked to its parent. Print-mode runs (`agy -p`, `--print`, `--prompt`, with a single or double dash) are skipped because automation tools start them often and they do not need watching. To report print-mode runs too, set `MY_DASHBOARD_ANTIGRAVITY_INCLUDE_PRINT=1` in the hook's environment or in `~/.config/my-dashboard/env` ([env.example](env.example) has the commented line). Interactive runs started with `--prompt-interactive` are reported.

Limits:

- `agy` has no session-end hook, so a session stays at **Turn finished** and later shows the **Stale** badge. Delete such sessions in the dashboard when you no longer need them.
- `agy` does not signal that a command is waiting for your approval. That session shows **Working** and later **Possibly stalled**.
- Pressing Esc to interrupt a turn sends no stop event.
- Subagent events are not reported, so while a subagent keeps running after its parent's turn has ended, the parent session shows **Turn finished**. It shows **Working** again when `agy` calls the parent again.
- Questions asked by a subagent are not tracked.

## Update or remove

To update, download the setup script from the upgraded server again and run it. Existing `~/.config/my-dashboard/env` values are retained. Hook files are replaced under `${XDG_DATA_HOME:-$HOME/.local/share}/my-dashboard/hooks`.

To remove the integrations, back up the current agent configuration and remove only entries that invoke these dashboard hook scripts from `~/.claude/settings.json` and `~/.config/devin/config.json`. In `~/.codex/config.toml`, remove the section between `# BEGIN my-dashboard hooks` and `# END my-dashboard hooks`. In `~/.gemini/config/hooks.json`, delete the top-level `my-dashboard` key and leave other bundles unchanged. Restoring the installer's `.bak.TIMESTAMP` file is suitable only if you have made no later configuration changes.

After the integrations are removed, delete the installed hook directory and `~/.config/my-dashboard/env` if no other dashboard installation uses them. Hook state and queued events live under `~/.local/state/my-dashboard`; this directory can also contain app data, so inspect it before deleting anything. Removing local hooks does not remove data already stored by your server. Use the dashboard's session deletion and your server retention settings for that data.
