#include "PluginDiagnostics.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace {
    constexpr std::chrono::seconds HEARTBEAT_INTERVAL{10};
    constexpr std::chrono::seconds DISTANCE_LOG_INTERVAL{2};

    std::uint64_t loadCounter(const std::atomic<std::uint64_t>* counter) noexcept {
        if (counter == nullptr) {
            return 0;
        }

        return counter->load(std::memory_order_relaxed);
    }
}

void PluginDiagnostics::logHeartbeat(
    PluginLogger& logger,
    PositionalCache& cache,
    const std::string& fallbackUsername,
    const PluginCounters& counters
) noexcept {
    using Clock = std::chrono::steady_clock;
    const auto now = Clock::now();

    {
        std::lock_guard<std::mutex> lock(m_heartbeatLogMutex);

        if (
            m_lastHeartbeatLogTime.time_since_epoch().count() != 0 &&
            now - m_lastHeartbeatLogTime < HEARTBEAT_INTERVAL
        ) {
            return;
        }

        m_lastHeartbeatLogTime = now;
    }

    const CachedPositionalData cached = cache.snapshot();

    logger.logWithoutMumble(
        "[SpatialStable] alive cache=" + std::string(cached.valid ? "VALID" : "INVALID") +
        " username=" + (cached.username.empty() ? fallbackUsername : cached.username) +
        " players=" + std::to_string(cached.playerCount) +
        " positionalInitCalls=" + std::to_string(loadCounter(counters.positionalInitCalls)) +
        " positionalShutdownCalls=" + std::to_string(loadCounter(counters.positionalShutdownCalls)) +
        " fetchCalls=" + std::to_string(loadCounter(counters.fetchCalls)) +
        " fetchOK=" + std::to_string(loadCounter(counters.fetchSuccesses)) +
        " fetchFail=" + std::to_string(loadCounter(counters.fetchFailures)) +
        " status=" + (cached.status.empty() ? "<none>" : cached.status)
    );
}

std::string PluginDiagnostics::formatRadios(const PlayerRadioState& player)
{
    if (player.radios.empty()) {
        return "radios=none";
    }

    std::ostringstream oss;
    oss << "radios=";

    for (size_t i = 0; i < player.radios.size(); ++i) {
        const auto& r = player.radios[i];

        if (i > 0) {
            oss << ",";
        }

        oss << "{id=" << r.id
            << " channel=" << r.channel
            << " listening=" << (r.listening ? "true" : "false")
            << " transmitting=" << (r.transmitting ? "true" : "false")
            << " ear=" << r.ear
            << " volume=" << r.volume
            << " min=" << r.minDistance
            << " max=" << r.maxDistance
            << "}";
    }

    return oss.str();
}

void PluginDiagnostics::logDistanceDebug(
    PluginLogger& logger,
    const PluginSnapshot& snapshot,
    const PlayerRadioState& me,
    const std::string& mumbleUsername
) noexcept {
    using Clock = std::chrono::steady_clock;
    const auto now = Clock::now();

    {
        std::lock_guard<std::mutex> lock(m_distanceLogMutex);

        if (
            m_lastDistanceLogTime.time_since_epoch().count() != 0 &&
            now - m_lastDistanceLogTime < DISTANCE_LOG_INTERVAL
        ) {
            return;
        }

        m_lastDistanceLogTime = now;
    }

    std::ostringstream out;
    out << "[SpatialStableDistance] local=" << mumbleUsername
        << " pos=(" << PositionalCache::formatFloat(me.position.x)
        << ", " << PositionalCache::formatFloat(me.position.y)
        << ", " << PositionalCache::formatFloat(me.position.z)
        << ") players=" << snapshot.players.size();

    logger.logWithoutMumble(out.str());

    bool foundOtherPlayer = false;

    for (const PlayerRadioState& other : snapshot.players) {
        if (other.username == mumbleUsername) {
            continue;
        }

        foundOtherPlayer = true;

        const float dx = other.position.x - me.position.x;
        const float dy = other.position.y - me.position.y;
        const float dz = other.position.z - me.position.z;
        const float distance = distanceBetween(me, other);

        logger.logWithoutMumble(
            "[SpatialStableDistance] " + mumbleUsername +
            " -> " + other.username +
            " distance=" + PositionalCache::formatFloat(distance) +
            " delta=(" +
            PositionalCache::formatFloat(dx) + ", " +
            PositionalCache::formatFloat(dy) + ", " +
            PositionalCache::formatFloat(dz) + ")" +
            " otherPos=(" +
            PositionalCache::formatFloat(other.position.x) + ", " +
            PositionalCache::formatFloat(other.position.y) + ", " +
            PositionalCache::formatFloat(other.position.z) + ")"
        );
    }

    if (!foundOtherPlayer) {
        logger.logWithoutMumble("[SpatialStableDistance] " + mumbleUsername + " has no other bridge players to measure.");
    }
}

std::string PluginDiagnostics::joinPlayerNames(
    const std::vector<PlayerRadioState>& players,
    std::size_t maxNames
) noexcept {
    std::ostringstream out;
    const std::size_t count = std::min(players.size(), maxNames);

    for (std::size_t i = 0; i < count; ++i) {
        if (i > 0) {
            out << ", ";
        }

        out << players[i].username;
    }

    if (players.size() > maxNames) {
        out << ", ... +" << (players.size() - maxNames) << " more";
    }

    return out.str();
}

float PluginDiagnostics::distanceBetween(const PlayerRadioState& a, const PlayerRadioState& b) noexcept {
    const float dx = b.position.x - a.position.x;
    const float dy = b.position.y - a.position.y;
    const float dz = b.position.z - a.position.z;

    return std::sqrt((dx * dx) + (dy * dy) + (dz * dz));
}
