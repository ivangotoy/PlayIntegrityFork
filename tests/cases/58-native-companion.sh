# Companion IPC in main.cpp (companion() and the receiving part of preAppSpecialize), cut out by
# anchors and run on the host over socketpairs with a relay that passes the stream on in 7-byte
# chunks, as a stream socket may deliver it. The wire format is two longs, then dex, then config.

CPP="$ROOT/app/src/main/cpp/main.cpp"
CXX=""
for c in c++ g++ clang++; do command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }; done
if [ -z "$CXX" ]; then
    skip "companion IPC (no C++ compiler)"
else
    N="$WORK/native-ipc"; mkdir -p "$N"
    { sed -n '/^static bool readFully(/,/^}/p;/^static bool writeFully(/,/^}/p;/^#define MAX_COMPANION_SIZE/p' "$CPP"
      sed -n '/^static bool receiveFromCompanion(/,/^}/p' "$CPP"; } > "$N/helpers.inc"
    sed -n '/^static void companion(int fd) {/,/^}/p' "$CPP" > "$N/companion.inc"
    sed -n '/^        std::vector<char> configVector;$/,/std::string configString(configVector.cbegin()/p' "$CPP" | sed '$d' > "$N/client.inc"
    cat > "$N/ipc.cpp" <<'CPPEOF'
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>
#define LOGD(...) ((void)0)
static const char *g_dex, *g_cpp, *g_cjs, *g_pp, *g_js;
#define DEX_FILE_PATH g_dex
#define CUSTOM_PROP_FILE_PATH g_cpp
#define CUSTOM_JSON_FILE_PATH g_cjs
#define PROP_FILE_PATH g_pp
#define JSON_FILE_PATH g_js
#include "helpers.inc"
#include "companion.inc"
namespace zygisk { enum Option { DLCLOSE_MODULE_LIBRARY }; }
struct Api { int fd = -1; bool dlclose = false; int connectCompanion() { return fd; } void setOption(zygisk::Option) { dlclose = true; } };
struct Client {
    Api apiObj; Api *api = &apiObj;
    std::vector<char> dexVector, configOut;
    void run() {
#include "client.inc"
        configOut = configVector;
    }
};
static std::string slurp(const char *p) { std::string s; if (FILE *f = fopen(p, "rb")) { char b[4096]; size_t n; while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n); fclose(f); } return s; }
int main(int argc, char **argv) {
    // argv: mode(full|cut) dex config
    signal(SIGPIPE, SIG_IGN);
    g_dex = argv[2]; g_cpp = argv[3]; g_cjs = g_pp = g_js = "/nonexistent/pif";
    long cut = std::string(argv[1]) == "cut" ? 2 * (long) sizeof(long) + 20 : -1;
    int a[2], b[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, a); socketpair(AF_UNIX, SOCK_STREAM, 0, b);
    std::thread comp([&] { companion(a[0]); close(a[0]); });
    std::thread relay([&] {
        char buf[7]; long sent = 0; ssize_t n;
        while ((n = read(a[1], buf, sizeof buf)) > 0) {
            if (cut >= 0 && sent + n > cut) n = cut - sent;
            if (n > 0) { (void) !write(b[0], buf, n); sent += n; }
            if (cut >= 0 && sent >= cut) break;
            usleep(300);
        }
        close(b[0]);
        while (read(a[1], buf, sizeof buf) > 0) {}
        close(a[1]);
    });
    Client c; c.apiObj.fd = b[1]; c.run();
    comp.join(); relay.join();
    std::string dex(c.dexVector.begin(), c.dexVector.end()), cfg(c.configOut.begin(), c.configOut.end());
    printf("dlclose=%d dex_ok=%d config_ok=%d dex_size=%zu\n", (int) c.apiObj.dlclose, (int) (dex == slurp(g_dex)), (int) (cfg == slurp(g_cpp)), dex.size());
    return 0;
}
CPPEOF
    if "$CXX" -std=c++23 -O1 -I"$N" -o "$N/ipc" "$N/ipc.cpp" 2> "$N/ipc.err"; then
        ok "companion IPC regions compile on the host"
        head -c 20296 /dev/urandom > "$N/classes.dex" 2>/dev/null || awk 'BEGIN { for (i = 0; i < 20296; i++) printf "%c", 65 + i % 26 }' > "$N/classes.dex"
        printf 'MODEL=Pixel Test\nspoofBuild=1\n' > "$N/custom.pif.prop"
        "$N/ipc" full "$N/classes.dex" "$N/custom.pif.prop" > "$N/full.out" 2>&1
        check "companion IPC: chunked stream delivers dex and config whole" has_line "$N/full.out" "dlclose=0 dex_ok=1 config_ok=1 dex_size=20296"
        "$N/ipc" cut "$N/classes.dex" "$N/custom.pif.prop" > "$N/cut.out" 2>&1
        check "companion IPC: stream ending early fails closed (no dex kept)" has_line "$N/cut.out" "dlclose=1 dex_ok=0 config_ok=0 dex_size=0"
        "$N/ipc" full "$N/classes.dex" "$N/missing.prop" > "$N/nocfg.out" 2>&1
        check "companion IPC: missing config takes the no-config path" has_line "$N/nocfg.out" "dlclose=1 dex_ok=0 config_ok=1 dex_size=0"
    else
        bad "companion IPC regions compile on the host ($(head -c 300 "$N/ipc.err"))"
    fi
fi
