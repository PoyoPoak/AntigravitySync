#!/usr/bin/env bash
# Sync ~/.gemini (Gemini CLI and Antigravity CLI config) with its private git remote.
#
# Usage: see usage() below, or run config-sync.sh --help.
#
# Sync is manual only. Neither CLI runs this on its own: Antigravity has no session-end hook, and neither
# CLI exposes a measured way to tell a window the user opened from a headless or nested session.
# Every run prints its result and exits 1 on failure. Warnings are also logged to ~/.gemini/.sync.log.
set -uo pipefail

REPO="$HOME/.gemini"
PATTERNS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token-patterns.txt"
LOG="$REPO/.sync.log"
action=""

usage() {
  cat <<'EOF'
usage: config-sync.sh option
  --now        sync now: commit local changes, pull with rebase, push
  --overwrite  make the remote match this device, replacing other devices' changes
  --reset      make this device match the remote, saving its discarded work on a local branch
  --help       show this help
EOF
}
log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
fail() {
  log "WARN $*"
  echo "config-sync: $*"
  exit 1
}

# A pulled change to the Antigravity plugin list reports what this device is missing.
plugins_if_changed() {
  if ! git diff --quiet "$before" HEAD -- config/import_manifest.json && [ -f scripts/install.sh ]; then
    bash scripts/install.sh --plugins
  fi
}

case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  --now) action=sync ;;
  --overwrite) action=overwrite ;;
  --reset) action=reset ;;
  *) usage >&2; exit 2 ;;
esac

if [ ! -d "$REPO/.git" ]; then
  echo "config-sync: $REPO is not a git repo" >&2
  exit 1
fi

exec 9>"$REPO/.sync.lock"
flock -n 9 || fail "lock held by another sync, try again shortly"

cd "$REPO" || exit 1
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5'
export GIT_TERMINAL_PROMPT=0

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  fail "rebase in progress in $REPO, resolve it to resume syncing"
fi

# Some settings stay per device: /model rewrites the model often, and Antigravity's trusted workspaces are
# this device's trust decisions. Before committing, put back the committed values and save this device's.
# On exit, success or failure, apply this device's values on top of whatever is now checked out.
DEVICE_KEYS_FILE="$(git rev-parse --git-path device-settings.json)"
device_keys() {
  python3 - "$1" "$DEVICE_KEYS_FILE" <<'PY'
import json, os, subprocess, sys
mode, saved = sys.argv[1:]
KEYS = {
    "settings.json": ("model",),
    "antigravity-cli/settings.json": ("model", "trustedWorkspaces"),
}

def apply(path, src):
    # Writes only when a value differs, and keeps the file's final-newline style, so the CLI's own
    # formatting never shows up as a change.
    raw = open(path).read()
    cur = json.loads(raw)
    new = dict(cur)
    for k in KEYS[path]:
        if k in src:
            new[k] = src[k]
        else:
            new.pop(k, None)
    if new != cur:
        with open(path, "w") as f:
            f.write(json.dumps(new, indent=2, ensure_ascii=False) + ("\n" if raw.endswith("\n") else ""))

if mode == "save":
    device = {}
    for path, keys in KEYS.items():
        if not os.path.exists(path):
            continue
        cur = json.load(open(path))
        device[path] = {k: cur[k] for k in keys if k in cur}
        head = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True, text=True)
        apply(path, json.loads(head.stdout) if head.returncode == 0 else {})
    json.dump(device, open(saved, "w"))
elif os.path.exists(saved):
    device = json.load(open(saved))
    os.remove(saved)
    for path, values in device.items():
        if os.path.exists(path):
            apply(path, values)
PY
}
device_keys restore # a run that was killed may have left saved values
device_keys save || fail "could not read settings.json or antigravity-cli/settings.json, fix the JSON first"
trap 'device_keys restore' EXIT

if [ "$action" = "reset" ]; then
  # No token scan: the backup commit stays on a local branch and is never pushed.
  timeout 10 git fetch --quiet 2>/dev/null || fail "fetch failed (network or SSH), nothing changed"
  before="$(git rev-parse HEAD)"
  backup=""
  git add -A
  if ! git diff --cached --quiet || [ "$(git rev-list --count '@{u}..HEAD')" != "0" ]; then
    if ! git diff --cached --quiet && ! git -c commit.gpgsign=false commit -qm "reset backup: $(hostname) $(date -Is)"; then
      git reset -q
      fail "backup commit failed, nothing changed"
    fi
    backup="reset-backup/$(date +%Y%m%d-%H%M%S)"
    git branch "$backup" HEAD
  fi
  if [ -z "$backup" ] && [ "$before" = "$(git rev-parse '@{u}')" ]; then
    echo "config-sync: already matches remote"
    exit 0
  fi
  git reset -q --hard '@{u}'
  log "ok: reset${backup:+, backup $backup}"
  echo "config-sync: reset to remote${backup:+, discarded local work saved on branch $backup}"
  plugins_if_changed
  exit 0
fi

[ -s "$PATTERNS" ] || fail "$PATTERNS is missing, token scan cannot run, sync stopped"
git add -A
matches="$(git grep --cached -I -l -E -f "$PATTERNS" 2>/dev/null)"
if [ -n "$matches" ]; then
  git reset -q
  fail "possible token found, sync stopped. Check: $(tr '\n' ' ' <<<"$matches")"
fi
committed=no
if ! git diff --cached --quiet; then
  git -c commit.gpgsign=false commit -qm "sync: $(hostname) $(date -Is)" || fail "commit failed, check git user.name and user.email"
  committed=yes
fi

before="$(git rev-parse HEAD)"
upstream_before="$(git rev-parse '@{u}' 2>/dev/null)"
replaced=0
if [ "$action" = "overwrite" ]; then
  # Merge with -s ours keeps this device's files and records the remote commits as merged, so the push
  # fast-forwards: no force push, and replaced commits stay in history for recovery.
  timeout 10 git fetch --quiet 2>/dev/null || fail "fetch failed (network or SSH), try again later"
  replaced="$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
  if [ "$replaced" != "0" ] && ! git -c commit.gpgsign=false merge --quiet -s ours --no-edit \
    -m "overwrite: $(hostname) $(date -Is)" '@{u}' >/dev/null; then
    fail "overwrite merge failed, nothing pushed"
  fi
elif ! timeout 10 git pull --rebase --quiet 2>/dev/null; then
  if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
    git rebase --abort
    fail "conflict with remote, local work kept and not pushed. Run git pull --rebase in $REPO to resolve"
  fi
  fail "pull failed (network or SSH), try again later"
fi

pulled="$(git rev-list --count "$upstream_before..@{u}" 2>/dev/null || echo 0)"
pushed="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
if [ "$pushed" != "0" ] && ! timeout 10 git push --quiet 2>/dev/null; then
  fail "push failed (network or SSH), try again later"
fi
log "ok: $action"

if [ "$action" = "overwrite" ] && [ "$replaced" != "0" ]; then
  echo "config-sync: overwrote remote with this device, replaced $replaced remote commit(s), pushed $pushed commit(s)"
elif [ "$committed" = "no" ] && [ "$pulled" = "0" ] && [ "$pushed" = "0" ]; then
  echo "config-sync: already up to date"
else
  echo "config-sync: synced, pulled $pulled commit(s), pushed $pushed commit(s)"
fi
plugins_if_changed

tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
exit 0
