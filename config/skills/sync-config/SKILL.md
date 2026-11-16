---
name: sync-config
description: Sync ~/.gemini (Gemini CLI and Antigravity config) with its private git repo now, overwrite the repo with this device's config, reset this device to the repo, or list these options. Use only when the user asks to sync their Gemini or Antigravity config.
argument-hint: "[overwrite | reset | help]"
disable-model-invocation: true
---

# Sync config

Run one command based on the arguments, then report its output in one or two lines.

| Arguments | Command |
| --- | --- |
| none | `bash "$HOME/.gemini/scripts/config-sync.sh" --now` |
| `overwrite` | `bash "$HOME/.gemini/scripts/config-sync.sh" --overwrite` |
| `reset` | `bash "$HOME/.gemini/scripts/config-sync.sh" --reset` |
| `help` | `grep '^| ./sync-config' "$HOME/.gemini/README.md"` |

## Rules

- For `help`, show the output as a table and run nothing else.
- Sync is manual only. Nothing syncs `~/.gemini` unless this command runs.
- `overwrite` makes the remote match this device's tracked files and drops other devices' unsynced changes from the current state. Report how many remote commits it replaced. They stay in git history, so recovery is possible (see "Troubleshooting" in `~/.gemini/README.md`).
- `reset` makes this device match the remote and pushes nothing. Pending edits are saved on a local `reset-backup/<time>` branch. Report the branch name. Local-only files (credentials, `.env`, `mcp_config.json`, conversations) are never touched.
- If the output lists `MISSING plugin` lines, pass them on with their commands. Do not run them: `agy plugin import` is interactive.
- If the sync fails, explain the message and propose a fix from "Troubleshooting" in `~/.gemini/README.md`. Apply a fix only after the user approves it.
- If the sync reports a possible token, name the file only. Do not print the matching line.
