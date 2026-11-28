# Config loading in preAppSpecialize against the real nlohmann/json header (the json submodule,
# or PIF_JSON_HPP): every config that parsed before parses to the same result (except trailing
# blanks of prop values, now dropped as the shell readers drop them), configs that failed only on
# stray quotes/backslashes or invalid UTF-8 now parse, and a config that still does not parse to
# an object takes the missing-config path. Skipped visibly without the header.

CPP="$ROOT/app/src/main/cpp/main.cpp"
HPP="${PIF_JSON_HPP:-$ROOT/app/src/main/cpp/json/single_include/nlohmann/json.hpp}"
CXX=""
for c in c++ g++ clang++; do command -v "$c" >/dev/null 2>&1 && { CXX="$c"; break; }; done
if [ -z "$CXX" ] || [ ! -f "$HPP" ]; then
    skip "native config corpus (needs a C++ compiler and the json submodule header)"
else
    N="$WORK/native-config"; mkdir -p "$N"
    sed -n '/std::string configString(configVector.cbegin()/,/configString.clear();/p' "$CPP" > "$N/load.inc"
    for h in sanitizeUtf8 escapeStrayJson; do sed -n "/^static std::string $h(/,/^}/p" "$CPP"; done > "$N/helpers.inc"
    cat > "$N/load.cpp" <<CPPEOF
#include <algorithm>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include "$HPP"
#define LOGD(...) ((void)0)
#include "helpers.inc"
namespace zygisk { enum Option { DLCLOSE_MODULE_LIBRARY }; }
struct Api { bool dlclose = false; void setOption(zygisk::Option) { dlclose = true; } };
struct Module {
    Api apiObj; Api *api = &apiObj;
    std::vector<char> dexVector{'d'};
    nlohmann::json json;
    void load(const std::string &input) {
        std::vector<char> configVector(input.begin(), input.end());
#include "load.inc"
    }
};
int main() {
    std::stringstream ss; ss << std::cin.rdbuf();
    Module m; m.load(ss.str());
    if (m.api->dlclose || m.dexVector.empty()) printf("SKIPPED dlclose=%d dex=%zu\n", (int)m.api->dlclose, m.dexVector.size());
    else printf("%s\n", m.json.dump().c_str());
    return 0;
}
CPPEOF
    if "$CXX" -std=c++23 -fno-exceptions -fno-rtti -O1 -I"$N" -o "$N/load" "$N/load.cpp" 2> "$N/load.err"; then
        ok "config load region compiles with the json header"
        for f in "$ROOT"/tests/fixtures/native/*.prop; do
            b="$(basename "$f" .prop)"
            "$N/load" < "$f" > "$N/$b.out" 2>&1
            check "config corpus $b" cmp -s "$N/$b.out" "${f%.prop}.expected"
        done
    else
        bad "config load region compiles with the json header ($(head -c 300 "$N/load.err"))"
    fi
fi
