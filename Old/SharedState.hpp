#pragma once

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

struct Vec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
};

struct RadioSlot {
    int id = 0;
    std::string channel;
    bool listening = false;
    bool transmitting = false;
    std::string ear = "both";
    float volume = 1.0f;
    float minDistance = 0.0f;
    float maxDistance = 3000.0f;
};

struct PlayerRadioState {
    std::uint64_t robloxUserId = 0;
    std::string username;
    std::string displayName;

    Vec3 position;
    Vec3 lookVector;

    std::string frequency;
    bool isPtt = false;

    std::string team;
    std::string squad;
    std::string radioId;
    std::vector<RadioSlot> radios;
    
    std::uint64_t updatedAtMs = 0;
};

struct TxLock {
    std::string frequency;
    std::uint64_t ownerRobloxUserId = 0;
    std::string token;
    std::uint64_t expiresAtMs = 0;
};

struct PluginSnapshot {
    std::uint64_t nowMs = 0;
    std::uint64_t localRobloxUserId = 0;

    std::vector<PlayerRadioState> players;
    std::vector<TxLock> txLocks;
};

class SharedState {
public:
    void setSnapshot(PluginSnapshot next) {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_snapshot = std::move(next);
    }

    std::optional<PluginSnapshot> snapshot() const {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_snapshot;
    }

private:
    mutable std::mutex m_mutex;
    std::optional<PluginSnapshot> m_snapshot;
};