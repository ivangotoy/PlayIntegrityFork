# WebUI config writes and removal (module/webroot/index.html): the real inline script runs under node
# with a minimal fake DOM; ksu.exec runs each command with sh in the fake root (lib.sh path rewrite).
# A write that fails must leave the old custom.pif.prop as it was, leave no temp file, and not be
# reported as done (no success log, no migrate.sh or killpi.sh); a failed removal must not be
# reported as done. A write that works stores the text byte for byte.

if ! command -v node >/dev/null 2>&1; then
    skip "webui config write/remove (no node)"
else
    H="$ROOT/module/webroot/index.html"
    WJS="$WORK/webui-write.js"
    sed -n '/^<script>$/,/^<\/script>$/p' "$H" | sed '1d;$d' > "$WORK/webui-write-page.js"
    cat > "$WJS" <<'JS'
const fs = require("fs"), vm = require("vm"), cp = require("child_process");
const [page, root, scenario, input, outFile] = process.argv.slice(2);
class CL { constructor() { this.s = new Set(); } add(c) { this.s.add(c); } remove(c) { this.s.delete(c); }
  toggle(c, f) { if (f === undefined ? !this.s.has(c) : f) this.s.add(c); else this.s.delete(c); } contains(c) { return this.s.has(c); } }
class El { constructor(s) { this.sel = s; this.children = []; this.style = {}; this.classList = new CL(); this.value = ""; this.textContent = ""; }
  addEventListener() {} appendChild(c) { this.children.push(c); } querySelector(s) { return new El(s); } closest() { return null; }
  getAttribute() { return null; } setAttribute() {} removeAttribute() {} }
const els = {};
const document = { querySelector: s => els[s] || (els[s] = new El(s)), querySelectorAll: () => [], createElement: t => new El(t),
  documentElement: new El("html"), body: new El("body"), activeElement: null };
const cmds = [], toasts = [];
let pending = 0;
const sb = { document, console, setTimeout, clearTimeout, setImmediate, performance, btoa, atob,
  requestAnimationFrame: f => setImmediate(f), getComputedStyle: () => ({ lineHeight: "12", fontSize: "12" }),
  innerWidth: 400, innerHeight: 800, addEventListener() {} };
sb.window = sb;
sb.ksu = {
  toast: m => toasts.push(m),
  exec(cmd, opts, cb) {
    pending++;
    const c = cmd.split("/data/adb").join(root + "/data/adb");
    cmds.push(c);
    const r = cp.spawnSync("sh", ["-c", c], { encoding: "utf8" });
    setImmediate(() => { pending--; sb[cb](r.status, r.stdout, r.stderr); });
  }
};
let lastLoad = null, target = null;
sb.FileReader = class { readAsText(f) { lastLoad = this.onload({ target: { result: f.text } }); } };
sb.fetch = async () => ({ ok: true, status: 200, text: async () => fs.readFileSync(input, "utf8") });
const idle = async () => { for (let n = 0; n < 3; n++) { await new Promise(r => setImmediate(r)); if (pending) n = -1; } };
(async () => {
  vm.createContext(sb);
  vm.runInContext(fs.readFileSync(page, "utf8"), sb);
  await idle();
  const term = els["#term"]; term.children.length = 0; cmds.length = 0; toasts.length = 0;
  if (scenario === "save") { document.querySelector("#propEditorArea").value = fs.readFileSync(input, "utf8"); await sb.savePropEditor(); }
  else if (scenario === "url") { document.querySelector("#customPrintInput").value = "https://example.invalid/custom.pif.prop"; await sb.submitCustomUrl(); }
  else if (scenario === "file") { await sb.handleFileSelect({ target: { files: [{ name: "custom.pif.prop", text: fs.readFileSync(input, "utf8") }], value: "x" } }); await lastLoad; }
  else if (scenario === "delete") { const p = sb.deletePropFile(); await idle(); document.querySelector("#confirmYes").onclick(); await p; }
  else if (scenario === "setflag") { const [k, v] = input.split("="); await sb.setFlag(k, v); }
  else if (scenario === "setmode") { await sb.setMode(input); }
  else if (scenario === "skip") { target = { checked: !document.querySelector(input).checked }; await document.querySelector(input).onchange({ target }); }
  await idle();
  fs.writeFileSync(outFile, JSON.stringify({ logs: term.children.map(s => s.textContent), toasts, cmds, checked: target ? target.checked : null }, null, 1));
})().catch(e => { console.error(e); process.exit(1); });
JS
    # made-up config; the new text has non-ASCII, quote, dollar, backtick and no trailing newline
    OLDCFG="$WORK/webui-write-old.prop"; NEWTXT="$WORK/webui-write-new.txt"; NEWCFG="$WORK/webui-write-new.prop"
    printf 'MANUFACTURER=Google\nMODEL=Old Pixel\nFINGERPRINT=google/zzold/zzold:98/ZZ0A.240101.001/7654321:user/release-keys\n' > "$OLDCFG"
    printf 'MANUFACTURER=Google\nMODEL=Pixel "Q" $HOME `id` \303\251\nFINGERPRINT=google/zzdev/zzdev:99/ZZ1A.250101.001/1234567:user/release-keys' > "$NEWTXT"
    { cat "$NEWTXT"; echo; } > "$NEWCFG"
    for SC in save url file; do
        new_root
        C="$MOD/custom.pif.prop"
        mkdir -p "$W/failbin"
        printf '#!/bin/sh\ncat > /dev/null\nprintf PARTIAL\nexit 1\n' > "$W/failbin/base64"
        chmod 755 "$W/failbin/base64"

        cp "$OLDCFG" "$C"
        PATH="$W/failbin:$PATH" node "$WJS" "$WORK/webui-write-page.js" "$W" "$SC" "$NEWTXT" "$W/fail.json" 2> "$W/fail.err"
        check "webui $SC: harness ran (failing write)" test -s "$W/fail.json"
        check "webui $SC: failed write leaves the old custom.pif.prop" cmp -s "$OLDCFG" "$C"
        check "webui $SC: failed write leaves no temp file" test -z "$(find "$MOD" -maxdepth 1 -name 'custom.pif.prop?*' ! -name custom.pif.prop.bak)"
        check "webui $SC: failed write not reported as done" sh -c 'test -s "$1" && ! grep -q "✓\|Saved custom.pif.prop\|Copied \|Downloaded " "$1"' - "$W/fail.json"
        check "webui $SC: failed write runs neither migrate.sh nor killpi.sh" sh -c 'test -s "$1" && ! grep -q "migrate.sh\|killpi.sh" "$1"' - "$W/fail.json"

        cp "$OLDCFG" "$C"; : > "$STUB_LOG"
        node "$WJS" "$WORK/webui-write-page.js" "$W" "$SC" "$NEWTXT" "$W/ok.json" 2> "$W/ok.err"
        if [ "$SC" = save ]; then
            check "webui $SC: saved text stored byte for byte" cmp -s "$NEWCFG" "$C"
        else
            check "webui $SC: imported text written" has_line "$C" "$(sed -n 2p "$NEWCFG")"
        fi
        check "webui $SC: write leaves no temp file" test -z "$(find "$MOD" -maxdepth 1 -name 'custom.pif.prop?*' ! -name custom.pif.prop.bak)"
        check "webui $SC: write reported as done" grep -q "✓" "$W/ok.json"
        check "webui $SC: write runs killpi.sh" grep -q "^killall" "$STUB_LOG"
    done

    new_root
    C="$MOD/custom.pif.prop"
    mkdir -p "$C/x"
    node "$WJS" "$WORK/webui-write-page.js" "$W" delete /dev/null "$W/del-fail.json" 2> "$W/del-fail.err"
    check "webui delete: harness ran (failing removal)" test -s "$W/del-fail.json"
    check "webui delete: failed removal not reported as done" sh -c 'test -s "$1" && ! grep -q "✓\|Deleted custom.pif.prop" "$1"' - "$W/del-fail.json"
    rm -rf "$C"; cp "$OLDCFG" "$C"
    node "$WJS" "$WORK/webui-write-page.js" "$W" delete /dev/null "$W/del-ok.json" 2> "$W/del-ok.err"
    check "webui delete: custom.pif.prop removed" test ! -e "$C"
    check "webui delete: removal reported as done" grep -q "✓ custom.pif.prop deleted" "$W/del-ok.json"

    # Manual Edit with an empty or blank editor: refused before the backup, nothing written
    new_root
    C="$MOD/custom.pif.prop"
    cp "$OLDCFG" "$C"; printf 'MODEL=Older Backup\n' > "$C.bak"; cp "$C.bak" "$W/bak.orig"
    printf '  \n\n' > "$W/blank.txt"
    node "$WJS" "$WORK/webui-write-page.js" "$W" save "$W/blank.txt" "$W/blank.json" 2> "$W/blank.err"
    check "webui save blank: harness ran" test -s "$W/blank.json"
    check "webui save blank: custom.pif.prop unchanged" cmp -s "$OLDCFG" "$C"
    check "webui save blank: backup not overwritten" cmp -s "$W/bak.orig" "$C.bak"
    check "webui save blank: refused, not reported as done" sh -c 'test -s "$1" && grep -q "Save failed" "$1" && ! grep -q "✓\|killpi.sh" "$1"' - "$W/blank.json"

    # Manual Edit backup: no config -> no backup message and the save proceeds; a failed copy aborts the save
    new_root
    C="$MOD/custom.pif.prop"
    node "$WJS" "$WORK/webui-write-page.js" "$W" save "$NEWTXT" "$W/nocfg.json" 2> "$W/nocfg.err"
    check "webui save without config: text stored" cmp -s "$NEWCFG" "$C"
    check "webui save without config: no backup message" sh -c 'test -s "$1" && ! grep -q "Backed up" "$1"' - "$W/nocfg.json"
    check "webui save without config: no backup file" test ! -e "$C.bak"
    cp "$OLDCFG" "$C"
    mkdir -p "$W/failcp"
    printf '#!/bin/sh\nexit 1\n' > "$W/failcp/cp"; chmod 755 "$W/failcp/cp"
    PATH="$W/failcp:$PATH" node "$WJS" "$WORK/webui-write-page.js" "$W" save "$NEWTXT" "$W/cpfail.json" 2> "$W/cpfail.err"
    check "webui save, backup fails: custom.pif.prop unchanged" cmp -s "$OLDCFG" "$C"
    check "webui save, backup fails: aborted, not reported as done" sh -c 'test -s "$1" && grep -q "Save failed" "$1" && ! grep -q "✓\|killpi.sh\|Backed up" "$1"' - "$W/cpfail.json"

    # setFlag: a failed sed (stub) or a missing custom.pif.prop is not reported as set and kills nothing
    new_root
    C="$MOD/custom.pif.prop"
    printf 'MODEL=Pixel\nspoofBuild=1\n' > "$C"
    node "$WJS" "$WORK/webui-write-page.js" "$W" setflag spoofBuild=0 "$W/flag-ok.json" 2> "$W/flag-ok.err"
    check "webui setFlag: value set" has_line "$C" "spoofBuild=0"
    check "webui setFlag: reported and Play processes killed" sh -c 'grep -q "Spoof Build off" "$1" && grep -q "killpi.sh" "$1"' - "$W/flag-ok.json"
    mkdir -p "$W/failsed"
    printf '#!/bin/sh\nexit 1\n' > "$W/failsed/sed"; chmod 755 "$W/failsed/sed"
    PATH="$W/failsed:$PATH" node "$WJS" "$WORK/webui-write-page.js" "$W" setflag spoofBuild=1 "$W/flag-fail.json" 2> "$W/flag-fail.err"
    check "webui setFlag, sed fails: not reported as set, nothing killed" sh -c 'test -s "$1" && ! grep -q "Spoof Build on\|Set spoofBuild\|killpi.sh" "$1"' - "$W/flag-fail.json"
    rm -f "$C"
    node "$WJS" "$WORK/webui-write-page.js" "$W" setflag spoofBuild=1 "$W/flag-nocfg.json" 2> "$W/flag-nocfg.err"
    check "webui setFlag without custom.pif.prop: not reported as set, nothing killed" sh -c 'test -s "$1" && ! grep -q "Spoof Build on\|Set spoofBuild\|killpi.sh" "$1"' - "$W/flag-nocfg.json"
    check "webui setFlag without custom.pif.prop: no file created" test ! -e "$C"

    # setMode: a failed touch (stub) or rm (directory in the way) is not logged as done
    node "$WJS" "$WORK/webui-write-page.js" "$W" setmode random "$W/mode-ok.json" 2> "$W/mode-ok.err"
    check "webui setMode random: marker created and logged" sh -c 'test -f "$1" && grep -q "Create skipmatchdevice" "$2"' - "$MOD/skipmatchdevice" "$W/mode-ok.json"
    rm -f "$MOD/skipmatchdevice"
    mkdir -p "$W/failtouch"
    printf '#!/bin/sh\nexit 1\n' > "$W/failtouch/touch"; chmod 755 "$W/failtouch/touch"
    PATH="$W/failtouch:$PATH" node "$WJS" "$WORK/webui-write-page.js" "$W" setmode random "$W/mode-fail.json" 2> "$W/mode-fail.err"
    check "webui setMode random, touch fails: not logged as done" sh -c 'test -s "$1" && ! grep -q "Create skipmatchdevice" "$1"' - "$W/mode-fail.json"
    mkdir -p "$MOD/skipmatchdevice/x"
    node "$WJS" "$WORK/webui-write-page.js" "$W" setmode match "$W/mode-rmfail.json" 2> "$W/mode-rmfail.err"
    check "webui setMode match, rm fails: not logged as done" sh -c 'test -s "$1" && ! grep -q "Remove skipmatchdevice" "$1"' - "$W/mode-rmfail.json"
fi
