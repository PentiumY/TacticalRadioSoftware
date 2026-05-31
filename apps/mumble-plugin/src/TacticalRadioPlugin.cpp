#include "BridgeClient.hpp"
#include "BridgeConfig.hpp"
#include "SharedState.hpp"

#include "mumble/plugin/MumblePlugin.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

class TacticalRadioPlugin final : public MumblePlugin {
public:
    TacticalRadioPlugin()
    : MumblePlugin(
        "Tactical Radio Bridge",
        "TacticalRadioSoftware",
        "Roblox MILSIM tactical radio bridge for Mumble.",
        "tactical-radio"
    ),
    m_bridge(m_state) {}

    mumble_error_t init() noexcept override {
        m_config = loadBridgeConfig();

        log("Tactical Radio Bridge initializing");
        logConfig();

        m_bridge.start(m_config);

        m_debugRunning.store(true);
        m_debugThread = std::thread(&TacticalRadioPlugin::debugLoop, this);

        log("Tactical Radio Bridge bridge client started");

        return MUMBLE_STATUS_OK;
    }

    void shutdown() noexcept override {
        log("Tactical Radio Bridge shutting down");

        m_debugRunning.store(false);

        if (m_debugThread.joinable()) {
            m_debugThread.join();
        }

        m_bridge.stop();

        log("Tactical Radio Bridge stopped");
    }

    void releaseResource(const void* pointer) noexcept override {
        (void) pointer;
    }

    uint32_t getFeatures() const noexcept override {
        return MUMBLE_FEATURE_POSITIONAL;
    }

    uint8_t initPositionalData(std::vector<ProgramInformation>& programs) noexcept override {
        (void) programs;

        log("Positional data initialized");

        return MUMBLE_PDEC_OK;
    }

    void shutdownPositionalData() noexcept override {
        log("Positional data shutdown");
    }

    MumbleStringWrapper getPositionalDataContextPrefix() noexcept override {
        static const char prefix[] = "tactical-radio";

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
        m_posFetchCallCount.fetch_add(1);

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
            m_posFetchBadPointerCount.fetch_add(1);
            return false;
        }

        const auto snapshot = m_state.snapshot();

        if (!snapshot) {
            m_posFetchNoSnapshotCount.fetch_add(1);
            return false;
        }

        const auto localPlayer = findLocalPlayer(*snapshot);

        if (!localPlayer) {
            m_posFetchNoLocalPlayerCount.fetch_add(1);
            return false;
        }

        const PlayerRadioState& me = *localPlayer;

        const float convertedX = me.position.x * kStudsToMeters;
        const float convertedY = me.position.y * kStudsToMeters;
        const float convertedZ = me.position.z * kStudsToMeters;

        avatarPos[0] = convertedX;
        avatarPos[1] = convertedY;
        avatarPos[2] = convertedZ;

        float lookX = me.lookVector.x;
        float lookY = me.lookVector.y;
        float lookZ = me.lookVector.z;

        normalizeDirectionOrDefault(lookX, lookY, lookZ);

        avatarDir[0] = lookX;
        avatarDir[1] = lookY;
        avatarDir[2] = lookZ;

        avatarAxis[0] = 0.0f;
        avatarAxis[1] = 1.0f;
        avatarAxis[2] = 0.0f;

        cameraPos[0] = avatarPos[0];
        cameraPos[1] = avatarPos[1];
        cameraPos[2] = avatarPos[2];

        cameraDir[0] = avatarDir[0];
        cameraDir[1] = avatarDir[1];
        cameraDir[2] = avatarDir[2];

        cameraAxis[0] = avatarAxis[0];
        cameraAxis[1] = avatarAxis[1];
        cameraAxis[2] = avatarAxis[2];

        {
            std::lock_guard<std::mutex> lock(m_positionalDataMutex);

            m_context =
                "tactical-radio:" +
                std::to_string(m_config.placeId) +
                ":" +
                m_config.jobId;

            m_identity =
                "{"
                "\"robloxUserId\":" + std::to_string(me.robloxUserId) + ","
                "\"username\":\"" + me.username + "\","
                "\"frequency\":\"" + me.frequency + "\","
                "\"isPtt\":" + std::string(me.isPtt ? "true" : "false") +
                "}";

            m_lastRawX = me.position.x;
            m_lastRawY = me.position.y;
            m_lastRawZ = me.position.z;

            m_lastConvertedX = convertedX;
            m_lastConvertedY = convertedY;
            m_lastConvertedZ = convertedZ;

            m_lastLookX = avatarDir[0];
            m_lastLookY = avatarDir[1];
            m_lastLookZ = avatarDir[2];

            *context = m_context.c_str();
            *identity = m_identity.c_str();
        }

        m_posFetchOkCount.fetch_add(1);
        m_lastPosFetchOkMs.store(nowSteadyMs());

        return true;
    }

    void onServerSynchronized(mumble_connection_t connection) noexcept override {
        updateLocalMumbleUsername(connection);

        log("Mumble server synchronized");
        logCurrentSnapshot();
        logPositionalAudioStatus();
    }

    void onServerDisconnected(mumble_connection_t connection) noexcept override {
        (void) connection;

        {
            std::lock_guard<std::mutex> lock(m_identityMutex);
            m_localMumbleUsername.clear();
        }

        log("Mumble server disconnected; cleared local Mumble username");
    }

private:
    // Mumble positional audio expects meters.
    //
    // Roblox positions are in studs. 0.28 is a common physical approximation,
    // but it can make Mumble falloff feel too aggressive in Roblox-scale maps.
    //
    // For testing, 0.10 makes Roblox distances feel smaller to Mumble and should
    // make positional falloff easier to notice without immediately becoming quiet.
    static constexpr float kStudsToMeters = 0.10f;

    static std::uint64_t nowSteadyMs() noexcept {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()
            ).count()
        );
    }

    static void normalizeDirectionOrDefault(
        float& x,
        float& y,
        float& z
    ) noexcept {
        const float length = std::sqrt((x * x) + (y * y) + (z * z));

        if (length <= 0.0001f) {
            x = 0.0f;
            y = 0.0f;
            z = -1.0f;
            return;
        }

        x /= length;
        y /= length;
        z /= length;
    }

    void debugLoop() noexcept {
        while (m_debugRunning.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(2));

            if (!m_debugRunning.load()) {
                break;
            }

            updateLocalMumbleUsernameFromActiveConnection();
            logBridgeStatus();
        }
    }

    void updateLocalMumbleUsernameFromActiveConnection() noexcept {
        try {
            const mumble_connection_t connection = m_api.getActiveServerConnection();

            if (!m_api.isConnectionSynchronized(connection)) {
                return;
            }

            updateLocalMumbleUsername(connection);
        } catch (...) {
            // No active synchronized server connection yet.
        }
    }

    void updateLocalMumbleUsername(mumble_connection_t connection) noexcept {
        try {
            const mumble_userid_t localUserId = m_api.getLocalUserID(connection);
            const MumbleString username = m_api.getUserName(connection, localUserId);
            const std::string usernameString = static_cast<std::string>(username);

            bool changed = false;

            {
                std::lock_guard<std::mutex> lock(m_identityMutex);

                if (m_localMumbleUsername != usernameString) {
                    m_localMumbleUsername = usernameString;
                    changed = true;
                }
            }

            if (changed) {
                log("Local Mumble username: " + usernameString);
            }
        } catch (const std::exception& e) {
            log(std::string("Failed to read local Mumble username: ") + e.what());
        } catch (...) {
            log("Failed to read local Mumble username: unknown error");
        }
    }

    std::string localMatchUsername() const noexcept {
        std::lock_guard<std::mutex> lock(m_identityMutex);

        if (!m_localMumbleUsername.empty()) {
            return m_localMumbleUsername;
        }

        return m_config.localRobloxUsername;
    }

    std::optional<PlayerRadioState> findLocalPlayer(const PluginSnapshot& snapshot) const noexcept {
        const std::string username = localMatchUsername();

        const auto playerIt = std::find_if(
            snapshot.players.begin(),
            snapshot.players.end(),
            [&](const PlayerRadioState& player) {
                if (!username.empty()) {
                    return player.username == username;
                }

                return player.robloxUserId == m_config.localRobloxUserId;
            }
        );

        if (playerIt == snapshot.players.end()) {
            return std::nullopt;
        }

        return *playerIt;
    }

    void logBridgeStatus() noexcept {
        std::ostringstream ss;

        ss
            << "Bridge status: "
            << m_bridge.lastStatus()
            << ", hasEverConnected="
            << (m_bridge.hasEverConnected() ? "true" : "false")
            << ", localMumbleUsername="
            << localMatchUsername();

        log(ss.str());

        logCurrentSnapshot();
        logPositionalAudioStatus();
    }

    void logPositionalAudioStatus() noexcept {
        const std::uint64_t nowMs = nowSteadyMs();
        const std::uint64_t lastOkMs = m_lastPosFetchOkMs.load();

        std::string contextCopy;
        std::string identityCopy;

        float rawX = 0.0f;
        float rawY = 0.0f;
        float rawZ = 0.0f;

        float convertedX = 0.0f;
        float convertedY = 0.0f;
        float convertedZ = 0.0f;

        float lookX = 0.0f;
        float lookY = 0.0f;
        float lookZ = 0.0f;

        {
            std::lock_guard<std::mutex> lock(m_positionalDataMutex);

            contextCopy = m_context;
            identityCopy = m_identity;

            rawX = m_lastRawX;
            rawY = m_lastRawY;
            rawZ = m_lastRawZ;

            convertedX = m_lastConvertedX;
            convertedY = m_lastConvertedY;
            convertedZ = m_lastConvertedZ;

            lookX = m_lastLookX;
            lookY = m_lastLookY;
            lookZ = m_lastLookZ;
        }

        std::ostringstream ss;

        ss
            << "PA status:"
            << " features=MUMBLE_FEATURE_POSITIONAL"
            << " fetchCalls=" << m_posFetchCallCount.load()
            << " fetchOk=" << m_posFetchOkCount.load()
            << " noSnapshot=" << m_posFetchNoSnapshotCount.load()
            << " noLocalPlayer=" << m_posFetchNoLocalPlayerCount.load()
            << " badPointers=" << m_posFetchBadPointerCount.load();

        if (lastOkMs == 0) {
            ss << " lastOkAgeMs=never";
        } else {
            ss << " lastOkAgeMs=" << (nowMs - lastOkMs);
        }

        ss
            << " studsToMeters=" << kStudsToMeters
            << " rawPos=("
            << rawX << ", "
            << rawY << ", "
            << rawZ << ")"
            << " convertedMeters=("
            << convertedX << ", "
            << convertedY << ", "
            << convertedZ << ")"
            << " look=("
            << lookX << ", "
            << lookY << ", "
            << lookZ << ")"
            << " context=" << contextCopy
            << " identity=" << identityCopy;

        log(ss.str());
    }

    void log(const std::string& message) noexcept {
        try {
            m_api.log(message.c_str());
        } catch (...) {
            // Never throw through Mumble callback boundaries.
        }
    }

    void logConfig() noexcept {
        std::ostringstream ss;

        ss
            << "Bridge config: "
            << "baseUrl=" << m_config.baseUrl
            << ", placeId=" << m_config.placeId
            << ", jobId=" << m_config.jobId
            << ", localRobloxUserId=" << m_config.localRobloxUserId
            << ", localRobloxUsername=" << m_config.localRobloxUsername
            << ", pollIntervalMs=" << m_config.pollIntervalMs;

        log(ss.str());
    }

    void logCurrentSnapshot() noexcept {
        const auto snapshot = m_state.snapshot();

        if (!snapshot) {
            log("No bridge snapshot available yet");
            return;
        }

        const auto localPlayer = findLocalPlayer(*snapshot);

        if (!localPlayer) {
            std::ostringstream ss;

            ss
                << "Bridge snapshot received, but local player was not found. "
                << "localMumbleUsername=" << localMatchUsername()
                << ", fallbackUserId=" << m_config.localRobloxUserId
                << ", players in snapshot=" << snapshot->players.size();

            log(ss.str());
            return;
        }

        const PlayerRadioState& me = *localPlayer;

        std::uint64_t txOwner = 0;

        const auto lockIt = std::find_if(
            snapshot->txLocks.begin(),
            snapshot->txLocks.end(),
            [&](const TxLock& lock) {
                return lock.frequency == me.frequency;
            }
        );

        if (lockIt != snapshot->txLocks.end()) {
            txOwner = lockIt->ownerRobloxUserId;
        }

        std::ostringstream ss;

        ss
            << "Bridge snapshot: "
            << "username=" << me.username
            << ", robloxUserId=" << me.robloxUserId
            << ", frequency=" << me.frequency
            << ", isPtt=" << (me.isPtt ? "true" : "false")
            << ", txOwner=" << txOwner
            << ", position=("
            << me.position.x << ", "
            << me.position.y << ", "
            << me.position.z << ")"
            << ", lookVector=("
            << me.lookVector.x << ", "
            << me.lookVector.y << ", "
            << me.lookVector.z << ")";

        log(ss.str());
    }

private:
    SharedState m_state;
    BridgeClient m_bridge;
    BridgeConfig m_config;

    std::atomic<bool> m_debugRunning = false;
    std::thread m_debugThread;

    mutable std::mutex m_identityMutex;
    std::string m_localMumbleUsername;

    mutable std::mutex m_positionalDataMutex;
    std::string m_context;
    std::string m_identity;

    float m_lastRawX = 0.0f;
    float m_lastRawY = 0.0f;
    float m_lastRawZ = 0.0f;

    float m_lastConvertedX = 0.0f;
    float m_lastConvertedY = 0.0f;
    float m_lastConvertedZ = 0.0f;

    float m_lastLookX = 0.0f;
    float m_lastLookY = 0.0f;
    float m_lastLookZ = -1.0f;

    std::atomic<std::uint64_t> m_posFetchCallCount = 0;
    std::atomic<std::uint64_t> m_posFetchOkCount = 0;
    std::atomic<std::uint64_t> m_posFetchNoSnapshotCount = 0;
    std::atomic<std::uint64_t> m_posFetchNoLocalPlayerCount = 0;
    std::atomic<std::uint64_t> m_posFetchBadPointerCount = 0;
    std::atomic<std::uint64_t> m_lastPosFetchOkMs = 0;
};

MumblePlugin& MumblePlugin::getPlugin() noexcept {
    static TacticalRadioPlugin plugin;
    return plugin;
}