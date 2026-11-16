#!/usr/bin/env bash
# Set up this device after ~/.gemini is linked to your config repo. Safe to run repeatedly.
# Changes only file modes and core.fileMode (on WSL); everything else is a report.
# Usage: install.sh            file modes, plugin, secret, tool, and path report
#        install.sh --plugins  list Antigravity plugins in config/import_manifest.json missing from this device
#        install.sh --paths    list absolute paths in config files that point into another home directory
set -uo pipefail

REPO="$HOME/.gemini"
mode="${1:-all}"

# Prints "MISSING plugin ..." per plugin. `agy plugin import` picks plugins interactively, so this
# reports the command instead of running it.
missing_plugins() {
  python3 - "$REPO" <<'EOF'
import json, os, sys
repo = sys.argv[1]
try:
    imports = json.load(open(os.path.join(repo, "config", "import_manifest.json"))).get("imports", [])
except (OSError, ValueError):
    imports = []
hint = {"claude-code": "agy plugin import claude", "gemini-cli": "agy plugin import gemini"}
for i in imports:
    if not os.path.isdir(os.path.join(repo, "config", "plugins", i["name"])):
        source = i.get("source", "?")
        print(f"MISSING plugin {i['name']} (from {source}): run {hint.get(source, 'agy plugin install ' + i['name'])}")
EOF
}

check_secrets() {
  local var
  for var in $(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' "$REPO/settings.json" 2>/dev/null | tr -d '${' | sort -u); do
    [ -n "${!var:-}" ] || grep -qE "^(export )?$var=." "$REPO/.env" 2>/dev/null ||
      echo "MISSING $var: settings.json references it. Add $var=<value> to ~/.gemini/.env (chmod 600)"
  done
  if [ -n "$(command -v agy)" ] && [ ! -f "$REPO/config/mcp_config.json" ]; then
    echo "MISSING config/mcp_config.json: it stays local because it holds API keys. Add servers with agy mcp add"
  fi
}

# scripts/tools.txt lists one CLI per line as "<command> <install hint>".
check_tools() {
  local tool hint
  if [ ! -f "$REPO/scripts/tools.txt" ]; then
    echo "WARN scripts/tools.txt is missing, tools were not checked"
    return
  fi
  while read -r tool hint; do
    case "$tool" in "" | \#*) continue ;; esac
    command -v "$tool" >/dev/null || echo "MISSING $tool: $hint"
  done <"$REPO/scripts/tools.txt"
}

# A path under another user's home works on one device only. Paths under this device's $HOME are fine.
check_paths() {
  local f p
  for f in settings.json antigravity-cli/settings.json config/hooks.json config/skills.json; do
    [ -f "$REPO/$f" ] || continue
    for p in $(grep -oE "/(home|Users)/[^/\"'[:space:]]+" "$REPO/$f" | sort -u); do
      case "$HOME/" in
        "$p"/*) ;;
        *) echo "WARN $f points into $p, but this device's home is $HOME. Use the same username on every device, or fix the path" ;;
      esac
    done
  done
}

case "$mode" in
  --plugins) missing_plugins ;;
  --paths) check_paths ;;
  all)
    # Windows tools writing over \\wsl$ drop exec bits. Restore them, then stop git tracking modes.
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
      git -C "$REPO" diff --summary | awk '/mode change/{print $NF}' | xargs -r git -C "$REPO" checkout --
      git -C "$REPO" config core.fileMode false
    fi
    missing_plugins
    check_secrets
    check_tools
    check_paths
    ;;
  *) echo "usage: install.sh [--plugins|--paths]" >&2; exit 2 ;;
esac
