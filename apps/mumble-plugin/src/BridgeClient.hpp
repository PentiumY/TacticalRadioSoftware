#pragma once

#include "BridgeConfig.hpp"
#include "SharedState.hpp"

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

namespace httplib { class Client; }

class BridgeClient {
public:
    explicit BridgeClient(SharedState& state);
    ~BridgeClient();

    void start(BridgeConfig config);
    void stop();
    void setMumbleUsername(const std::string& username);
    std::string selectedRobloxUsername() const;

    bool hasEverConnected() const;
    std::string lastStatus() const;

private:
    void run();
    bool fetchOnce(httplib::Client& client, const std::string& path, const BridgeConfig& config);
    bool discoverSession(httplib::Client& client, const std::string& username,
                         std::uint64_t& placeId, std::string& jobId);
    void setStatus(const std::string& status);

    SharedState& m_state;
    BridgeConfig m_config;
    std::atomic<bool> m_running{false};
    std::atomic<bool> m_hasEverConnected{false};
    mutable std::mutex m_statusMutex;
    std::string m_lastStatus = "not started";
    std::string m_mumbleUsername;
    std::string m_selectedRobloxUsername;
    std::thread m_thread;
};
