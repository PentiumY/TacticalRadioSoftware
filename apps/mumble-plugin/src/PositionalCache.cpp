#include "PositionalCache.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

void PositionalCache::invalidate(const std::string& status) noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_cache.valid) {
        m_cache.status = "STALE_USING_LAST_VALID " + status;
        return;
    }

    m_cache.status = "NO_VALID_POSITION_YET " + status;
}

void PositionalCache::update(
    const PluginSnapshot& snapshotValue,
    const PlayerRadioState& me,
    const std::string& mumbleUsername
) noexcept {
    CachedPositionalData next;
    next.valid = true;
    next.username = mumbleUsername;
    next.playerCount = snapshotValue.players.size();
    next.status =
        "OK username=" + mumbleUsername +
        " pos=(" +
        formatFloat(me.position.x) + ", " +
        formatFloat(me.position.y) + ", " +
        formatFloat(me.position.z) + ")" +
        " players=" + std::to_string(snapshotValue.players.size());

    // Roblox -> Mumble coordinate transform.
    // Flip X because left/right is reversed in Mumble positional audio.
    next.avatarPos[0] = -me.position.x;
    next.avatarPos[1] =  me.position.y;
    next.avatarPos[2] =  me.position.z;

    float lookX = -me.lookVector.x;
    float lookY =  me.lookVector.y;
    float lookZ =  me.lookVector.z;
    normalizeDirectionOrDefault(lookX, lookY, lookZ);

    next.avatarDir[0] = lookX;
    next.avatarDir[1] = lookY;
    next.avatarDir[2] = lookZ;

    next.avatarAxis[0] = 0.0f;
    next.avatarAxis[1] = 1.0f;
    next.avatarAxis[2] = 0.0f;

    next.cameraPos[0] = next.avatarPos[0];
    next.cameraPos[1] = next.avatarPos[1];
    next.cameraPos[2] = next.avatarPos[2];

    next.cameraDir[0] = next.avatarDir[0];
    next.cameraDir[1] = next.avatarDir[1];
    next.cameraDir[2] = next.avatarDir[2];

    next.cameraAxis[0] = next.avatarAxis[0];
    next.cameraAxis[1] = next.avatarAxis[1];
    next.cameraAxis[2] = next.avatarAxis[2];

    std::lock_guard<std::mutex> lock(m_mutex);
    m_cache = std::move(next);
}

CachedPositionalData PositionalCache::snapshot() const noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_cache;
}

bool PositionalCache::copyToMumble(
    float* avatarPos,
    float* avatarDir,
    float* avatarAxis,
    float* cameraPos,
    float* cameraDir,
    float* cameraAxis
) const noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_cache.valid) {
        avatarPos[0] = 0.0f; avatarPos[1] = 0.0f; avatarPos[2] = 0.0f;
        avatarDir[0] = 0.0f; avatarDir[1] = 0.0f; avatarDir[2] = -1.0f;
        avatarAxis[0] = 0.0f; avatarAxis[1] = 1.0f; avatarAxis[2] = 0.0f;
        cameraPos[0] = 0.0f; cameraPos[1] = 0.0f; cameraPos[2] = 0.0f;
        cameraDir[0] = 0.0f; cameraDir[1] = 0.0f; cameraDir[2] = -1.0f;
        cameraAxis[0] = 0.0f; cameraAxis[1] = 1.0f; cameraAxis[2] = 0.0f;
        return false;
    }

    copyVec3(avatarPos, m_cache.avatarPos);
    copyVec3(avatarDir, m_cache.avatarDir);
    copyVec3(avatarAxis, m_cache.avatarAxis);
    copyVec3(cameraPos, m_cache.cameraPos);
    copyVec3(cameraDir, m_cache.cameraDir);
    copyVec3(cameraAxis, m_cache.cameraAxis);
    return true;
}

const PlayerRadioState* PositionalCache::findPlayerByUsername(
    const PluginSnapshot& snapshotValue,
    const std::string& username
) noexcept {
    const auto playerIt = std::find_if(
        snapshotValue.players.begin(),
        snapshotValue.players.end(),
        [&](const PlayerRadioState& player) {
            return player.username == username;
        }
    );

    if (playerIt == snapshotValue.players.end()) {
        return nullptr;
    }

    return &(*playerIt);
}

std::string PositionalCache::formatFloat(float value) noexcept {
    char buffer[32] = {};
    std::snprintf(buffer, sizeof(buffer), "%.2f", static_cast<double>(value));
    return std::string(buffer);
}

void PositionalCache::copyVec3(float* dst, const float* src) noexcept {
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
}

void PositionalCache::normalizeDirectionOrDefault(float& x, float& y, float& z) noexcept {
    const float length = std::sqrt((x * x) + (y * y) + (z * z));

    if (length <= 0.0001f) {
        x = 0.0f;
        y = 0.0f;
        z = -1.0f;
        return;
    }

    const float invLength = 1.0f / length;
    x *= invLength;
    y *= invLength;
    z *= invLength;
}
