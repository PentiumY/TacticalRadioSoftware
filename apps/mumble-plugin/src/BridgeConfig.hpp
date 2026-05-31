#pragma once

#include <cstdint>
#include <cstdlib>
#include <string>

struct BridgeConfig {
    std::string baseUrl = "http://127.0.0.1:3000";
    std::uint64_t placeId = 16489784096;
    std::string jobId = "studio-local";
    std::uint64_t localRobloxUserId = 2026345646;
    std::string localRobloxUsername;
    int pollIntervalMs = 200;
};

inline std::string getEnvString(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);

    if (!value || std::string(value).empty()) {
        return fallback;
    }

    return value;
}

inline std::uint64_t getEnvUint64(const char* name, std::uint64_t fallback) {
    const char* value = std::getenv(name);

    if (!value) {
        return fallback;
    }

    try {
        return static_cast<std::uint64_t>(std::stoull(value));
    } catch (...) {
        return fallback;
    }
}

inline BridgeConfig loadBridgeConfig() {
    BridgeConfig config;

    config.baseUrl = getEnvString("TRADIO_BASE_URL", config.baseUrl);
    config.jobId = getEnvString("TRADIO_JOB_ID", config.jobId);
    config.placeId = getEnvUint64("TRADIO_PLACE_ID", config.placeId);

    config.localRobloxUserId = getEnvUint64(
        "TRADIO_ROBLOX_USER_ID",
        config.localRobloxUserId
    );

    config.localRobloxUsername = getEnvString(
        "TRADIO_ROBLOX_USERNAME",
        config.localRobloxUsername
    );

    return config;
}