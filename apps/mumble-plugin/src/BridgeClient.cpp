#include "BridgeClient.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <httplib.h>
#include <iostream>
#include <nlohmann/json.hpp>
#include <sstream>
#include <thread>

using json = nlohmann::json;

namespace {

constexpr bool ENABLE_BRIDGE_SNAPSHOT_DEBUG = false;

std::uint64_t jsonUint64OrZero(const json& value, const char* key) {
    const auto it = value.find(key);

    if (it == value.end() || it->is_null()) {
        return 0;
    }

    const auto& field = *it;

    if (field.is_number_unsigned()) {
        return field.get<std::uint64_t>();
    }

    if (field.is_number_integer()) {
        const auto signedValue = field.get<std::int64_t>();
        return signedValue > 0 ? static_cast<std::uint64_t>(signedValue) : 0;
    }

    if (field.is_string()) {
        try {
            return static_cast<std::uint64_t>(std::stoull(field.get<std::string>()));
        } catch (...) {
            return 0;
        }
    }

    return 0;
}

float clampFloat(float value, float minValue, float maxValue) {
    return std::max(minValue, std::min(maxValue, value));
}

float jsonFloatOrDefault(const json& value, const char* key, float fallback) {
    const auto it = value.find(key);

    if (it == value.end() || it->is_null()) {
        return fallback;
    }

    const auto& field = *it;

    if (field.is_number()) {
        return field.get<float>();
    }

    if (field.is_string()) {
        try {
            return std::stof(field.get<std::string>());
        } catch (...) {
            return fallback;
        }
    }

    return fallback;
}

Vec3 parseVec3(const json& value) {
    Vec3 vec;

    vec.x = value.value("x", 0.0f);
    vec.y = value.value("y", 0.0f);
    vec.z = value.value("z", 0.0f);

    return vec;
}

PlayerRadioState parsePlayer(const json& value) {
    PlayerRadioState player;

    player.robloxUserId = jsonUint64OrZero(value, "robloxUserId");
    player.username = value.value("username", "");
    player.displayName = value.value("displayName", "");

    const auto positionIt = value.find("position");

    if (positionIt != value.end() && positionIt->is_object()) {
        player.position = parseVec3(*positionIt);
    }

    const auto lookVectorIt = value.find("lookVector");

    if (lookVectorIt != value.end() && lookVectorIt->is_object()) {
        player.lookVector = parseVec3(*lookVectorIt);
    }

    player.frequency = value.value("frequency", "");
    player.isPtt = value.value("isPtt", false);

    player.team = value.value("team", "");
    player.squad = value.value("squad", "");
    player.radioId = value.value("radioId", "");

    player.speechMode = value.value("speechMode", "normal");
    player.speechVolume = clampFloat(
        jsonFloatOrDefault(value, "speechVolume", 1.0f),
        0.0f,
        2.0f
    );
    player.speechMinDistance = clampFloat(
        jsonFloatOrDefault(value, "speechMinDistance", 8.0f),
        0.0f,
        10000.0f
    );
    player.speechMaxDistance = clampFloat(
        jsonFloatOrDefault(value, "speechMaxDistance", 90.0f),
        player.speechMinDistance + 1.0f,
        10000.0f
    );

    player.updatedAtMs = value.value("updatedAtMs", 0ULL);

    const auto radiosIt = value.find("radios");

    if (radiosIt != value.end() && radiosIt->is_array()) {
        player.radios.reserve(radiosIt->size());

        for (const auto& radioJson : *radiosIt) {
            RadioSlot radio;

            radio.id = radioJson.value("id", 0);
            radio.channel = radioJson.value("channel", "");
            radio.listening = radioJson.value("listening", false);
            radio.transmitting = radioJson.value("transmitting", false);
            radio.ear = radioJson.value("ear", "both");
            radio.volume = clampFloat(
                jsonFloatOrDefault(radioJson, "volume", 1.0f),
                0.0f,
                2.0f
            );
            radio.minDistance = clampFloat(
                jsonFloatOrDefault(radioJson, "minDistance", 0.0f),
                0.0f,
                100000.0f
            );
            radio.maxDistance = clampFloat(
                jsonFloatOrDefault(radioJson, "maxDistance", 3000.0f),
                radio.minDistance + 1.0f,
                100000.0f
            );

            if (!radio.channel.empty()) {
                player.radios.push_back(std::move(radio));
            }
        }
    }

    const auto hearingIt = value.find("hearing");

    if (hearingIt != value.end() && hearingIt->is_array()) {
        player.hearing.reserve(hearingIt->size());

        for (const auto& hearingJson : *hearingIt) {
            SpeechHearingOverride hearing;

            hearing.remoteRobloxUserId =
                jsonUint64OrZero(hearingJson, "remoteRobloxUserId");

            hearing.obstruction = clampFloat(
                jsonFloatOrDefault(hearingJson, "obstruction", 0.0f),
                0.0f,
                1.0f
            );

            hearing.volumeMultiplier = clampFloat(
                jsonFloatOrDefault(hearingJson, "volumeMultiplier", 1.0f),
                0.0f,
                1.0f
            );

            hearing.maxDistanceMultiplier = clampFloat(
                jsonFloatOrDefault(hearingJson, "maxDistanceMultiplier", 1.0f),
                0.0f,
                1.0f
            );

            hearing.muffled = hearingJson.value("muffled", false);

            if (hearing.remoteRobloxUserId != 0) {
                player.hearing.push_back(std::move(hearing));
            }
        }
    }

    return player;
}

TxLock parseTxLock(const json& value) {
    TxLock lock;

    lock.frequency = value.value("frequency", "");
    lock.ownerRobloxUserId = jsonUint64OrZero(value, "ownerRobloxUserId");
    lock.token = value.value("token", "");
    lock.expiresAtMs = value.value("expiresAtMs", 0ULL);

    return lock;
}

} // namespace

BridgeClient::BridgeClient(SharedState& state)
    : m_state(state) {}

BridgeClient::~BridgeClient() {
    stop();
}

void BridgeClient::start(BridgeConfig config) {
    if (m_running.exchange(true)) {
        return;
    }

    m_config = std::move(config);
    m_snapshotPath = makeSnapshotPath();

    {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        m_lastStatus = "starting";
    }

    m_thread = std::thread(&BridgeClient::run, this);
}

void BridgeClient::stop() {
    if (!m_running.exchange(false)) {
        return;
    }

    if (m_thread.joinable()) {
        m_thread.join();
    }
}

bool BridgeClient::hasEverConnected() const {
    return m_hasEverConnected.load();
}

std::string BridgeClient::lastStatus() const {
    std::lock_guard<std::mutex> lock(m_statusMutex);
    return m_lastStatus;
}

std::string BridgeClient::makeSnapshotPath() const {
    std::ostringstream ss;

    ss
        << "/v1/plugin/snapshot"
        << "?placeId=" << m_config.placeId
        << "&jobId=" << m_config.jobId;

    return ss.str();
}

void BridgeClient::run() {
    int tick = 0;

    httplib::Client client(m_config.baseUrl);
    client.set_connection_timeout(2, 0);
    client.set_read_timeout(2, 0);
    client.set_write_timeout(2, 0);

    while (m_running.load()) {
        const bool ok = fetchOnce(client);

        if (ok) {
            m_hasEverConnected.store(true);

            std::lock_guard<std::mutex> lock(m_statusMutex);
            m_lastStatus = "connected";
        }

        ++tick;

        if (ENABLE_BRIDGE_SNAPSHOT_DEBUG && tick % 25 == 0) {
            const auto snapshot = m_state.snapshot();

            if (snapshot) {
                std::cout
                    << "[TacticalRadio] Snapshot ok: players="
                    << snapshot->players.size()
                    << ", txLocks="
                    << snapshot->txLocks.size()
                    << "\n";
            } else {
                std::cout << "[TacticalRadio] No snapshot yet\n";
            }
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(m_config.pollIntervalMs)
        );
    }

    {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        m_lastStatus = "stopped";
    }
}

bool BridgeClient::fetchOnce(httplib::Client& client) {
    const std::string& path = m_snapshotPath;
    const std::string fullUrl = m_config.baseUrl + path;

    try {
        {
            std::lock_guard<std::mutex> lock(m_statusMutex);
            m_lastStatus = "fetching: " + fullUrl;
        }

        auto response = client.Get(path);

        if (!response) {
            std::lock_guard<std::mutex> lock(m_statusMutex);
            m_lastStatus = "fetch failed: no HTTP response from " + fullUrl;
            return false;
        }

        if (response->status < 200 || response->status >= 300) {
            std::lock_guard<std::mutex> lock(m_statusMutex);

            std::ostringstream ss;
            ss
                << "fetch failed: HTTP "
                << response->status
                << " body="
                << response->body;

            m_lastStatus = ss.str();
            return false;
        }

        const auto parsed = json::parse(response->body);

        PluginSnapshot snapshot;

        snapshot.nowMs = parsed.value("nowMs", 0ULL);
        snapshot.localRobloxUserId = jsonUint64OrZero(parsed, "localRobloxUserId");

        const auto playersIt = parsed.find("players");

        if (playersIt != parsed.end() && playersIt->is_array()) {
            snapshot.players.reserve(playersIt->size());

            for (const auto& playerJson : *playersIt) {
                snapshot.players.push_back(parsePlayer(playerJson));
            }
        }

        const auto locksIt = parsed.find("txLocks");

        if (locksIt != parsed.end() && locksIt->is_array()) {
            snapshot.txLocks.reserve(locksIt->size());

            for (const auto& lockJson : *locksIt) {
                snapshot.txLocks.push_back(parseTxLock(lockJson));
            }
        }

        m_state.setSnapshot(std::move(snapshot));
        return true;
    } catch (const std::exception& e) {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        m_lastStatus = std::string("fetch failed: exception from ") + fullUrl + ": " + e.what();

        std::cerr << "[TacticalRadio] Bridge fetch error: " << e.what() << "\n";
        return false;
    } catch (...) {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        m_lastStatus = "fetch failed: unknown exception from " + fullUrl;

        std::cerr << "[TacticalRadio] Unknown bridge fetch error\n";
        return false;
    }
}
