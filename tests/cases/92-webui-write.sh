# WebUI config writes (module/webroot/index.html): the real inline script runs under node
# with a minimal fake DOM; ksu.exec runs each command with sh in the fake root (lib.sh path rewrite).
# A write that fails must leave the old custom.pif.prop as it was, leave no temp file, and not be
# reported as done (no success log, no migrate.sh or killpi.sh). A write that works stores
# the text byte for byte.

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
let lastLoad = null;
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
  await idle();
  fs.writeFileSync(outFile, JSON.stringify({ logs: term.children.map(s => s.textContent), toasts, cmds }, null, 1));
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
fi
