#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>
#include <nlohmann/json.hpp>

struct BridgeConfig {
    std::string baseUrl = "http://127.0.0.1:3000";
    std::uint64_t placeId = 0;
    std::string jobId;
    std::uint64_t localRobloxUserId = 0;
    std::string localRobloxUsername;
    bool autoSession = true;
    int pollIntervalMs = 200;
};

inline std::string getEnvString(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return value && *value ? std::string(value) : fallback;
}

inline std::uint64_t getEnvUint64(const char* name, std::uint64_t fallback) {
    const char* value = std::getenv(name);
    if (!value || !*value) return fallback;
    try { return std::stoull(value); } catch (...) { return fallback; }
}

inline std::string radioConfigPath() {
#ifdef _WIN32
    const char* appdata = std::getenv("APPDATA");
    if (appdata && *appdata) return std::string(appdata) + "\\TRS-Mumble\\radio.json";
#endif
    return "radio.json";
}

// The Qt app owns this file. Environment variables deliberately override it for debugging.
inline BridgeConfig loadBridgeConfig() {
    BridgeConfig config;
    try {
        std::ifstream input(radioConfigPath());
        if (input) {
            const auto data = nlohmann::json::parse(input);
            if (data.is_object()) {
                if (data.contains("bridgeUrl") && data["bridgeUrl"].is_string())
                    config.baseUrl = data["bridgeUrl"].get<std::string>();
                if (data.contains("robloxUsername") && data["robloxUsername"].is_string())
                    config.localRobloxUsername = data["robloxUsername"].get<std::string>();
                if (data.contains("autoSession") && data["autoSession"].is_boolean())
                    config.autoSession = data["autoSession"].get<bool>();
                if (data.contains("placeId") && data["placeId"].is_number_unsigned())
                    config.placeId = data["placeId"].get<std::uint64_t>();
                if (data.contains("jobId") && data["jobId"].is_string())
                    config.jobId = data["jobId"].get<std::string>();
            }
        }
    } catch (...) {
        // Invalid or partially written config: keep defaults until the next refresh.
    }

    config.baseUrl = getEnvString("TRADIO_BASE_URL", config.baseUrl);
    config.jobId = getEnvString("TRADIO_JOB_ID", config.jobId);
    config.placeId = getEnvUint64("TRADIO_PLACE_ID", config.placeId);
    config.localRobloxUserId = getEnvUint64("TRADIO_ROBLOX_USER_ID", config.localRobloxUserId);
    config.localRobloxUsername = getEnvString("TRADIO_ROBLOX_USERNAME", config.localRobloxUsername);
    while (!config.baseUrl.empty() && config.baseUrl.back() == '/') config.baseUrl.pop_back();
    if (config.baseUrl.empty()) config.baseUrl = "http://127.0.0.1:3000";
    config.pollIntervalMs = std::max(100, std::min(2000, config.pollIntervalMs));
    return config;
}
