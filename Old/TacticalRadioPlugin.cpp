#include "AudioRadioEffects.hpp"
#include "BridgeClient.hpp"
#include "BridgeConfig.hpp"
#include "MumbleIdentity.hpp"
#include "PluginDiagnostics.hpp"
#include "PluginLogger.hpp"
#include "PositionalCache.hpp"
#include "RadioRouter.hpp"
#include "SharedState.hpp"

#include "mumble/plugin/MumblePlugin.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>

namespace {
    constexpr std::chrono::milliseconds CACHE_UPDATE_INTERVAL{50};

    constexpr bool ENABLE_DISTANCE_DEBUG = false;

    // Plugin-owned proximity voice settings.
    // Since Mumble positional audio is disabled, this controls normal speech range.
    constexpr float PROXIMITY_FULL_VOLUME_DISTANCE = 8.0f;
    constexpr float PROXIMITY_MAX_DISTANCE = 90.0f;

    float clampFloat(float value, float minValue, float maxValue)
    {
        return std::max(minValue, std::min(maxValue, value));
    }

    float distanceBetween(const Vec3& a, const Vec3& b)
    {
        const float dx = a.x - b.x;
        const float dy = a.y - b.y;
        const float dz = a.z - b.z;

        return std::sqrt(dx * dx + dy * dy + dz * dz);
    }

    void muteAudio(
        float* outputPCM,
        uint32_t sampleCount,
        uint16_t channelCount
    )
    {
        if (!outputPCM || sampleCount == 0 || channelCount == 0) {
            return;
        }

        const uint32_t totalSamples = sampleCount * channelCount;

        for (uint32_t i = 0; i < totalSamples; ++i) {
            outputPCM[i] = 0.0f;
        }
    }

    float proximityGain(float distance)
    {
        if (distance <= PROXIMITY_FULL_VOLUME_DISTANCE) {
            return 1.0f;
        }

        if (distance >= PROXIMITY_MAX_DISTANCE) {
            return 0.0f;
        }

        const float t =
            (distance - PROXIMITY_FULL_VOLUME_DISTANCE) /
            (PROXIMITY_MAX_DISTANCE - PROXIMITY_FULL_VOLUME_DISTANCE);

        const float linear = 1.0f - clampFloat(t, 0.0f, 1.0f);

        // Slightly steeper falloff than pure linear.
        return linear * linear;
    }

    void applyGain(
        float* outputPCM,
        uint32_t sampleCount,
        uint16_t channelCount,
        float gain
    )
    {
        if (!outputPCM || sampleCount == 0 || channelCount == 0) {
            return;
        }

        gain = clampFloat(gain, 0.0f, 2.0f);

        const uint32_t totalSamples = sampleCount * channelCount;

        for (uint32_t i = 0; i < totalSamples; ++i) {
            outputPCM[i] *= gain;
        }
    }

    void applyHeadsetPan(
        float* outputPCM,
        uint32_t sampleCount,
        uint16_t channelCount,
        const std::string& ear
    )
    {
        if (!outputPCM || sampleCount == 0 || channelCount == 0) {
            return;
        }

        if (channelCount < 2) {
            return;
        }

        float leftGain = 1.0f;
        float rightGain = 1.0f;

        if (ear == "left") {
            leftGain = 1.0f;
            rightGain = 0.0f;
        } else if (ear == "right") {
            leftGain = 0.0f;
            rightGain = 1.0f;
        }

        for (uint32_t frame = 0; frame < sampleCount; ++frame) {
            outputPCM[frame * channelCount + 0] *= leftGain;
            outputPCM[frame * channelCount + 1] *= rightGain;
        }
    }

    void applyProximityPanAndGain(
        float* outputPCM,
        uint32_t sampleCount,
        uint16_t channelCount,
        const PlayerRadioState& localPlayer,
        const PlayerRadioState& remotePlayer,
        float gain
    )
    {
        if (!outputPCM || sampleCount == 0 || channelCount == 0) {
            return;
        }

        gain = clampFloat(gain, 0.0f, 1.0f);

        if (channelCount < 2) {
            applyGain(outputPCM, sampleCount, channelCount, gain);
            return;
        }

        const float relX = remotePlayer.position.x - localPlayer.position.x;
        const float relZ = remotePlayer.position.z - localPlayer.position.z;

        float forwardX = localPlayer.lookVector.x;
        float forwardZ = localPlayer.lookVector.z;

        const float forwardLength =
            std::sqrt(forwardX * forwardX + forwardZ * forwardZ);

        if (forwardLength > 0.001f) {
            forwardX /= forwardLength;
            forwardZ /= forwardLength;
        } else {
            forwardX = 0.0f;
            forwardZ = -1.0f;
        }

        // Roblox horizontal right vector from forward.
        const float rightX = -forwardZ;
        const float rightZ = forwardX;

        const float horizontalDistance =
            std::sqrt(relX * relX + relZ * relZ);

        float pan = 0.0f;

        if (horizontalDistance > 0.001f) {
            pan = ((relX * rightX) + (relZ * rightZ)) / horizontalDistance;
            pan = clampFloat(pan, -1.0f, 1.0f);
        }

        // Equal-power-ish pan.
        const float leftGain = std::sqrt((1.0f - pan) * 0.5f) * gain;
        const float rightGain = std::sqrt((1.0f + pan) * 0.5f) * gain;

        for (uint32_t frame = 0; frame < sampleCount; ++frame) {
            outputPCM[frame * channelCount + 0] *= leftGain;
            outputPCM[frame * channelCount + 1] *= rightGain;
        }
    }
}

class TacticalRadioPlugin final : public MumblePlugin {
public:
    TacticalRadioPlugin()
        : MumblePlugin(
            "Roblox Spatial Voice",
            "TacticalRadioSoftware",
            "Stable low-lag Roblox proximity voice bridge for Mumble positional audio.",
            "roblox-spatial-voice"
        ),
        m_bridge(m_state) {}

    mumble_error_t init() noexcept override {
        m_config = loadBridgeConfig();
        m_logger.setDefaultPath();

        logAlways("[SpatialStable] init");
        logAlways("[SpatialStable] fileLog=" + m_logger.path());
        logAlways(
            "[SpatialStable] config placeId=" + std::to_string(m_config.placeId) +
            " jobId=" + m_config.jobId
        );

        m_contextString =
            "roblox-spatial:" +
            std::to_string(m_config.placeId) +
            ":" +
            m_config.jobId;

        m_identityString = "roblox-spatial-voice";

        m_bridge.start(m_config);
        startCacheThread();

        return MUMBLE_STATUS_OK;
    }

    void shutdown() noexcept override {
        logAlways("[SpatialStable] shutdown");
        stopCacheThread();
        m_bridge.stop();
    }

    void releaseResource(const void* pointer) noexcept override {
        (void) pointer;
    }

    uint32_t getFeatures() const noexcept override {
        // IMPORTANT:
        // We intentionally do NOT return MUMBLE_FEATURE_POSITIONAL anymore.
        // Mumble should transport voice only. This plugin now does radio/proximity routing itself.
        return MUMBLE_FEATURE_AUDIO;
    }

    uint32_t deactivateFeatures(uint32_t features) noexcept {
        if ((features & MUMBLE_FEATURE_POSITIONAL) != 0) {
            logAlways("[SpatialStable] Mumble requested POSITIONAL feature deactivation");
        }

        if ((features & MUMBLE_FEATURE_AUDIO) != 0) {
            logAlways("[SpatialStable] Mumble requested AUDIO feature deactivation");
        }

        return MUMBLE_FEATURE_NONE;
    }

    uint8_t initPositionalData(std::vector<ProgramInformation>& programs) noexcept override {
        m_positionalInitCalls.fetch_add(1, std::memory_order_relaxed);

        logAlways(
            "[SpatialStable] positional initialized by Mumble programs=" +
            std::to_string(programs.size())
        );

        return MUMBLE_PDEC_OK;
    }

    void shutdownPositionalData() noexcept override {
        m_positionalShutdownCalls.fetch_add(1, std::memory_order_relaxed);
        logAlways("[SpatialStable] positional shutdown by Mumble");
    }

    MumbleStringWrapper getPositionalDataContextPrefix() noexcept override {
        static const char prefix[] = "roblox-spatial";

        return MumbleStringWrapper{
            prefix,
            sizeof(prefix) - 1,
            false
        };
    }

    bool fetchPositionalData(
        float* avatarPos,
        float* avatarDir,
        float* avatarAxis,
        float* cameraPos,
        float* cameraDir,
        float* cameraAxis,
        const char** context,
        const char** identity
    ) noexcept override {
        m_fetchCalls.fetch_add(1, std::memory_order_relaxed);

        if (
            avatarPos == nullptr ||
            avatarDir == nullptr ||
            avatarAxis == nullptr ||
            cameraPos == nullptr ||
            cameraDir == nullptr ||
            cameraAxis == nullptr ||
            context == nullptr ||
            identity == nullptr
        ) {
            m_fetchFailures.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        m_positionalCache.copyToMumble(
            avatarPos,
            avatarDir,
            avatarAxis,
            cameraPos,
            cameraDir,
            cameraAxis
        );

        *context = m_contextString.c_str();
        *identity = m_identityString.c_str();

        m_fetchSuccesses.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    bool onAudioSourceFetched(
        float* outputPCM,
        uint32_t sampleCount,
        uint16_t channelCount,
        uint32_t sampleRate,
        bool isSpeech,
        mumble_userid_t userID
    ) noexcept override {
        (void) sampleRate;

        if (!isSpeech) {
            return false;
        }

        if (!outputPCM || sampleCount == 0 || channelCount == 0) {
            return false;
        }

        const std::string remoteUsername = usernameForUserId(userID);

        if (remoteUsername.empty()) {
            return false;
        }

        const std::string localUsername = m_identity.username();

        if (localUsername.empty()) {
            return false;
        }

        const auto snapshot = m_state.snapshot();

        if (!snapshot) {
            return false;
        }

        const auto localPlayer =
            PositionalCache::findPlayerByUsername(*snapshot, localUsername);

        if (!localPlayer) {
            return false;
        }

        const auto remotePlayer =
            PositionalCache::findPlayerByUsername(*snapshot, remoteUsername);

        if (!remotePlayer) {
            return false;
        }

        const RadioRouteResult radioRoute =
            m_radioRouter.evaluate(*localPlayer, *remotePlayer);

        if (radioRoute.audible) {
            AudioRadioEffects::applyRadioEffect(
                outputPCM,
                sampleCount,
                channelCount,
                radioRoute.volume,
                radioRoute.quality
            );

            applyHeadsetPan(
                outputPCM,
                sampleCount,
                channelCount,
                radioRoute.ear
            );

            logAudioRouteThrottled(
                "[AudioRoute] remote=" + remoteUsername +
                " mode=radio" +
                " channel=" + radioRoute.channel +
                " ear=" + radioRoute.ear +
                " volume=" + std::to_string(radioRoute.volume)
            );

            return true;
        }

        const float distance =
            distanceBetween(localPlayer->position, remotePlayer->position);

        const float gain = proximityGain(distance);

        if (gain > 0.0f) {
            applyProximityPanAndGain(
                outputPCM,
                sampleCount,
                channelCount,
                *localPlayer,
                *remotePlayer,
                gain
            );

            logAudioRouteThrottled(
                "[AudioRoute] remote=" + remoteUsername +
                " mode=proximity" +
                " distance=" + std::to_string(distance) +
                " gain=" + std::to_string(gain)
            );

            return true;
        }

        muteAudio(outputPCM, sampleCount, channelCount);

        logAudioRouteThrottled(
            "[AudioRoute] remote=" + remoteUsername +
            " mode=muted" +
            " distance=" + std::to_string(distance)
        );

        return true;
    }

    void onServerSynchronized(mumble_connection_t connection) noexcept override {
        m_identity.update(m_api, connection);
        logAlways("[SpatialStable] server synchronized username=" + m_identity.username());
    }

    void onServerDisconnected(mumble_connection_t connection) noexcept override {
        (void) connection;

        m_identity.clear();
        m_positionalCache.invalidate("SERVER_DISCONNECTED");
        logAlways("[SpatialStable] server disconnected");
    }

private:
    std::string usernameForUserId(mumble_userid_t userID) noexcept {
        try {
            const mumble_connection_t connection = m_api.getActiveServerConnection();

            if (!m_api.isConnectionSynchronized(connection)) {
                return {};
            }

            const MumbleString username = m_api.getUserName(connection, userID);
            return static_cast<std::string>(username);
        } catch (...) {
            return {};
        }
    }

    void logAudioRouteThrottled(const std::string& message) noexcept {
        const std::uint64_t count =
            m_audioRouteLogCounter.fetch_add(1, std::memory_order_relaxed);

        if ((count % 100) == 0) {
            m_logger.logWithoutMumble(message);
        }
    }

    void runCacheUpdateOnce() noexcept {
        m_identity.refreshIfSynchronized(m_api);

        const std::string username = m_identity.username();

        if (username.empty()) {
            m_positionalCache.invalidate("NO_MUMBLE_USERNAME");
            return;
        }

        const auto snapshot = m_state.snapshot();

        if (!snapshot) {
            m_positionalCache.invalidate("NO_BRIDGE_SNAPSHOT username=" + username);
            return;
        }

        const auto localPlayer = PositionalCache::findPlayerByUsername(*snapshot, username);

        if (!localPlayer) {
            m_positionalCache.invalidate(
                "USERNAME_NOT_FOUND_IN_BRIDGE username=" + username +
                " bridgePlayers=" + std::to_string(snapshot->players.size()) +
                " names=[" + PluginDiagnostics::joinPlayerNames(snapshot->players, 16) + "]"
            );
            return;
        }

        m_positionalCache.update(*snapshot, *localPlayer, username);

        if (ENABLE_DISTANCE_DEBUG) {
            m_diagnostics.logDistanceDebug(m_logger, *snapshot, *localPlayer, username);
        }
    }

    void startCacheThread() noexcept {
        bool expected = false;

        if (!m_cacheThreadRunning.compare_exchange_strong(expected, true)) {
            return;
        }

        try {
            m_cacheThread = std::thread([this]() {
                while (m_cacheThreadRunning.load(std::memory_order_relaxed)) {
                    runCacheUpdateOnce();
                    logHeartbeatFromCacheThread();
                    std::this_thread::sleep_for(CACHE_UPDATE_INTERVAL);
                }
            });
        } catch (...) {
            m_cacheThreadRunning.store(false, std::memory_order_relaxed);
            logAlways("[SpatialStable] failed to start cache thread");
        }
    }

    void stopCacheThread() noexcept {
        m_cacheThreadRunning.store(false, std::memory_order_relaxed);

        if (m_cacheThread.joinable()) {
            try {
                m_cacheThread.join();
            } catch (...) {
                // Never throw through Mumble callback boundaries.
            }
        }
    }

    void logHeartbeatFromCacheThread() noexcept {
        PluginCounters counters;
        counters.positionalInitCalls = &m_positionalInitCalls;
        counters.positionalShutdownCalls = &m_positionalShutdownCalls;
        counters.fetchCalls = &m_fetchCalls;
        counters.fetchSuccesses = &m_fetchSuccesses;
        counters.fetchFailures = &m_fetchFailures;

        m_diagnostics.logHeartbeat(
            m_logger,
            m_positionalCache,
            m_identity.username(),
            counters
        );
    }

    void logAlways(const std::string& message) noexcept {
        m_logger.log(m_api, message);
    }

private:
    SharedState m_state;
    BridgeClient m_bridge;
    BridgeConfig m_config;

    PluginLogger m_logger;
    MumbleIdentity m_identity;
    PositionalCache m_positionalCache;
    PluginDiagnostics m_diagnostics;
    RadioRouter m_radioRouter;

    std::string m_contextString;
    std::string m_identityString;

    std::atomic<std::uint64_t> m_positionalInitCalls{0};
    std::atomic<std::uint64_t> m_positionalShutdownCalls{0};
    std::atomic<std::uint64_t> m_fetchCalls{0};
    std::atomic<std::uint64_t> m_fetchSuccesses{0};
    std::atomic<std::uint64_t> m_fetchFailures{0};
    std::atomic<std::uint64_t> m_audioRouteLogCounter{0};

    std::atomic<bool> m_cacheThreadRunning{false};
    std::thread m_cacheThread;
};

MumblePlugin& MumblePlugin::getPlugin() noexcept {
    static TacticalRadioPlugin plugin;
    return plugin;
}