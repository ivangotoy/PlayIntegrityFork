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
check "only module-ci.sh mentions $S outside tests/" sh -c '
cd "$1" && ! find . \( -path ./.git -o -path ./tests \) -prune -o -type f -exec grep -l "$2" {} + | grep -v "^./.forgejo/module-ci.sh$" | grep -q .' - "$ROOT" "$S"
check "no signingConfig in app/build.gradle.kts" sh -c '! grep -q signingConfig "$1"' - "$ROOT/app/build.gradle.kts"
