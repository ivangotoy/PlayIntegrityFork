#include <android/log.h>
#include <sys/system_properties.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <mutex>

#include "zygisk.hpp"
#include "json/single_include/nlohmann/json.hpp"
#include "shadowhook.h"

#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, "PIF/Native", __VA_ARGS__)

#define DEX_FILE_PATH "/data/adb/modules/playintegrityfork/classes.dex"

#define PROP_FILE_PATH "/data/adb/modules/playintegrityfork/pif.prop"
#define CUSTOM_PROP_FILE_PATH "/data/adb/modules/playintegrityfork/custom.pif.prop"

#define JSON_FILE_PATH "/data/adb/modules/playintegrityfork/pif.json"
#define CUSTOM_JSON_FILE_PATH "/data/adb/modules/playintegrityfork/custom.pif.json"

#define VENDING_PACKAGE "com.android.vending"
#define DROIDGUARD_PACKAGE "com.google.android.gms.unstable"

static int verboseLogs = 0;
static int spoofBuild = 1;
static int spoofProps = 1;
static int spoofProvider = 1;
static int spoofSignature = 0;
static int spoofVendingFinger = 0;
static int spoofVendingSdk = 0;

static std::map<std::string, std::string> jsonProps;

typedef void (*T_Callback)(void *, const char *, const char *, uint32_t);

static std::map<void *, T_Callback> callbacks;
static std::mutex callbacksMutex;

static void modify_callback(void *cookie, const char *name, const char *value, uint32_t serial) {
    if (cookie == nullptr || name == nullptr || value == nullptr) return;
    T_Callback callback;
    {
        std::lock_guard<std::mutex> lock(callbacksMutex);
        auto it = callbacks.find(cookie);
        if (it == callbacks.end()) return;
        callback = it->second;
    }

    const char *oldValue = value;

    std::string prop(name);

    if (jsonProps.count(prop)) {
        // Exact property match
        value = jsonProps[prop].c_str();
    } else {
        // Leading * wildcard property match
        for (const auto &p: jsonProps) {
            if (p.first.starts_with("*") && prop.ends_with(p.first.substr(1))) {
                value = p.second.c_str();
                break;
            }
        }
    }

    if (oldValue == value) {
        if (verboseLogs > 99) LOGD("[%s]: %s (unchanged)", name, oldValue);
    } else {
        LOGD("[%s]: %s -> %s", name, oldValue, value);
    }

    return callback(cookie, name, value, serial);
}

static void (*o_system_property_read_callback)(const prop_info *, T_Callback, void *);

static void my_system_property_read_callback(const prop_info *pi, T_Callback callback, void *cookie) {
    if (pi == nullptr || callback == nullptr || cookie == nullptr) {
        return o_system_property_read_callback(pi, callback, cookie);
    }
    {
        std::lock_guard<std::mutex> lock(callbacksMutex);
        callbacks[cookie] = callback;
    }
    return o_system_property_read_callback(pi, modify_callback, cookie);
}

#include <dlfcn.h>

extern "C" int sh_linker_init(void) {
    return 0;
}

static void doHook() {
    shadowhook_init(SHADOWHOOK_MODE_UNIQUE, false);

    void *sym_addr = dlsym(RTLD_DEFAULT, "__system_property_read_callback");
    if (sym_addr == nullptr) {
        LOGD("Couldn't find '__system_property_read_callback' via dlsym");
        return;
    }

    void *handle = shadowhook_hook_sym_addr(
            sym_addr,
            reinterpret_cast<void *>(my_system_property_read_callback),
            reinterpret_cast<void **>(&o_system_property_read_callback)
    );

    if (handle == nullptr) {
        LOGD("Couldn't hook '__system_property_read_callback'. Error: %d", shadowhook_get_errno());
        return;
    }
    LOGD("Found '__system_property_read_callback' handle at %p", handle);
}

static void setFieldNative(JNIEnv *env, jclass /* clazz_EntryPoint */, jclass targetClass, jobject fieldObj, jstring typeObj, jobject valueObj) {
    if (!targetClass || !fieldObj || !typeObj) return;

    jfieldID fieldID = env->FromReflectedField(fieldObj);
    if (!fieldID) return;

    const char *typeName = env->GetStringUTFChars(typeObj, nullptr);

    if (strcmp(typeName, "java.lang.String") == 0) {
        env->SetStaticObjectField(targetClass, fieldID, valueObj);
    } else if (strcmp(typeName, "int") == 0) {
        jclass intClass = env->FindClass("java/lang/Integer");
        jmethodID intValue = env->GetMethodID(intClass, "intValue", "()I");
        jint val = env->CallIntMethod(valueObj, intValue);
        env->SetStaticIntField(targetClass, fieldID, val);
    } else if (strcmp(typeName, "long") == 0) {
        jclass longClass = env->FindClass("java/lang/Long");
        jmethodID longValue = env->GetMethodID(longClass, "longValue", "()J");
        jlong val = env->CallLongMethod(valueObj, longValue);
        env->SetStaticLongField(targetClass, fieldID, val);
    } else if (strcmp(typeName, "boolean") == 0) {
        jclass boolClass = env->FindClass("java/lang/Boolean");
        jmethodID booleanValue = env->GetMethodID(boolClass, "booleanValue", "()Z");
        jboolean val = env->CallBooleanMethod(valueObj, booleanValue);
        env->SetStaticBooleanField(targetClass, fieldID, val);
    }

    env->ReleaseStringUTFChars(typeObj, typeName);
}

static int toInt(const std::string &text, int fallback) {
    errno = 0;
    char *end = nullptr;
    long value = strtol(text.c_str(), &end, 10);
    if (end == text.c_str() || errno == ERANGE || value < INT_MIN || value > INT_MAX) {
        LOGD("Couldn't parse '%s' as a number, keeping %d", text.c_str(), fallback);
        return fallback;
    }
    return static_cast<int>(value);
}

// Replace bytes that are not valid UTF-8 (as nlohmann::json requires inside strings) with U+FFFD
static std::string sanitizeUtf8(const std::string &text) {
    std::string out;
    size_t i = 0;
    while (i < text.size()) {
        auto c = static_cast<unsigned char>(text[i]);
        size_t len = 0;
        unsigned char lo = 0x80, hi = 0xBF;
        if (c < 0x80) len = 1;
        else if (c >= 0xC2 && c <= 0xDF) len = 2;
        else if (c >= 0xE0 && c <= 0xEF) { len = 3; if (c == 0xE0) lo = 0xA0; if (c == 0xED) hi = 0x9F; }
        else if (c >= 0xF0 && c <= 0xF4) { len = 4; if (c == 0xF0) lo = 0x90; if (c == 0xF4) hi = 0x8F; }
        bool valid = len > 0 && i + len <= text.size();
        for (size_t k = 1; valid && k < len; k++) {
            auto cc = static_cast<unsigned char>(text[i + k]);
            if (cc < (k == 1 ? lo : 0x80) || cc > (k == 1 ? hi : 0xBF)) valid = false;
        }
        if (valid) {
            out.append(text, i, len);
            i += len;
        } else {
            out += "\xEF\xBF\xBD";
            i++;
        }
    }
    return out;
}

// Escape a " and a \ that starts no valid JSON escape; valid escapes are kept as they are
static std::string escapeStrayJson(const std::string &text) {
    auto isHex = [](char h) { return (h >= '0' && h <= '9') || (h >= 'a' && h <= 'f') || (h >= 'A' && h <= 'F'); };
    std::string out;
    for (size_t i = 0; i < text.size(); i++) {
        char c = text[i];
        char next = i + 1 < text.size() ? text[i + 1] : '\0';
        if (c == '"') {
            out += "\\\"";
        } else if (c != '\\') {
            out += c;
        } else if (next == '"' || next == '\\' || next == '/' || next == 'b' || next == 'f' || next == 'n' || next == 'r' || next == 't') {
            out += c;
            out += next;
            i++;
        } else if (next == 'u' && i + 5 < text.size() && isHex(text[i + 2]) && isHex(text[i + 3]) && isHex(text[i + 4]) && isHex(text[i + 5])) {
            out.append(text, i, 6);
            i += 5;
        } else {
            out += "\\\\";
        }
    }
    return out;
}

// Companion IO: whole buffers only, retrying short counts and EINTR; false on EOF or error
static bool readFully(int fd, void *buffer, size_t length) {
    auto *p = static_cast<char *>(buffer);
    while (length > 0) {
        ssize_t n = read(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        length -= static_cast<size_t>(n);
    }
    return true;
}

static bool writeFully(int fd, const void *buffer, size_t length) {
    auto *p = static_cast<const char *>(buffer);
    while (length > 0) {
        ssize_t n = write(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        length -= static_cast<size_t>(n);
    }
    return true;
}

// far above the module's classes.dex and any config file
#define MAX_COMPANION_SIZE (64L * 1024 * 1024)

// Receives dex size, config size, dex, config; false (nothing usable) unless all of it arrived
static bool receiveFromCompanion(int fd, std::vector<char> &dexVector, std::vector<char> &configVector) {
    long dexSize = 0, configSize = 0;

    if (fd < 0 || !readFully(fd, &dexSize, sizeof(long)) || !readFully(fd, &configSize, sizeof(long))) {
        LOGD("Couldn't read from companion");
        return false;
    }

    if (dexSize < 1 || dexSize > MAX_COMPANION_SIZE) {
        LOGD("Couldn't read dex file");
        return false;
    }

    if (configSize < 1 || configSize > MAX_COMPANION_SIZE) {
        LOGD("Couldn't read config file");
        return false;
    }

    LOGD("Read from file descriptor for 'dex' -> %ld bytes", dexSize);
    LOGD("Read from file descriptor for 'config' -> %ld bytes", configSize);

    dexVector.resize(dexSize);
    configVector.resize(configSize);
    if (!readFully(fd, dexVector.data(), dexSize) || !readFully(fd, configVector.data(), configSize)) {
        LOGD("Companion data ended early");
        dexVector.clear();
        configVector.clear();
        return false;
    }
    return true;
}

class PlayIntegrityFix : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api = api;
        this->env = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        bool isGms = false, isDroidGuardOrVending = false;

        auto rawProcess = env->GetStringUTFChars(args->nice_name, nullptr);
        auto rawDir = env->GetStringUTFChars(args->app_data_dir, nullptr);

        // Prevent crash on apps with no data dir
        if (rawDir == nullptr) {
            env->ReleaseStringUTFChars(args->nice_name, rawProcess);
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        pkgName = rawProcess;
        std::string_view dir(rawDir);

        isGms = dir.ends_with("/com.google.android.gms") || dir.ends_with("/com.android.vending");
        isDroidGuardOrVending = pkgName == DROIDGUARD_PACKAGE || pkgName == VENDING_PACKAGE;

        env->ReleaseStringUTFChars(args->nice_name, rawProcess);
        env->ReleaseStringUTFChars(args->app_data_dir, rawDir);

        if (!isGms) {
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        // We are in GMS now, force unmount
        api->setOption(zygisk::FORCE_DENYLIST_UNMOUNT);

        if (!isDroidGuardOrVending) {
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        std::vector<char> configVector;

        int fd = api->connectCompanion();
        bool received = receiveFromCompanion(fd, dexVector, configVector);
        if (fd >= 0) close(fd);

        if (!received) {
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        std::string configString(configVector.cbegin(), configVector.cend());

        if (!nlohmann::json::accept(configString, true)) configString = sanitizeUtf8(configString);
        if (!nlohmann::json::accept(configString, true)) {
            LOGD("Converting config from prop format to JSON format");

            configString.erase(std::remove(configString.begin(), configString.end(), '\r'), configString.end());

            std::string jsonString = "{";
            std::vector<std::pair<std::string, std::string>> entries;
            char propDelimiter = '=';
            char commentDelimiter = '#';
            size_t beginPos = 0, endPos = 0;
            while (beginPos < configString.size()) {
                endPos = configString.find('\n', beginPos);
                if (endPos == std::string::npos) endPos = configString.size();
                std::string line = configString.substr(beginPos, endPos - beginPos);
                beginPos = endPos + 1;
                if (line.empty() || line[0] == '#') continue;
                std::string name, value;
                size_t propDelimiterPos = line.find(propDelimiter);
                if (propDelimiterPos != std::string::npos) {
                    name = line.substr(0, propDelimiterPos);
                    value = line.substr(propDelimiterPos + 1);
                } else {
                    LOGD("Invalid prop entry, skipping");
                    continue;
                }
                size_t commentDelimiterPos = value.find(commentDelimiter);
                if (commentDelimiterPos != std::string::npos) {
                    value = value.substr(0, commentDelimiterPos);
                    size_t lastPos = value.find_last_not_of(" ");
                    if (lastPos != std::string::npos) value.resize(lastPos + 1);
                }
                // trailing blanks are not part of a value, as for migrate.sh, autopif4.sh and the WebUI
                value.erase(value.find_last_not_of(" \t") + 1);
                for (std::string *field : {&name, &value}) {
                    std::string escaped;
                    for (unsigned char c : *field) {
                        if (c < 0x20) {
                            char hex[7];
                            snprintf(hex, sizeof(hex), "\\u%04x", c);
                            escaped += hex;
                        } else {
                            escaped += static_cast<char>(c);
                        }
                    }
                    *field = escaped;
                }
                jsonString += "\n\"" + name + "\": \"" + value + "\",";
                entries.emplace_back(name, value);
            }
            if (jsonString.back() == ',') jsonString.pop_back();
            jsonString += "\n}\n";

            if (!nlohmann::json::accept(jsonString, true)) {
                LOGD("Escaping stray quotes and backslashes in prop values");
                jsonString = "{";
                for (const auto &[entryName, entryValue] : entries) {
                    jsonString += "\n\"" + escapeStrayJson(entryName) + "\": \"" + escapeStrayJson(entryValue) + "\",";
                }
                if (jsonString.back() == ',') jsonString.pop_back();
                jsonString += "\n}\n";
            }

            configString = jsonString;

            jsonString.clear();
        }

        json = nlohmann::json::parse(configString, nullptr, false, true);
        if (json.is_discarded() || !json.is_object()) {
            LOGD("Couldn't parse config file");
            json = nullptr;
            dexVector.clear();
            api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        configVector.clear();
        configString.clear();
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *args) override {
        if (dexVector.empty() || json.empty()) return;

        readJson();

        if (pkgName == VENDING_PACKAGE) spoofBuild = spoofProps = spoofProvider = spoofSignature = 0;
        else spoofVendingFinger = spoofVendingSdk = 0;

        if (spoofProps > 0) doHook();
        if (spoofBuild + spoofProvider + spoofSignature + spoofVendingFinger + spoofVendingSdk > 0) inject();

        dexVector.clear();
        json.clear();
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *args) override {
        api->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
    }

private:
    zygisk::Api *api = nullptr;
    JNIEnv *env = nullptr;
    std::vector<char> dexVector;
    nlohmann::json json;
    std::string pkgName;
    std::string vendingFingerprintValue;

    void readJson() {
        LOGD("JSON contains %d keys!", static_cast<int>(json.size()));

        // Verbose logging level
        if (json.contains("verboseLogs")) {
            if (!json["verboseLogs"].is_null() && json["verboseLogs"].is_string() && json["verboseLogs"] != "") {
                verboseLogs = toInt(json["verboseLogs"].get<std::string>(), verboseLogs);
                if (verboseLogs > 0) LOGD("Verbose logging (level %d) enabled!", verboseLogs);
            } else {
                LOGD("Error parsing verboseLogs!");
            }
            json.erase("verboseLogs");
        }

        // Vending advanced spoofing settings
        if (json.contains("spoofVendingSdk")) {
            if (!json["spoofVendingSdk"].is_null() && json["spoofVendingSdk"].is_string() && json["spoofVendingSdk"] != "") {
                spoofVendingSdk = toInt(json["spoofVendingSdk"].get<std::string>(), spoofVendingSdk);
                if (verboseLogs > 0) LOGD("Spoofing SDK Level in Play Store %s!", (spoofVendingSdk > 0) ? "enabled" : "disabled");
            } else {
                LOGD("Error parsing spoofVendingSdk!");
            }
            json.erase("spoofVendingSdk");
        }
        if (json.contains("spoofVendingFinger")) {
            if (!json["spoofVendingFinger"].is_null() && json["spoofVendingFinger"].is_string() && json["spoofVendingFinger"] != "") {
                if (json["spoofVendingFinger"].get<std::string>().find_first_not_of("01") != std::string::npos) {
                    spoofVendingFinger = 1;
                    vendingFingerprintValue = json["spoofVendingFinger"].get<std::string>();
                } else if (json.contains("FINGERPRINT") && !json["FINGERPRINT"].is_null() && json["FINGERPRINT"].is_string() && json["FINGERPRINT"] != "") {
                    spoofVendingFinger = toInt(json["spoofVendingFinger"].get<std::string>(), spoofVendingFinger);
                    vendingFingerprintValue = json["FINGERPRINT"].get<std::string>();
                } else {
                    LOGD("Error parsing spoofVendingFinger or FINGERPRINT field!");
                }
                if (verboseLogs > 0) LOGD("Spoofing Fingerprint in Play Store %s!", (spoofVendingFinger > 0) ? "enabled" : "disabled");
            } else {
                LOGD("Error parsing spoofVendingFinger!");
            }
            json.erase("spoofVendingFinger");
        }
        if (pkgName == VENDING_PACKAGE) {
            json.clear();
            return;
        }

        // DroidGuard advanced spoofing settings
        if (json.contains("spoofBuild")) {
            if (!json["spoofBuild"].is_null() && json["spoofBuild"].is_string() && json["spoofBuild"] != "") {
                spoofBuild = toInt(json["spoofBuild"].get<std::string>(), spoofBuild);
                if (verboseLogs > 0) LOGD("Spoofing Build Fields %s!", (spoofBuild > 0) ? "enabled" : "disabled");
            } else {
                LOGD("Error parsing spoofBuild!");
            }
            json.erase("spoofBuild");
        }
        if (json.contains("spoofProps")) {
            if (!json["spoofProps"].is_null() && json["spoofProps"].is_string() && json["spoofProps"] != "") {
                spoofProps = toInt(json["spoofProps"].get<std::string>(), spoofProps);
                if (verboseLogs > 0) LOGD("Spoofing System Properties %s!", (spoofProps > 0) ? "enabled" : "disabled");
            } else {
                LOGD("Error parsing spoofProps!");
            }
            json.erase("spoofProps");
        }
        if (json.contains("spoofProvider")) {
            if (!json["spoofProvider"].is_null() && json["spoofProvider"].is_string() && json["spoofProvider"] != "") {
                spoofProvider = toInt(json["spoofProvider"].get<std::string>(), spoofProvider);
                if (verboseLogs > 0) LOGD("Spoofing Keystore Provider %s!", (spoofProvider > 0) ? "enabled" : "disabled");
            } else {
                LOGD("Error parsing spoofProvider!");
            }
            json.erase("spoofProvider");
        }
        if (json.contains("spoofSignature")) {
            if (!json["spoofSignature"].is_null() && json["spoofSignature"].is_string() && json["spoofSignature"] != "") {
                spoofSignature = toInt(json["spoofSignature"].get<std::string>(), spoofSignature);
                if (verboseLogs > 0) LOGD("Spoofing ROM Signature %s!", (spoofSignature > 0) ? "enabled" : "disabled");
            } else {
                LOGD("Error parsing spoofSignature!");
            }
            json.erase("spoofSignature");
        }

        std::vector<std::string> eraseKeys;
        for (auto &jsonList: json.items()) {
            if (verboseLogs > 1) LOGD("Parsing %s", jsonList.key().c_str());
            if (jsonList.key().find_first_of("*.") != std::string::npos) {
                // Name contains . or * (wildcard) so assume real property name
                if (!jsonList.value().is_null() && jsonList.value().is_string()) {
                    if (jsonList.value() == "") {
                        LOGD("%s is empty, skipping", jsonList.key().c_str());
                    } else {
                        if (verboseLogs > 0) LOGD("Adding '%s' to properties list", jsonList.key().c_str());
                        jsonProps[jsonList.key()] = jsonList.value();
                    }
                } else {
                    LOGD("Error parsing %s!", jsonList.key().c_str());
                }
                eraseKeys.push_back(jsonList.key());
            }
        }
        // Remove properties from parsed JSON
        for (auto key: eraseKeys) {
            if (json.contains(key)) json.erase(key);
        }
    }

    void inject() {
        const char* niceName = pkgName == VENDING_PACKAGE ? "PS" : "DG";

        LOGD("JNI %s: Getting system classloader", niceName);
        auto clClass = env->FindClass("java/lang/ClassLoader");
        auto getSystemClassLoader = env->GetStaticMethodID(clClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        auto systemClassLoader = env->CallStaticObjectMethod(clClass, getSystemClassLoader);

        LOGD("JNI %s: Creating module classloader", niceName);
        auto dexClClass = env->FindClass("dalvik/system/InMemoryDexClassLoader");
        auto dexClInit = env->GetMethodID(dexClClass, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
        auto buffer = env->NewDirectByteBuffer(dexVector.data(), static_cast<jlong>(dexVector.size()));
        auto dexCl = env->NewObject(dexClClass, dexClInit, buffer, systemClassLoader);

        LOGD("JNI %s: Loading module class", niceName);
        auto loadClass = env->GetMethodID(clClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
        const char* className = pkgName == VENDING_PACKAGE ? "es.chiteroman.playintegrityfix.EntryPointVending" : "es.chiteroman.playintegrityfix.EntryPoint";
        auto entryClassName = env->NewStringUTF(className);
        auto entryClassObj = env->CallObjectMethod(dexCl, loadClass, entryClassName);

        auto entryClass = (jclass) entryClassObj;

        JNINativeMethod methods[] = {
            {"setFieldNative", "(Ljava/lang/Class;Ljava/lang/reflect/Field;Ljava/lang/String;Ljava/lang/Object;)V", (void*) setFieldNative}
        };
        env->RegisterNatives(entryClass, methods, 1);

        if (pkgName == VENDING_PACKAGE) {
            LOGD("JNI %s: Calling EntryPointVending.init", niceName);
            auto entryInit = env->GetStaticMethodID(entryClass, "init", "(IIILjava/lang/String;)V");
            auto javaStr = env->NewStringUTF(vendingFingerprintValue.c_str());
            env->CallStaticVoidMethod(entryClass, entryInit, verboseLogs, spoofVendingFinger, spoofVendingSdk, javaStr);
            env->DeleteLocalRef(javaStr);
        } else {
            LOGD("JNI %s: Sending JSON", niceName);
            auto receiveJson = env->GetStaticMethodID(entryClass, "receiveJson", "(Ljava/lang/String;)V");
            auto javaStr = env->NewStringUTF(json.dump().c_str());
            env->CallStaticVoidMethod(entryClass, receiveJson, javaStr);

            LOGD("JNI %s: Calling EntryPoint.init", niceName);
            auto entryInit = env->GetStaticMethodID(entryClass, "init", "(IIII)V");
            env->CallStaticVoidMethod(entryClass, entryInit, verboseLogs, spoofBuild, spoofProvider, spoofSignature);
            env->DeleteLocalRef(javaStr);
        }
        env->DeleteLocalRef(clClass);
        env->DeleteLocalRef(systemClassLoader);
        env->DeleteLocalRef(dexClClass);
        env->DeleteLocalRef(buffer);
        env->DeleteLocalRef(dexCl);
        env->DeleteLocalRef(entryClassName);
        env->DeleteLocalRef(entryClassObj);
    }
};

static void companion(int fd) {
    long dexSize = 0, configSize = 0;
    std::vector<char> dexVector, configVector;

    FILE *dex = fopen(DEX_FILE_PATH, "rb");

    if (dex) {
        fseek(dex, 0, SEEK_END);
        dexSize = ftell(dex);
        fseek(dex, 0, SEEK_SET);

        if (dexSize < 0 || dexSize > MAX_COMPANION_SIZE) dexSize = 0;
        dexVector.resize(dexSize);
        dexSize = static_cast<long>(fread(dexVector.data(), 1, dexSize, dex));

        fclose(dex);
    }

    FILE *config = fopen(CUSTOM_PROP_FILE_PATH, "r");
    if (!config)
        config = fopen(CUSTOM_JSON_FILE_PATH, "r");
    if (!config)
        config = fopen(PROP_FILE_PATH, "r");
    if (!config)
        config = fopen(JSON_FILE_PATH, "r");

    if (config) {
        fseek(config, 0, SEEK_END);
        configSize = ftell(config);
        fseek(config, 0, SEEK_SET);

        if (configSize < 0 || configSize > MAX_COMPANION_SIZE) configSize = 0;
        configVector.resize(configSize);
        configSize = static_cast<long>(fread(configVector.data(), 1, configSize, config));

        fclose(config);
    }

    if (!writeFully(fd, &dexSize, sizeof(long)) || !writeFully(fd, &configSize, sizeof(long)) ||
        !writeFully(fd, dexVector.data(), dexSize) || !writeFully(fd, configVector.data(), configSize)) {
        LOGD("Companion couldn't send all data");
    }

    dexVector.clear();
    configVector.clear();
}

REGISTER_ZYGISK_MODULE(PlayIntegrityFix)

REGISTER_ZYGISK_COMPANION(companion)
