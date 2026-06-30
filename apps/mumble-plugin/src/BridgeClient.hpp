#pragma once

#include "BridgeConfig.hpp"
#include "SharedState.hpp"

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

namespace httplib {
    class Client;
}

class BridgeClient {
public:
    explicit BridgeClient(SharedState& state);
    ~BridgeClient();

    void start(BridgeConfig config);
    void stop();

    bool hasEverConnected() const;
    std::string lastStatus() const;

private:
    void run();
    bool fetchOnce(httplib::Client& client);
    std::string makeSnapshotPath() const;

private:
    SharedState& m_state;
    BridgeConfig m_config;
    std::string m_snapshotPath;

    std::atomic<bool> m_running = false;
    std::atomic<bool> m_hasEverConnected = false;

    mutable std::mutex m_statusMutex;
    std::string m_lastStatus = "not started";

    std::thread m_thread;
};
