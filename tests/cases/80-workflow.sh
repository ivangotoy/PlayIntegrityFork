# Release workflow: the build step (which runs upstream-merged build code) gets no signing secrets.

WF="$ROOT/.forgejo/workflows/module-release.yml"
S="SIGN""_"
check "workflow has no $S entries" sh -c '! grep -q "$1" "$2"' - "$S" "$WF"
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null; then
    check "yaml: build step env has no $S key" python3 -I -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for job in wf["jobs"].values() for s in job["steps"]]
build = [s for s in steps if s.get("name", "").startswith("Build")]
sys.exit(0 if build and not any(k.startswith(sys.argv[2]) for s in build for k in (s.get("env") or {})) else 1)
' "$WF" "$S"
else
    skip "yaml: build step env (no python3 yaml module)"
fi
# fixed source list: build outputs and fetched third-party sources contain unrelated SIGN_ strings
check "no build or module source reads $S" sh -c '
cd "$1" && ! { find .forgejo/workflows .github app/src/main/java module -type f ! -path "module/zygisk/*" ! -name classes.dex;
    ls .forgejo/module-ci.conf app/build.gradle.kts build.gradle.kts settings.gradle.kts gradle.properties app/proguard-rules.pro \
        app/src/main/cpp/CMakeLists.txt app/src/main/cpp/main.cpp; } | xargs grep -l "$2" | grep -q .' - "$ROOT" "$S"
check "no signingConfig in app/build.gradle.kts" sh -c '! grep -q signingConfig "$1"' - "$ROOT/app/build.gradle.kts"

# two dispatched runs must not release at the same time (versionCode, tag and update.json race):
# one top-level concurrency group, a running release never cancelled. Read without PyYAML.
wf_concurrency() {
  awk '
    /^concurrency:[ \t]*$/ { inb = 1; blocks++; next }
    inb && /^[^ \t#]/ { inb = 0 }
    inb && /^  group:[ \t]*[^ \t]/ { group++ }
    inb && /^  cancel-in-progress:[ \t]*false[ \t]*$/ { keep++ }
    /^[ \t]+concurrency:/ { nested++ }
    END { exit !(blocks == 1 && group == 1 && keep == 1 && !nested) }
  ' "$1"
}
check "workflow: one top-level concurrency group, cancel-in-progress false" wf_concurrency "$WF"

# The fork releases above the code module.prop builds (already published), so root managers
# offer it as an update: released versionCode = module.prop's + offset
off=$(sed -n 's/^VERSION_CODE_OFFSET=//p' "$ROOT/.forgejo/module-ci.conf")
check "module-ci.conf: release versionCode above module.prop's" [ "${off:-0}" -ge 1 ]

# the job builds the dispatched commit even when main has moved since: the steps whose run text
# clones or calls `module-ci.sh build` run against a local bare repo whose main has a commit after
# BASE_SHA. The fixture's .forgejo/module-ci.sh is a marker script that records which commit's copy
# ran; the real pipeline is never reachable from here. Run blocks are read without PyYAML.
wf_dispatched() {
  _wf=$WORK/workflow
  mkdir -p "$_wf/job" "$_wf/forge/owner" "$_wf/seed/.forgejo" || return 1
  git init -q --bare "$_wf/forge/owner/repo.git" && git init -q "$_wf/seed" || return 1
  for _c in dispatched later-on-main; do
    printf '#!/bin/sh\necho "%s $*" >> "$MARKER_LOG"\n' "$_c" > "$_wf/seed/.forgejo/module-ci.sh"
    (cd "$_wf/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "$_c") || return 1
    [ "$_c" = dispatched ] && _base=$(git -C "$_wf/seed" rev-parse HEAD)
  done
  git -C "$_wf/seed" push -q "$_wf/forge/owner/repo.git" HEAD:refs/heads/main || return 1
  python3 -I - "$ROOT/.forgejo/workflows/module-release.yml" > "$_wf/steps.sh" <<'PY'
import re, sys
steps, cur = [], None
for l in open(sys.argv[1]).read().split("\n"):
    if re.match(r"^      - name:", l):
        cur = {"run": [], "in": False}; steps.append(cur); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
for st in steps:
    text = "\n".join(st["run"])
    if "git clone" in text or "module-ci.sh build" in text:
        print("(\n" + text + "\n)")
PY
  : > "$_wf/marker.log"
  (cd "$_wf/job" && env SERVER_URL="file://$_wf/forge" REPOSITORY=owner/repo BASE_SHA="$_base" \
    MARKER_LOG="$_wf/marker.log" sh "$_wf/steps.sh") > "$_wf/out.log" 2>&1 || { tail -n 2 "$_wf/out.log"; return 1; }
  [ "$(git -C "$_wf/job/src" rev-parse HEAD)" = "$_base" ] && [ "$(cat "$_wf/marker.log")" = "dispatched build src" ] \
    || { echo "     ran: $(tr '\n' ';' < "$_wf/marker.log")"; return 1; }
}
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  check "workflow: checkout and build use the dispatched commit after main moved" wf_dispatched
else
  skip "workflow dispatched-commit check (needs python3 and git)"
fi
