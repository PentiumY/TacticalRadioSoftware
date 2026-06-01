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

#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>

namespace {
    constexpr std::chrono::milliseconds CACHE_UPDATE_INTERVAL{50};
    
    // Set this to false for a quieter production build after testing.
    constexpr bool ENABLE_DISTANCE_DEBUG = false;
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
        return MUMBLE_FEATURE_POSITIONAL | MUMBLE_FEATURE_AUDIO;
    }
    
    uint32_t deactivateFeatures(uint32_t features) noexcept {
        if ((features & MUMBLE_FEATURE_POSITIONAL) != 0) {
            logAlways("[SpatialStable] Mumble requested POSITIONAL feature deactivation");
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
        
        const std::string remoteUsername = usernameForUserId(userID);
        
        if (remoteUsername.empty()) {
            m_logger.logWithoutMumble(
                "[AudioRoute] userId=" + std::to_string(userID) +
                " username=<unknown>"
            );
            
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
            m_logger.logWithoutMumble(
                "[AudioRoute] userId=" + std::to_string(userID) +
                " username=" + remoteUsername +
                " bridgeMatch=no"
            );
            
            return false;
        }
        
        const RadioRouteResult route =
        m_radioRouter.evaluate(*localPlayer, *remotePlayer);
        
        if (!route.audible) {
            return false;
        }
        
        AudioRadioEffects::applyRadioEffect(
            outputPCM,
            sampleCount,
            channelCount,
            route.volume,
            route.quality
        );
        
        AudioRadioEffects::applyHeadsetPan(
            outputPCM,
            sampleCount,
            channelCount,
            route.ear
        );
        
        
        m_logger.logWithoutMumble(
            "[AudioRoute] userId=" + std::to_string(userID) +
            " remote=" + remoteUsername +
            " route=radio" +
            " channel=" + route.channel +
            " ear=" + route.ear +
            " volume=" + std::to_string(route.volume)
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
        
        for (const auto& remotePlayer : snapshot->players) {
            if (remotePlayer.username == localPlayer->username) {
                continue;
            }
            
            const RadioRouteResult route =
            m_radioRouter.evaluate(*localPlayer, remotePlayer);
            
            if (!route.audible) {
                continue;
            }
            
            m_logger.logWithoutMumble(
                "[RadioRoute] local=" + localPlayer->username +
                " remote=" + remotePlayer.username +
                " channel=" + route.channel +
                " ear=" + route.ear +
                " volume=" + std::to_string(route.volume) +
                " quality=" + std::to_string(route.quality) +
                " localRadioId=" + std::to_string(route.localRadioId) +
                " remoteRadioId=" + std::to_string(route.remoteRadioId)
            );
        }
        
        m_logger.logWithoutMumble(
            "[RadioDebug] local username=" + localPlayer->username + " " +
            PluginDiagnostics::formatRadios(*localPlayer)
        );
        
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
    
    std::atomic<bool> m_cacheThreadRunning{false};
    std::thread m_cacheThread;
};

MumblePlugin& MumblePlugin::getPlugin() noexcept {
    static TacticalRadioPlugin plugin;
    return plugin;
}