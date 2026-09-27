# Agent hooks

The server package serves `GET /setup.sh` and `GET /hooks/files/:name`. Its build reads the hook source files in this directory, so the installer and event hooks match that server release.

Download and inspect the setup script from your own server before running it. Supply a dedicated ingest token. The setup script installs Claude Code, Codex, and Devin integrations and prints the configuration backup paths. Run `bash setup.sh --dry-run` first to inspect the changes. To select integrations individually from a source checkout, use `bash hooks/install.sh --claude`, `--codex`, or `--devin` after configuring your environment. Codex requires trusting the new hooks through its `/hooks` command.

For a source checkout, create the hook environment before registering integrations:

```sh
mkdir -p ~/.config/my-dashboard
test -f ~/.config/my-dashboard/env || cp hooks/env.example ~/.config/my-dashboard/env
# Edit MY_DASHBOARD_URL and MY_DASHBOARD_TOKEN (the ingest token) in that file.
bash hooks/install.sh --claude --codex --devin
```

Keep that file local. [env.example](env.example) documents content collection and optional project/host aliases.

Agent state events use `POST /dashboard/events`. `GET /dashboard/auth/ingest-check` validates an ingest token without writing an event. A client token is not an ingest token. If the installer reports an unsupported endpoint, update the server and obtain its installer again.

By default, hooks send state metadata, including actual project paths and host identifiers (set `MY_DASHBOARD_PROJECT_LABEL` and `MY_DASHBOARD_HOST_LABEL` to aliases when desired), without prompt/message content or the original event body. Detailed content requires both hook `MY_DASHBOARD_INCLUDE_CONTENT=1` and server `DASHBOARD_STORE_MESSAGE=1`. See [the server guide](../server/README.md) for the full collection policy. Do not send secret values in event messages. Ingest and client tokens grant access to one dashboard instance; this is not a multi-tenant authorization system.

## Update or remove

To update, download the setup script from the upgraded server again and run it. Existing `~/.config/my-dashboard/env` values are retained. Hook files are replaced under `${XDG_DATA_HOME:-$HOME/.local/share}/my-dashboard/hooks`.

To remove the integrations, back up the current agent configuration and remove only entries that invoke these dashboard hook scripts from `~/.claude/settings.json` and `~/.config/devin/config.json`. In `~/.codex/config.toml`, remove the section between `# BEGIN my-dashboard hooks` and `# END my-dashboard hooks`. Restoring the installer's `.bak.TIMESTAMP` file is suitable only if you have made no later configuration changes.

After the integrations are removed, delete the installed hook directory and `~/.config/my-dashboard/env` if no other dashboard installation uses them. Hook state and queued events live under `~/.local/state/my-dashboard`; this directory can also contain app data, so inspect it before deleting anything. Removing local hooks does not remove data already stored by your server. Use the dashboard's session deletion and your server retention settings for that data.
