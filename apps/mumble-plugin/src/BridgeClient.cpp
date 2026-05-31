#include "BridgeClient.hpp"

#include <atomic>
#include <chrono>
#include <httplib.h>
#include <iostream>
#include <nlohmann/json.hpp>
#include <sstream>
#include <thread>

using json = nlohmann::json;

static std::uint64_t jsonUint64OrZero(const json& value, const char* key) {
    if (!value.contains(key) || value.at(key).is_null()) {
        return 0;
    }

    const auto& field = value.at(key);

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

static Vec3 parseVec3(const json& value) {
    Vec3 vec;

    vec.x = value.value("x", 0.0f);
    vec.y = value.value("y", 0.0f);
    vec.z = value.value("z", 0.0f);

    return vec;
}

static PlayerRadioState parsePlayer(const json& value) {
    PlayerRadioState player;

    player.robloxUserId = jsonUint64OrZero(value, "robloxUserId");
    player.username = value.value("username", "");
    player.displayName = value.value("displayName", "");

    if (value.contains("position") && value.at("position").is_object()) {
        player.position = parseVec3(value.at("position"));
    }

    if (value.contains("lookVector") && value.at("lookVector").is_object()) {
        player.lookVector = parseVec3(value.at("lookVector"));
    }

    player.frequency = value.value("frequency", "");
    player.isPtt = value.value("isPtt", false);

    player.team = value.value("team", "");
    player.squad = value.value("squad", "");
    player.radioId = value.value("radioId", "");

    player.updatedAtMs = value.value("updatedAtMs", 0ULL);

    return player;
}

static TxLock parseTxLock(const json& value) {
    TxLock lock;

    lock.frequency = value.value("frequency", "");
    lock.ownerRobloxUserId = jsonUint64OrZero(value, "ownerRobloxUserId");
    lock.token = value.value("token", "");
    lock.expiresAtMs = value.value("expiresAtMs", 0ULL);

    return lock;
}

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

std::string BridgeClient::snapshotPath() const {
    std::ostringstream ss;

    ss
        << "/v1/plugin/snapshot"
        << "?placeId=" << m_config.placeId
        << "&jobId=" << m_config.jobId;

    return ss.str();
}

void BridgeClient::run() {
    int tick = 0;

    while (m_running.load()) {
        const bool ok = fetchOnce();

        if (ok) {
            m_hasEverConnected.store(true);

            std::lock_guard<std::mutex> lock(m_statusMutex);
            m_lastStatus = "connected";
        }

        tick++;

        if (tick % 25 == 0) {
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

bool BridgeClient::fetchOnce() {
    const std::string path = snapshotPath();
    const std::string fullUrl = m_config.baseUrl + path;

    try {
        httplib::Client client(m_config.baseUrl);

        client.set_connection_timeout(2, 0);
        client.set_read_timeout(2, 0);
        client.set_write_timeout(2, 0);

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

        if (parsed.contains("players") && parsed.at("players").is_array()) {
            for (const auto& playerJson : parsed.at("players")) {
                snapshot.players.push_back(parsePlayer(playerJson));
            }
        }

        if (parsed.contains("txLocks") && parsed.at("txLocks").is_array()) {
            for (const auto& lockJson : parsed.at("txLocks")) {
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