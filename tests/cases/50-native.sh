# Host-compiled checks of code regions extracted from app/src/main/cpp/main.cpp.
# The regions are cut out by anchor lines; nothing else of the native library is built here.

CPP="$ROOT/app/src/main/cpp/main.cpp"
CXX=""
for c in c++ g++ clang++; do command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }; done
CXXFLAGS="-std=c++23 -fno-exceptions -fno-rtti -O1"

if [ -z "$CXX" ]; then
    skip "native host checks (no C++ compiler)"
else
    N="$WORK/native"; mkdir -p "$N"

    # prop -> JSON conversion block in preAppSpecialize
    sed -n '/std::string jsonString = "{";/,/configString = jsonString;/p' "$CPP" > "$N/conv.inc"
    for h in sanitizeUtf8 escapeStrayJson; do sed -n "/^static std::string $h(/,/^}/p" "$CPP"; done > "$N/helpers.inc"
    cat > "$N/conv.cpp" <<'CPPEOF'
#include <algorithm>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>
#define LOGD(...) ((void)0)
// no json header here: every converted config counts as valid, so only the first conversion runs
namespace nlohmann { struct json { static bool accept(const std::string &, bool) { return true; } }; }
#include "helpers.inc"
static std::string convert(std::string configString) {
#include "conv.inc"
    return configString;
}
int main() { std::stringstream ss; ss << std::cin.rdbuf(); std::cout << convert(ss.str()); return 0; }
CPPEOF
    if [ -s "$N/conv.inc" ] && "$CXX" $CXXFLAGS -o "$N/conv" "$N/conv.cpp" 2> "$N/conv.err"; then
        ok "prop conversion block compiles on the host"
        printf 'MODEL=Pixel Test\n# comment\nspoofBuild=1  # c\n\n' | "$N/conv" > "$N/out1"
        printf '{\n"MODEL": "Pixel Test",\n"spoofBuild": "1"\n}\n' > "$N/exp1"
        check "prop conversion: terminated lines" cmp -s "$N/out1" "$N/exp1"
        printf 'MODEL=Pixel Test\nspoofProvider=0' | "$N/conv" > "$N/out2"
        check "prop conversion: unterminated last line kept" has_line "$N/out2" '"spoofProvider": "0"'
        printf 'MODEL=Pixel\tTest\nspoofBuild=0\t# c\n' | "$N/conv" > "$N/out3"
        check "prop conversion: control characters escaped" has_line "$N/out3" '"MODEL": "Pixel\u0009Test",'
        check "prop conversion: no raw control characters" sh -c '! tr -d "\n" < "$1" | grep -q "$(printf "\t")"' - "$N/out3"
        printf 'MODEL=Pixel \\"Q\\"\n' | "$N/conv" > "$N/out4"
        check "prop conversion: JSON escapes in values pass through" has_line "$N/out4" '"MODEL": "Pixel \"Q\""'
    else
        bad "prop conversion block compiles on the host ($(head -c 300 "$N/conv.err"))"
    fi
fi

if [ -n "$CXX" ]; then
    # numeric Advanced Settings parsing in readJson (verboseLogs line plus any helper it calls)
    sed -n '/^static int toInt(/,/^}/p' "$CPP" > "$N/num.inc"
    grep -m1 '^ *verboseLogs = .*json\["verboseLogs"\]' "$CPP" > "$N/num-line.inc"
    cat > "$N/num.cpp" <<'CPPEOF'
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <string>
#define LOGD(...) ((void)0)
#include "num.inc"
struct J { std::string v; template <class T> T get() const { return v; } };
struct JS { std::string v; J operator[](const char *) const { return J{v}; } };
static int verboseLogs = 7;
int main(int argc, char **argv) {
    JS json{argv[1]};
#include "num-line.inc"
    printf("%d\n", verboseLogs);
    return 0;
}
CPPEOF
    if [ -s "$N/num-line.inc" ] && "$CXX" $CXXFLAGS -o "$N/num" "$N/num.cpp" 2> "$N/num.err"; then
        ok "settings parse line compiles on the host"
        check "settings parse: number" test "$("$N/num" 3 2>/dev/null)" = 3
        check "settings parse: leading space and trailing text as before" test "$("$N/num" " 2x" 2>/dev/null)" = 2
        check "settings parse: non-number keeps the default" test "$("$N/num" true 2>/dev/null)" = 7
        check "settings parse: out of range keeps the default" test "$("$N/num" 99999999999999999999 2>/dev/null)" = 7
    else
        bad "settings parse line compiles on the host ($(head -c 300 "$N/num.err"))"
    fi
fi

if [ -n "$CXX" ]; then
    # helpers used when a config only fails on stray quotes/backslashes or invalid UTF-8
    for h in sanitizeUtf8 escapeStrayJson; do sed -n "/^static std::string $h(/,/^}/p" "$CPP"; done > "$N/fix.inc"
    for h in sanitizeUtf8 escapeStrayJson; do
        grep -q "^static std::string $h(" "$N/fix.inc" || echo "static std::string $h(const std::string &s) { return s; }" >> "$N/fix.inc"
    done
    cat > "$N/fix.cpp" <<'CPPEOF'
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include "fix.inc"
int main(int argc, char **argv) {
    std::stringstream ss; ss << std::cin.rdbuf();
    std::string in = ss.str();
    std::cout << (std::string(argv[1]) == "utf8" ? sanitizeUtf8(in) : escapeStrayJson(in));
    return 0;
}
CPPEOF
    if "$CXX" $CXXFLAGS -o "$N/fix" "$N/fix.cpp" 2> "$N/fix.err"; then
        fx() { printf "$2" | "$N/fix" "$1" > "$N/fx.out"; printf "$3" > "$N/fx.exp"; cmp -s "$N/fx.out" "$N/fx.exp"; }
        check "escape: valid escapes unchanged" fx esc 'a\\/b\\"c\\\\d\\u0041\\n' 'a\\/b\\"c\\\\d\\u0041\\n'
        check "escape: raw quote escaped" fx esc 'Pixel "Q"' 'Pixel \\"Q\\"'
        check "escape: stray backslash escaped" fx esc 'C:\\x' 'C:\\\\x'
        check "escape: trailing backslash escaped" fx esc 'a\\' 'a\\\\'
        check "escape: short \\u escaped" fx esc '\\u12' '\\\\u12'
        check "utf8: valid text unchanged" fx utf8 'Pixel \303\251 \342\202\254 \360\237\230\200' 'Pixel \303\251 \342\202\254 \360\237\230\200'
        check "utf8: invalid byte replaced" fx utf8 'a\377b' 'a\357\277\275b'
        check "utf8: truncated tail replaced" fx utf8 'a\342\202' 'a\357\277\275\357\277\275'
        check "utf8: overlong and surrogate replaced" fx utf8 '\300\257\355\240\200' '\357\277\275\357\277\275\357\277\275\357\277\275\357\277\275'
    else
        bad "config fix helpers compile on the host ($(head -c 300 "$N/fix.err"))"
    fi
fi
