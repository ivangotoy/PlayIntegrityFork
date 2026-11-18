# Property read hook (modify_callback / my_system_property_read_callback in main.cpp) under
# ThreadSanitizer: threads read properties through the hook concurrently, each with its own
# stack cookie, as Java threads do via SystemProperties. Skipped visibly without TSan.

CPP="$ROOT/app/src/main/cpp/main.cpp"
N="$WORK/native-cb"; mkdir -p "$N"
TSAN_CXX=""
printf '#include <thread>\nint main(){std::thread t([]{}); t.join(); return 0;}\n' > "$N/probe.cpp"
for c in c++ g++ clang++; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -std=c++23 -fsanitize=thread -o "$N/probe" "$N/probe.cpp" 2>/dev/null && "$N/probe" >/dev/null 2>&1; then TSAN_CXX="$c"; break; fi
done
if [ -z "$TSAN_CXX" ]; then
    skip "property hook concurrency (no working ThreadSanitizer)"
else
    sed -n '/^typedef void (\*T_Callback)/,/^#include <dlfcn.h>/p' "$CPP" | sed '$d' > "$N/hook.inc"
    cat > "$N/hook.cpp" <<'CPPEOF'
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#define LOGD(...) ((void)0)
struct prop_info { const char *name; const char *value; };
static int verboseLogs = 0;
static std::map<std::string, std::string> jsonProps = {{"ro.zz.spoofed", "new"}, {"*.zz.tail", "tail"}};
#include "hook.inc"
static void real_read_callback(const prop_info *pi, T_Callback cb, void *cookie) { cb(cookie, pi->name, pi->value, 1); }
static std::atomic<int> wrong{0};
static void store(void *cookie, const char *, const char *value, uint32_t) { *static_cast<std::string *>(cookie) = value; }
int main() {
    o_system_property_read_callback = real_read_callback;
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; t++) threads.emplace_back([] {
        prop_info a{"ro.zz.spoofed", "old"}, b{"ro.zz.other", "same"}, c{"vendor.zz.tail", "x"};
        for (int i = 0; i < 2000; i++) {
            std::string v1, v2, v3;
            my_system_property_read_callback(&a, store, &v1);
            my_system_property_read_callback(&b, store, &v2);
            my_system_property_read_callback(&c, store, &v3);
            if (v1 != "new" || v2 != "same" || v3 != "tail") wrong++;
        }
    });
    for (auto &t : threads) t.join();
    printf("wrong=%d\n", wrong.load());
    return wrong.load() != 0;
}
CPPEOF
    if "$TSAN_CXX" -std=c++23 -fsanitize=thread -g -O1 -o "$N/hook" "$N/hook.cpp" 2> "$N/hook.err"; then
        ok "property hook region compiles with TSan"
        TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$N/hook" > "$N/hook.out" 2>&1
        rc=$?
        check "property hook: no data race under concurrent reads (exit $rc)" test "$rc" -eq 0
        check "property hook: every read returns the spoofed or original value" has_line "$N/hook.out" "wrong=0"
    else
        bad "property hook region compiles with TSan ($(head -c 300 "$N/hook.err"))"
    fi
fi
