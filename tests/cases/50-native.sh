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
    cat > "$N/conv.cpp" <<'CPPEOF'
#include <algorithm>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#define LOGD(...) ((void)0)
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
    else
        bad "prop conversion block compiles on the host ($(head -c 300 "$N/conv.err"))"
    fi
fi
