#pragma once

#include "PluginLogger.hpp"
#include "PositionalCache.hpp"
#include "SharedState.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

struct PluginCounters {
    const std::atomic<std::uint64_t>* positionalInitCalls = nullptr;
    const std::atomic<std::uint64_t>* positionalShutdownCalls = nullptr;
    const std::atomic<std::uint64_t>* fetchCalls = nullptr;
    const std::atomic<std::uint64_t>* fetchSuccesses = nullptr;
    const std::atomic<std::uint64_t>* fetchFailures = nullptr;
};

class PluginDiagnostics {
public:
    void logHeartbeat(
        PluginLogger& logger,
        PositionalCache& cache,
        const std::string& fallbackUsername,
        const PluginCounters& counters
    ) noexcept;

    void logDistanceDebug(
        PluginLogger& logger,
        const PluginSnapshot& snapshot,
        const PlayerRadioState& me,
        const std::string& mumbleUsername
    ) noexcept;

    static std::string formatRadios(const PlayerRadioState& player);
    static std::string joinPlayerNames(const std::vector<PlayerRadioState>& players, std::size_t maxNames) noexcept;
    static float distanceBetween(const PlayerRadioState& a, const PlayerRadioState& b) noexcept;

private:
    mutable std::mutex m_distanceLogMutex;
    std::chrono::steady_clock::time_point m_lastDistanceLogTime{};

    mutable std::mutex m_heartbeatLogMutex;
    std::chrono::steady_clock::time_point m_lastHeartbeatLogTime{};
};
