#include "BridgeClient.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <httplib.h>
#include <iostream>
#include <nlohmann/json.hpp>
#include <sstream>
#include <memory>
#include <cctype>
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

BridgeClient::~BridgeClient() { stop(); }

void BridgeClient::start(BridgeConfig config) {
    if (m_running.exchange(true)) return;
    m_config = std::move(config);
    setStatus("starting");
    m_thread = std::thread(&BridgeClient::run, this);
}

void BridgeClient::stop() {
    if (!m_running.exchange(false)) return;
    if (m_thread.joinable()) m_thread.join();
}

void BridgeClient::setMumbleUsername(const std::string& username) {
    std::lock_guard<std::mutex> lock(m_statusMutex);
    m_mumbleUsername = username;
}

std::string BridgeClient::selectedRobloxUsername() const {
    std::lock_guard<std::mutex> lock(m_statusMutex);
    return m_selectedRobloxUsername;
}

bool BridgeClient::hasEverConnected() const { return m_hasEverConnected.load(); }

std::string BridgeClient::lastStatus() const {
    std::lock_guard<std::mutex> lock(m_statusMutex);
    return m_lastStatus;
}

void BridgeClient::setStatus(const std::string& status) {
    std::lock_guard<std::mutex> lock(m_statusMutex);
    m_lastStatus = status;
}

// Encode a username or JobId as an HTTP query parameter.
static std::string urlEncode(const std::string& input) {
    static const char hex[] = "0123456789ABCDEF";
    std::string result;
    for (unsigned char c : input) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            result += static_cast<char>(c);
        } else {
            result += '%';
            result += hex[c >> 4];
            result += hex[c & 15];
        }
    }
    return result;
}

bool BridgeClient::discoverSession(httplib::Client& client, const std::string& username,
                                   std::uint64_t& placeId, std::string& jobId) {
    try {
        auto response = client.Get("/v1/sessions?username=" + urlEncode(username));
        if (!response || response->status != 200) {
            setStatus("session discovery unavailable");
            return false;
        }
        const auto parsed = json::parse(response->body);
        if (!parsed.contains("sessions") || !parsed["sessions"].is_array()) return false;
        const auto& sessions = parsed["sessions"];
        // Avoid choosing arbitrarily if the account appears in multiple active servers.
        if (sessions.size() != 1 || !sessions[0].is_object()) {
            setStatus(sessions.empty() ? "Roblox player not in game" : "multiple Roblox sessions found");
            return false;
        }
        const auto& session = sessions[0];
        placeId = jsonUint64OrZero(session, "placeId");
        jobId = session.value("jobId", std::string{});
        if (placeId != 0 && !jobId.empty()) {
            setStatus("session discovered placeId=" + std::to_string(placeId) + " jobId=" + jobId);
            return true;
        }
        setStatus("session response missing placeId or jobId");
        return false;
    } catch (const std::exception& error) {
        setStatus(std::string("session discovery error: ") + error.what());
        return false;
    } catch (...) {
        setStatus("session discovery failed");
        return false;
    }
}

void BridgeClient::run() {
    std::string activeUrl;
    std::unique_ptr<httplib::Client> client;
    std::uint64_t activePlace = 0;
    std::string activeJob;
    std::string oldSelectedUsername;
    bool oldAuto = false;
    auto nextDiscovery = std::chrono::steady_clock::time_point{};
    auto nextConfigRead = std::chrono::steady_clock::time_point{};
    BridgeConfig config = m_config;

    while (m_running.load()) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= nextConfigRead) {
            config = loadBridgeConfig();
            nextConfigRead = now + std::chrono::seconds(1);
        }

        std::string mumbleUsername;
        {
            std::lock_guard<std::mutex> lock(m_statusMutex);
            mumbleUsername = m_mumbleUsername;
        }
        const std::string selected = config.localRobloxUsername.empty()
            ? mumbleUsername : config.localRobloxUsername;
        {
            std::lock_guard<std::mutex> lock(m_statusMutex);
            m_selectedRobloxUsername = selected;
        }

        if (activeUrl != config.baseUrl || !client) {
            activeUrl = config.baseUrl;
            client.reset(new httplib::Client(activeUrl));
            client->set_connection_timeout(2, 0);
            client->set_read_timeout(2, 0);
            client->set_write_timeout(2, 0);
            nextDiscovery = std::chrono::steady_clock::time_point{};
            activePlace = 0;
            activeJob.clear();
            m_state.setSnapshot(PluginSnapshot{});
        }

        if (selected != oldSelectedUsername || config.autoSession != oldAuto) {
            oldSelectedUsername = selected;
            oldAuto = config.autoSession;
            nextDiscovery = std::chrono::steady_clock::time_point{};
            activePlace = 0;
            activeJob.clear();
            m_state.setSnapshot(PluginSnapshot{});
        }

        if (config.autoSession) {
            if (now >= nextDiscovery) {
                nextDiscovery = now + std::chrono::seconds(2);
                std::uint64_t newPlace = 0;
                std::string newJob;
                const bool found = !selected.empty() && discoverSession(*client, selected, newPlace, newJob);
                if (!found || newPlace != activePlace || newJob != activeJob) {
                    m_state.setSnapshot(PluginSnapshot{});
                }
                activePlace = found ? newPlace : 0;
                activeJob = found ? newJob : std::string{};
            }
        } else {
            if (activePlace != config.placeId || activeJob != config.jobId)
                m_state.setSnapshot(PluginSnapshot{});
            activePlace = config.placeId;
            activeJob = config.jobId;
        }

        if (activePlace && !activeJob.empty()) {
            std::ostringstream path;
            path << "/v1/plugin/snapshot?placeId=" << activePlace
                 << "&jobId=" << urlEncode(activeJob)
                 << "&localRobloxUsername=" << urlEncode(selected);
            if (fetchOnce(*client, path.str(), config)) m_hasEverConnected.store(true);
        } else if (selected.empty()) {
            setStatus("waiting for Roblox username or Mumble connection");
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(config.pollIntervalMs));
    }
    setStatus("stopped");
}

bool BridgeClient::fetchOnce(httplib::Client& client, const std::string& path,
                             const BridgeConfig& config) {
    const std::string fullUrl = config.baseUrl + path;
    try {
        auto response = client.Get(path);
        if (!response) {
            setStatus("fetch failed: no HTTP response from " + fullUrl);
            return false;
        }
        if (response->status < 200 || response->status >= 300) {
            setStatus("fetch failed: HTTP " + std::to_string(response->status));
            return false;
        }
        const auto parsed = json::parse(response->body);
        PluginSnapshot snapshot;
        snapshot.nowMs = parsed.value("nowMs", 0ULL);
        snapshot.localRobloxUserId = jsonUint64OrZero(parsed, "localRobloxUserId");
        const auto playersIt = parsed.find("players");
        if (playersIt != parsed.end() && playersIt->is_array()) {
            snapshot.players.reserve(playersIt->size());
            for (const auto& playerJson : *playersIt)
                snapshot.players.push_back(parsePlayer(playerJson));
        }
        const auto locksIt = parsed.find("txLocks");
        if (locksIt != parsed.end() && locksIt->is_array()) {
            snapshot.txLocks.reserve(locksIt->size());
            for (const auto& lockJson : *locksIt)
                snapshot.txLocks.push_back(parseTxLock(lockJson));
        }
        const std::size_t playerCount = snapshot.players.size();
        m_state.setSnapshot(std::move(snapshot));
        setStatus("snapshot OK url=" + fullUrl + " players=" + std::to_string(playerCount));
        return true;
    } catch (const std::exception& error) {
        setStatus(std::string("fetch exception: ") + error.what());
        return false;
    } catch (...) {
        setStatus("fetch failed: unknown exception");
        return false;
    }
}
