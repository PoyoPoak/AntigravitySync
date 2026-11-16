#!/usr/bin/env bash
# Offline tests for config-sync.sh and verify-config-sync.sh.
# Uses a temporary bare remote and two fake home directories. Never touches the real ~/.gemini or GitHub.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
pass=0; fail=0
trap 'rm -rf "$TMP"' EXIT

ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_NOSYSTEM=1

# Fake `gh` so verify's visibility check needs no network.
mkdir -p "$TMP/bin"
# FAKE_VISIBILITY="" stands for a repo gh cannot read (not on GitHub, or gh not signed in).
printf '#!/bin/sh\necho "$*" >> "%s/gh-args"\necho "${FAKE_VISIBILITY-PRIVATE}"\n' "$TMP" > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

git init -q --bare -b main "$TMP/remote.git"

seed() {
  local h="$TMP/seed/.gemini"
  mkdir -p "$h/scripts" "$h/config/skills/mine" "$h/antigravity-cli"
  cp "$SRC/.gitignore" "$h/.gitignore"
  cp "$SRC/scripts/token-patterns.txt" "$SRC/scripts/tools.txt" "$h/scripts/"
  # Stub so the plugin step is observable and never runs the real CLI.
  printf '#!/bin/sh\ntouch "$HOME/plugin-step-ran"\n' > "$h/scripts/install.sh"
  echo 'first' > "$h/config/AGENTS.md"
  echo mine > "$h/config/skills/mine/SKILL.md"
  echo '{"imports": []}' > "$h/config/import_manifest.json"
  echo '{"entries": []}' > "$h/config/skills.json"
  echo '{}' > "$h/config/hooks.json"
  # Both CLIs write settings as 2-space JSON. Gemini CLI leaves off the final newline.
  python3 - "$h" <<'EOF'
import json, sys
h = sys.argv[1]
open(h + "/settings.json", "w").write(json.dumps({"security": {"auth": {"selectedType": "oauth-personal"}}}, indent=2))
open(h + "/antigravity-cli/settings.json", "w").write(json.dumps({"colorScheme": "dark"}, indent=2) + "\n")
EOF
  git -C "$h" init -q -b main
  git -C "$h" add -A
  git -C "$h" commit -qm init
  git -C "$h" remote add origin "$TMP/remote.git"
  git -C "$h" push -qu origin main
}

clone_home() {
  mkdir -p "$TMP/$1"
  git clone -q "$TMP/remote.git" "$TMP/$1/.gemini"
}

cmd() {
  local home="$1"; shift
  HOME="$TMP/$home" bash "$SRC/scripts/config-sync.sh" "$@" </dev/null
}
remote_head() { git -C "$TMP/remote.git" rev-parse main; }
log_of() { cat "$TMP/$1/.gemini/.sync.log" 2>/dev/null; }
agents_md() { echo "$TMP/$1/.gemini/config/AGENTS.md"; }

seed
clone_home a
clone_home b

# Push and pull.
echo changed-on-a > "$(agents_md a)"
before="$(remote_head)"
out="$(cmd a --now)"; rc=$?
check "sync commits and pushes" '[ "$rc" -eq 0 ] && [ "$(remote_head)" != "$before" ] && grep -q "pushed 1" <<<"$out"'
check "commit message names the host" 'git -C "$TMP/remote.git" log -1 --format=%s main | grep -q "^sync: $(hostname) "'
out="$(cmd b --now)"; rc=$?
check "second device pulls the change" '[ "$rc" -eq 0 ] && grep -q changed-on-a "$(agents_md b)" && grep -q "pulled 1" <<<"$out"'
out="$(cmd b --now)"; rc=$?
check "sync with nothing to do succeeds and says so" '[ "$rc" -eq 0 ] && grep -qi "up to date" <<<"$out"'

# Arguments.
cmd a >/dev/null 2>&1; rc=$?
check "no argument is rejected" '[ "$rc" -ne 0 ]'
cmd a --unknown >/dev/null 2>&1; rc=$?
check "unknown argument is rejected" '[ "$rc" -ne 0 ]'
before="$(remote_head)"
out="$(cmd a --help)"; rc=$?
check "help lists every option and syncs nothing" \
  '[ "$rc" -eq 0 ] && grep -q -- --now <<<"$out" && grep -q -- --overwrite <<<"$out" && grep -q -- --reset <<<"$out" && [ "$(remote_head)" = "$before" ]'

# Allowlist.
a="$TMP/a/.gemini"
mkdir -p "$a/history/x" "$a/tmp/x" "$a/config/hooks" "$a/config/plugins/p" "$a/antigravity-cli/brain" "$a/skills/s" "$a/commands"
for f in oauth_creds.json google_accounts.json .env installation_id trustedFolders.json projects.json state.json \
  history/x/h tmp/x/t config/mcp_config.json config/plugins/p/plugin.json \
  antigravity-cli/antigravity-oauth-token antigravity-cli/mcp_oauth_tokens.json antigravity-cli/brain/b antigravity-cli/history.jsonl; do
  echo fake > "$a/$f"
done
echo skill > "$a/skills/s/SKILL.md"
echo cmd > "$a/commands/c.toml"
echo hook > "$a/config/hooks/h.sh"
cmd a --now >/dev/null
tracked="$(git -C "$a" ls-files)"
check "config files are tracked" \
  'for f in antigravity-cli/settings.json skills/s/SKILL.md commands/c.toml config/hooks/h.sh config/skills/mine/SKILL.md config/AGENTS.md config/skills.json config/hooks.json config/import_manifest.json settings.json; do grep -qx "$f" <<<"$tracked" || exit 1; done'
check "credentials, MCP keys, history, plugins, and app data are not tracked" \
  '! grep -qE "oauth|google_accounts|\.env|installation_id|trustedFolders|projects\.json|^state\.json|history|tmp/|mcp_config|config/plugins|antigravity-cli/(antigravity-oauth|mcp_oauth|brain)" <<<"$tracked"'

# Secret scan. Tokens are assembled at runtime so this file never matches the scan itself.
ctx7="ctx7sk-$(printf 'a%.0s' {1..36})"
google="AIza$(printf 'a%.0s' {1..35})"
for token in "$ctx7" "$google"; do
  cp "$a/settings.json" "$TMP/settings.keep"
  python3 - "$a/settings.json" "$token" <<'EOF'
import json, sys
p, t = sys.argv[1:]
d = json.load(open(p)); d["mcpServers"] = {"x": {"headers": {"Authorization": "Bearer " + t}}}
json.dump(d, open(p, "w"), indent=2)
EOF
  before="$(remote_head)"
  out="$(cmd a --now)"; rc=$?
  check "token ${token:0:6} blocks the push" '[ "$rc" -ne 0 ] && [ "$(remote_head)" = "$before" ] && grep -qi "possible token" <<<"$out"'
  check "token ${token:0:6} warning does not print the token" '! grep -q "$token" <<<"$out$(log_of a)"'
  check "token ${token:0:6} leaves nothing staged" 'git -C "$a" diff --cached --quiet'
  mv "$TMP/settings.keep" "$a/settings.json"
done
python3 - "$a/settings.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["mcpServers"] = {"x": {"headers": {"Authorization": "Bearer ${CONTEXT7_API_KEY}"}}}
json.dump(d, open(p, "w"), indent=2)
EOF
out="$(cmd a --now)"; rc=$?
check "a \$VAR reference in settings is not a token" '[ "$rc" -eq 0 ] && git -C "$a" show HEAD:settings.json | grep -q CONTEXT7_API_KEY'

# Plugin step runs only when a pull changes config/import_manifest.json.
cmd b --now >/dev/null
rm -f "$TMP/b/plugin-step-ran"
echo '{"imports": [{"name": "x", "source": "claude-code"}]}' > "$a/config/import_manifest.json"
cmd a --now >/dev/null
cmd b --now >/dev/null
check "pulled plugin list change runs the plugin step" '[ -e "$TMP/b/plugin-step-ran" ]'
rm -f "$TMP/b/plugin-step-ran"
echo more >> "$(agents_md a)"
cmd a --now >/dev/null
cmd b --now >/dev/null
check "pull with no plugin list change skips the plugin step" '[ ! -e "$TMP/b/plugin-step-ran" ]'

# Conflict: both devices edit the same line.
echo from-a > "$(agents_md a)"
cmd a --now >/dev/null
echo from-b > "$(agents_md b)"
out="$(cmd b --now)"; rc=$?
check "conflict fails loudly" '[ "$rc" -ne 0 ] && grep -qi "conflict" <<<"$out"'
check "conflict leaves no rebase in progress" '[ ! -d "$TMP/b/.gemini/.git/rebase-merge" ] && [ ! -d "$TMP/b/.gemini/.git/rebase-apply" ]'
check "conflict keeps local work" 'grep -q from-b "$(agents_md b)"'
check "conflict does not overwrite the remote" 'git -C "$TMP/remote.git" show main:config/AGENTS.md | grep -q from-a'
git -C "$TMP/b/.gemini" fetch -q origin
git -C "$TMP/b/.gemini" reset -q --hard origin/main

# Model (both CLIs) and trusted workspaces (Antigravity) stay per device.
edit_json() {
  python3 - "$TMP/$1/.gemini/$2" "$3" <<'EOF'
import json, sys
p = sys.argv[1]
raw = open(p).read()
d = json.loads(raw)
exec(sys.argv[2])
open(p, "w").write(json.dumps(d, indent=2) + ("\n" if raw.endswith("\n") else ""))
EOF
}
keys_of() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(json.dumps([d.get(k) for k in sys.argv[1:]]))' "$@"; }
gem=settings.json; agy=antigravity-cli/settings.json
cmd a --now >/dev/null; cmd b --now >/dev/null
remote_gem="$(git -C "$TMP/remote.git" show main:$gem | keys_of model)"
remote_agy="$(git -C "$TMP/remote.git" show main:$agy | keys_of model trustedWorkspaces)"
edit_json a $gem 'd.update(model={"name": "pro"}, ui={"theme": "x"})'
edit_json a $agy 'd.update(model="Argon", trustedWorkspaces=["/a"], colorScheme="light")'
cmd a --now >/dev/null
edit_json b $gem 'd.update(model={"name": "flash"})'
edit_json b $agy 'd.update(model="Xenon", trustedWorkspaces=["/b"])'
out="$(cmd b --now)"; rc=$?
check "model and trust changes do not conflict" '[ "$rc" -eq 0 ] && ! grep -qi "conflict" <<<"$out"'
check "model and trust are not pushed" \
  '[ "$(git -C "$TMP/remote.git" show main:$gem | keys_of model)" = "$remote_gem" ] && [ "$(git -C "$TMP/remote.git" show main:$agy | keys_of model trustedWorkspaces)" = "$remote_agy" ]'
check "other settings still sync" 'grep -q "\"theme\": \"x\"" "$TMP/b/.gemini/$gem" && grep -q "\"colorScheme\": \"light\"" "$TMP/b/.gemini/$agy"'
check "each device keeps its own model and trust" \
  '[ "$(keys_of model <"$a/$gem")" = "[{\"name\": \"pro\"}]" ] && [ "$(keys_of model trustedWorkspaces <"$TMP/b/.gemini/$agy")" = "[\"Xenon\", [\"/b\"]]" ]'
check "device keys leave nothing staged" '[ -z "$(git -C "$TMP/b/.gemini" diff --cached)" ]'
for h in a b; do
  edit_json "$h" $gem 'd.pop("model", None)'
  edit_json "$h" $agy 'd.pop("model", None); d.pop("trustedWorkspaces", None)'
done
cmd a --now >/dev/null; cmd b --now >/dev/null

# Lock: a second run fails fast instead of waiting.
echo locked >> "$(agents_md a)"
before="$(remote_head)"
( exec 9>"$a/.sync.lock"; flock 9; sleep 1.5 ) &
holder=$!
sleep 0.3
out="$(cmd a --now)"; rc=$?
check "held lock stops the sync and says so" '[ "$rc" -ne 0 ] && [ "$(remote_head)" = "$before" ] && grep -qi "lock" <<<"$out"'
wait "$holder"
cmd a --now >/dev/null
check "next run catches up after the lock" '[ "$(remote_head)" != "$before" ]'

# Unreachable remote.
git -C "$a" remote set-url origin "$TMP/does-not-exist.git"
echo offline >> "$(agents_md a)"
out="$(cmd a --now)"; rc=$?
check "unreachable remote fails loudly and keeps the commit" '[ "$rc" -ne 0 ] && grep -qi "pull failed" <<<"$out" && [ -z "$(git -C "$a" status --porcelain)" ]'
git -C "$a" remote set-url origin "$TMP/remote.git"
cmd a --now >/dev/null; cmd b --now >/dev/null

# --overwrite makes the remote match this device with a normal push, keeping replaced commits in history.
mkdir -p "$TMP/b/.gemini/skills/b-only"
echo from-b > "$TMP/b/.gemini/skills/b-only/SKILL.md"
sed -i '1s/.*/b-line/' "$(agents_md b)"
cmd b --now >/dev/null
b_commit="$(remote_head)"
sed -i '1s/.*/a-line/' "$(agents_md a)"
out="$(cmd a --overwrite)"; rc=$?
check "overwrite succeeds where a sync would conflict" '[ "$rc" -eq 0 ] && grep -q "overwrote remote" <<<"$out"'
check "overwrite leaves the remote equal to this device" \
  '[ "$(git -C "$TMP/remote.git" rev-parse "main^{tree}")" = "$(git -C "$a" rev-parse "HEAD^{tree}")" ] && [ "$(git -C "$TMP/remote.git" show main:config/AGENTS.md | head -1)" = a-line ] && ! git -C "$TMP/remote.git" cat-file -e main:skills/b-only/SKILL.md 2>/dev/null'
check "overwrite keeps replaced commits in history" 'git -C "$TMP/remote.git" merge-base --is-ancestor "$b_commit" main'
out="$(cmd b --now)"; rc=$?
check "other device pulls the overwrite cleanly" '[ "$rc" -eq 0 ] && [ "$(head -1 "$(agents_md b)")" = a-line ] && [ ! -e "$TMP/b/.gemini/skills/b-only/SKILL.md" ]'
out="$(cmd a --overwrite)"; rc=$?
check "overwrite with nothing to replace is up to date" '[ "$rc" -eq 0 ] && grep -q "already up to date" <<<"$out"'

# --reset makes this device match the remote and keeps the discarded work on a local backup branch.
cmd a --now >/dev/null; cmd b --now >/dev/null
mkdir -p "$a/skills/a-pending"
echo pending > "$a/skills/a-pending/SKILL.md"
sed -i '1s/.*/a-local/' "$(agents_md a)"
echo local-only > "$a/oauth_creds.json"
sed -i '1s/.*/b-remote/' "$(agents_md b)"
cmd b --now >/dev/null
remote_before="$(remote_head)"
out="$(cmd a --reset)"; rc=$?
check "reset succeeds and says so" '[ "$rc" -eq 0 ] && grep -q "reset to remote" <<<"$out"'
check "reset leaves this device equal to the remote" \
  '[ "$(git -C "$a" rev-parse HEAD)" = "$(remote_head)" ] && [ "$(head -1 "$(agents_md a)")" = b-remote ] && [ ! -e "$a/skills/a-pending/SKILL.md" ] && [ -z "$(git -C "$a" status --porcelain)" ]'
check "reset keeps local-only files" '[ "$(cat "$a/oauth_creds.json")" = local-only ]'
backup="$(git -C "$a" for-each-ref --format="%(refname:short)" refs/heads/reset-backup/ | tail -1)"
check "reset saves discarded work on a backup branch" \
  '[ -n "$backup" ] && git -C "$a" cat-file -e "$backup:skills/a-pending/SKILL.md" && [ "$(git -C "$a" show "$backup:config/AGENTS.md" | head -1)" = a-local ] && ! git -C "$a" cat-file -e "$backup:oauth_creds.json" 2>/dev/null'
check "reset pushes nothing" '[ "$(remote_head)" = "$remote_before" ] && ! git -C "$TMP/remote.git" show-ref --quiet --heads reset-backup'
cmd a --now >/dev/null
check "next sync does not bring discarded edits back" \
  '[ "$(git -C "$TMP/remote.git" show main:config/AGENTS.md | head -1)" = b-remote ] && ! git -C "$TMP/remote.git" cat-file -e main:skills/a-pending/SKILL.md 2>/dev/null'
out="$(cmd a --reset)"; rc=$?
check "reset when already matching changes nothing" '[ "$rc" -eq 0 ] && grep -q "already matches remote" <<<"$out" && [ "$(git -C "$a" for-each-ref refs/heads/reset-backup/ | wc -l)" -eq 1 ]'
git -C "$a" remote set-url origin "$TMP/nowhere.git"
echo offline-edit >> "$(agents_md a)"
out="$(cmd a --reset)"; rc=$?
check "reset with no network changes nothing" '[ "$rc" -ne 0 ] && grep -qi "fetch failed" <<<"$out" && grep -q offline-edit "$(agents_md a)"'
git -C "$a" checkout -q -- config/AGENTS.md
git -C "$a" remote set-url origin "$TMP/remote.git"

# verify-config-sync.sh.
# WSL_DISTRO_NAME is unset unless a test sets it, so the host running the tests does not matter.
verify() {
  env -u CONTEXT7_API_KEY -u WSL_DISTRO_NAME HOME="$TMP/a" "$@" bash "$SRC/scripts/verify-config-sync.sh" 2>&1
}
run_install() {
  env -u CONTEXT7_API_KEY -u WSL_DISTRO_NAME HOME="$TMP/a" "$@" bash "$SRC/scripts/install.sh" 2>&1
}
cmd a --now >/dev/null
git -C "$a" config core.fileMode false
head_before="$(git -C "$a" rev-parse HEAD)"
status_before="$(git -C "$a" status --porcelain)"
out="$(verify)"; rc=$?
check "verify passes on a clean setup" '[ "$rc" -eq 0 ] && ! grep -q "^FAIL" <<<"$out" && grep -q "^PASS" <<<"$out"'
check "verify changes nothing" '[ "$(git -C "$a" rev-parse HEAD)" = "$head_before" ] && [ "$(git -C "$a" status --porcelain)" = "$status_before" ]'
check "verify lists last sync per device" 'grep -q "^INFO   $(hostname) " <<<"$out"'
check "verify shows the origin it found" 'grep -q "^PASS origin is $TMP/remote.git" <<<"$out"'
# gh picks an "upstream" remote over origin when run without a repo, and the README adds upstream for updates.
check "verify asks gh about origin by URL" 'grep -q "^repo view $TMP/remote.git " "$TMP/gh-args"'
check "verify confirms a private repo" 'grep -q "^PASS GitHub repo is private" <<<"$out"'

# Per-device keys always differ from the committed settings, and no sync commits them.
set_json() {
  python3 - "$a/$1" "$2" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
exec(sys.argv[2])
json.dump(d, open(p, "w"), indent=2)
EOF
}
set_json settings.json 'd["model"] = "device-model"'
set_json antigravity-cli/settings.json 'd.update(model="device-model", trustedWorkspaces=["/somewhere"])'
out="$(verify)"
check "verify does not count per-device keys as uncommitted changes" 'grep -q "^PASS no uncommitted changes" <<<"$out"'
set_json antigravity-cli/settings.json 'd["colorScheme"] = "changed"'
out="$(verify)"
check "verify counts other settings changes as uncommitted" 'grep -q "^WARN 1 uncommitted change" <<<"$out"'
git -C "$a" checkout -q -- settings.json antigravity-cli/settings.json

expect_fail() {
  out="$(verify)"; rc=$?
  check "verify fails on $1" '[ "$rc" -ne 0 ] && grep -q "^FAIL" <<<"$out"'
}
FAKE_VISIBILITY=PUBLIC expect_fail "a public repo"
out="$(verify FAKE_VISIBILITY=)"; rc=$?
check "verify warns when visibility cannot be read" '[ "$rc" -eq 0 ] && grep -q "^WARN could not read repo visibility" <<<"$out"'

git -C "$a" config --unset remote.origin.url
expect_fail "a missing origin"
git -C "$a" config remote.origin.url "$TMP/remote.git"

for f in oauth_creds.json config/mcp_config.json antigravity-cli/mcp_oauth_tokens.json; do
  git -C "$a" add -f "$f"
  git -C "$a" commit -qm bad
  expect_fail "a tracked $f"
  git -C "$a" reset -q --hard "$head_before"
done

mkdir -p "$a/skills/leak"
echo "$ctx7" > "$a/skills/leak/SKILL.md"
git -C "$a" add skills/leak/SKILL.md
git -C "$a" commit -qm bad
expect_fail "a tracked token"
git -C "$a" reset -q --hard "$head_before"

cp "$a/antigravity-cli/settings.json" "$TMP/agy.keep"
echo '{broken' > "$a/antigravity-cli/settings.json"
expect_fail "invalid Antigravity settings JSON"
mv "$TMP/agy.keep" "$a/antigravity-cli/settings.json"

# A $VAR in settings.json must resolve on this device, from the shell or ~/.gemini/.env.
out="$(verify)"
check "verify warns when a settings variable is unset" 'grep -q "^WARN CONTEXT7_API_KEY" <<<"$out"'
echo 'CONTEXT7_API_KEY=x' > "$a/.env"
out="$(verify)"
check "verify accepts a variable set in ~/.gemini/.env" '! grep -q "^WARN CONTEXT7_API_KEY" <<<"$out"'

# Plugins in config/import_manifest.json must be installed under config/plugins/.
out="$(verify)"
check "verify warns about a missing plugin" 'grep -q "^WARN .*plugin.*x" <<<"$out"'
mkdir -p "$a/config/plugins/x"
out="$(verify)"
check "verify accepts installed plugins" 'grep -q "^PASS all imported plugins are installed" <<<"$out"'

# Windows tools writing over \\wsl$ drop exec bits. Only WSL needs core.fileMode false.
git -C "$a" config core.fileMode true
out="$(verify WSL_DISTRO_NAME=Test)"; rc=$?
check "verify on WSL warns when core.fileMode is true" '[ "$rc" -eq 0 ] && grep -q "^WARN core.fileMode" <<<"$out"'
out="$(verify)"
check "verify off WSL ignores core.fileMode" '! grep -q "core.fileMode" <<<"$out"'
run_install >/dev/null
check "install off WSL leaves core.fileMode alone" '[ "$(git -C "$a" config --bool core.fileMode)" = true ]'
run_install WSL_DISTRO_NAME=Test >/dev/null
check "install on WSL sets core.fileMode false" '[ "$(git -C "$a" config --bool core.fileMode)" = false ]'
out="$(verify WSL_DISTRO_NAME=Test)"
check "verify on WSL accepts core.fileMode false" 'grep -q "^PASS core.fileMode is false" <<<"$out"'

# scripts/tools.txt lists the CLIs to check. Comments and blank lines are skipped.
cp "$a/scripts/tools.txt" "$TMP/tools.keep"
printf '# a comment\n\ngit  from your package manager\nno-such-tool-xyz  get it from example.invalid\n' > "$a/scripts/tools.txt"
out="$(verify)"; rc=$?
check "verify warns about a missing tool with its hint" '[ "$rc" -eq 0 ] && grep -q "^WARN no-such-tool-xyz is not on PATH: get it from example.invalid" <<<"$out"'
check "verify skips comments and present tools" '! grep -qE "^WARN (#|git )" <<<"$out"'
out="$(run_install)"
check "install reports a missing tool with its hint" 'grep -q "^MISSING no-such-tool-xyz: get it from example.invalid" <<<"$out" && ! grep -qE "^MISSING (#|git)" <<<"$out"'
mv "$TMP/tools.keep" "$a/scripts/tools.txt"

# Absolute paths to another home break on devices with a different username.
cp "$a/config/skills.json" "$TMP/skills.keep"
echo '{"entries": [{"path": "/home/someone-else/skills"}, {"path": "'"$TMP/a"'/skills"}]}' > "$a/config/skills.json"
out="$(verify)"; rc=$?
check "verify warns about a path under another home" '[ "$rc" -eq 0 ] && grep -q "^WARN config/skills.json .*/home/someone-else" <<<"$out"'
check "verify accepts paths under this home" '! grep -q "$TMP/a/skills" <<<"$(grep "^WARN" <<<"$out")"'
out="$(run_install)"
check "install warns about a path under another home" 'grep -q "^WARN config/skills.json .*/home/someone-else" <<<"$out"'
mv "$TMP/skills.keep" "$a/config/skills.json"
out="$(verify)"
check "verify passes the path check when paths are local" 'grep -q "^PASS no config file points into another home" <<<"$out"'

out="$(verify)"; rc=$?
check "verify passes again after repairs" '[ "$rc" -eq 0 ]'

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
