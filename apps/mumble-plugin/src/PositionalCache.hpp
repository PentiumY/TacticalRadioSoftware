#pragma once

#include "SharedState.hpp"

#include <cstddef>
#include <mutex>
#include <optional>
#include <string>

struct CachedPositionalData {
    bool valid = false;

    float avatarPos[3] = {0.0f, 0.0f, 0.0f};
    float avatarDir[3] = {0.0f, 0.0f, -1.0f};
    float avatarAxis[3] = {0.0f, 1.0f, 0.0f};

    float cameraPos[3] = {0.0f, 0.0f, 0.0f};
    float cameraDir[3] = {0.0f, 0.0f, -1.0f};
    float cameraAxis[3] = {0.0f, 1.0f, 0.0f};

    std::string status;
    std::string username;
    std::size_t playerCount = 0;
};

class PositionalCache {
public:
    void invalidate(const std::string& status) noexcept;
    void update(const PluginSnapshot& snapshot, const PlayerRadioState& me, const std::string& mumbleUsername) noexcept;
    CachedPositionalData snapshot() const noexcept;

    bool copyToMumble(
        float* avatarPos,
        float* avatarDir,
        float* avatarAxis,
        float* cameraPos,
        float* cameraDir,
        float* cameraAxis
    ) const noexcept;

    static std::optional<PlayerRadioState> findPlayerByUsername(
        const PluginSnapshot& snapshot,
        const std::string& username
    ) noexcept;

    static std::string formatFloat(float value) noexcept;
    static void copyVec3(float* dst, const float* src) noexcept;
    static void normalizeDirectionOrDefault(float& x, float& y, float& z) noexcept;

private:
    mutable std::mutex m_mutex;
    CachedPositionalData m_cache;
};
