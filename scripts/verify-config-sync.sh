#!/usr/bin/env bash
# On-demand health check for the ~/.gemini config sync. Run through /verify-config-sync.
# Read-only: never commits, pulls, pushes, or edits files. `git fetch` updates remote-tracking refs only.
# Usage: verify-config-sync.sh [--test]    --test also runs the offline test suite.
# Exit status is non-zero if any check reports FAIL.
set -uo pipefail

REPO="$HOME/.gemini"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

pass() { echo "PASS $*"; }
warn() { echo "WARN $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- Repo ---
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  fail "~/.gemini is not a git repo"
  exit 1
fi
cd "$REPO" || exit 1
pass "~/.gemini is a git repo"

origin="$(git config --get remote.origin.url)"
if [ -n "$origin" ]; then pass "origin is $origin"; else fail "no origin remote, see Set up in README.md"; fi

# Name origin explicitly: without an argument, gh prefers a remote called upstream (README.md adds one).
visibility="$([ -n "$origin" ] && gh repo view "$origin" --json visibility --jq .visibility 2>/dev/null)"
case "$visibility" in
  PRIVATE) pass "GitHub repo is private" ;;
  "") warn "could not read repo visibility (not on GitHub, gh not signed in, or no network). Confirm the repo is private yourself" ;;
  *) fail "GitHub repo visibility is $visibility, expected PRIVATE" ;;
esac

# --- Sync state ---
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' GIT_TERMINAL_PROMPT=0
if timeout 15 git fetch --quiet 2>/dev/null; then pass "remote is reachable"; else warn "could not fetch, counts below may be stale"; fi

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  fail "rebase in progress, sync is paused until it is resolved"
fi

read -r behind ahead < <(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo "? ?")
if [ "$behind" = "0" ] && [ "$ahead" = "0" ]; then
  pass "in step with remote"
else
  warn "behind remote by $behind, ahead by $ahead (next sync fixes this)"
fi

# The settings files differ from the commit on every device by their per-device keys (KEYS in config-sync.sh).
# Count a settings file only when something else in it changed.
changed="$(python3 - "$SCRIPTS/config-sync.sh" <<'EOF'
import ast, json, re, subprocess, sys
keys = ast.literal_eval(re.search(r"KEYS = (\{.*?\n\})", open(sys.argv[1]).read(), re.S).group(1))
status = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout.splitlines()
def only_device_keys(path):
    try:
        head = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True, text=True)
        committed = json.loads(head.stdout) if head.returncode == 0 else {}
        local = json.load(open(path))
    except (OSError, ValueError):
        return False
    strip = lambda d: {k: v for k, v in d.items() if k not in keys[path]}
    return strip(committed) == strip(local)
print(sum(1 for line in status if not (line[3:] in keys and only_device_keys(line[3:]))))
EOF
)"
if [ "$changed" = "0" ]; then pass "no uncommitted changes"; else warn "${changed:-some} uncommitted change(s) (next sync commits these)"; fi

echo "INFO last sync per device:"
git log --format=%s --grep='^sync: ' -n 500 | awk '$1 == "sync:" && !seen[$2]++ { print "INFO   " $2 " " $3 }'

# --- Privacy ---
# Under antigravity-cli/, only settings.json and top-level scripts (a statusline command, say) may sync.
forbidden="$(git ls-files | grep -E '^(oauth_creds\.json|google_accounts\.json|gemini-credentials\.json|\.env|installation_id|trustedFolders\.json|projects\.json|state\.json|history/|tmp/|\.sync\.log|config/mcp_config\.json|config/plugins/|config/projects/)'
  git ls-files antigravity-cli/ | grep -vxE 'antigravity-cli/(settings\.json|[^/]+\.(sh|py))')"
if [ -z "$forbidden" ]; then pass "no private paths tracked"; else fail "private paths tracked: $(tr '\n' ' ' <<<"$forbidden")"; fi

if [ ! -s "$SCRIPTS/token-patterns.txt" ]; then
  fail "scripts/token-patterns.txt is missing, token scan cannot run"
else
  matches="$(git grep -I -l -E -f "$SCRIPTS/token-patterns.txt" HEAD -- 2>/dev/null)"
  if [ -z "$matches" ]; then pass "no token patterns in tracked files"; else fail "possible tokens in: $(tr '\n' ' ' <<<"$matches")"; fi
fi

# --- Config files ---
for f in settings.json antigravity-cli/settings.json config/hooks.json config/skills.json config/import_manifest.json; do
  [ -f "$f" ] || continue
  if python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
    pass "$f is valid JSON"
  else
    fail "$f is not valid JSON"
  fi
done

# Secrets in settings.json are $VAR references. Each must resolve from the shell or ~/.gemini/.env.
for var in $(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' settings.json 2>/dev/null | tr -d '${' | sort -u); do
  if [ -n "${!var:-}" ] || grep -qE "^(export )?$var=." .env 2>/dev/null; then
    pass "$var is set for settings.json"
  else
    warn "$var is not set, settings.json references it. Add it to ~/.gemini/.env"
  fi
done

# --- Device readiness ---
paths="$(bash "$SCRIPTS/install.sh" --paths 2>/dev/null)"
if [ -z "$paths" ]; then pass "no config file points into another home"; else echo "$paths"; fi

# Windows tools (Fork, editors) writing over \\wsl$ drop exec bits. With fileMode on, git reports each as a change.
if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  if [ "$(git config --bool core.fileMode)" = "false" ]; then
    pass "core.fileMode is false"
  else
    warn "core.fileMode is not false, Windows tools will show mode-only changes. Run scripts/install.sh"
  fi
fi

# scripts/tools.txt lists one CLI per line as "<command> <install hint>".
if [ -f scripts/tools.txt ]; then
  while read -r tool hint; do
    case "$tool" in "" | \#*) continue ;; esac
    command -v "$tool" >/dev/null || warn "$tool is not on PATH: $hint"
  done <scripts/tools.txt
else
  warn "scripts/tools.txt is missing, tools were not checked"
fi

missing="$(bash "$SCRIPTS/install.sh" --plugins 2>/dev/null)"
if [ -z "$missing" ]; then pass "all imported plugins are installed"; else sed 's/^MISSING /WARN missing /' <<<"$missing"; fi

# --- Sync log ---
if [ -f .sync.log ]; then
  last_ok="$(grep ' ok: ' .sync.log | tail -1)"
  if [ -n "$last_ok" ]; then echo "INFO last successful sync: $last_ok"; else warn "no successful sync in .sync.log"; fi
  echo "INFO recent warnings:"
  grep ' WARN ' .sync.log | tail -3 | sed 's/^/INFO   /'
else
  warn "no .sync.log yet, no sync has run on this device"
fi

# --- Optional test suite ---
if [ "${1:-}" = "--test" ]; then
  out="$(mktemp)"
  if bash "$SCRIPTS/test-config-sync.sh" >"$out" 2>&1; then
    pass "test suite: $(tail -1 "$out")"
  else
    fail "test suite failed:"
    grep '^FAIL' "$out"
  fi
  rm -f "$out"
fi

echo
if [ "$fails" -eq 0 ]; then echo "Result: no failures"; else echo "Result: $fails failure(s)"; fi
[ "$fails" -eq 0 ]
