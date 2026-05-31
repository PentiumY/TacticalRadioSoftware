#pragma once

#include "BridgeConfig.hpp"
#include "SharedState.hpp"

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

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
    bool fetchOnce();
    std::string snapshotPath() const;

private:
    SharedState& m_state;
    BridgeConfig m_config;

    std::atomic<bool> m_running = false;
    std::atomic<bool> m_hasEverConnected = false;

    mutable std::mutex m_statusMutex;
    std::string m_lastStatus = "not started";

    std::thread m_thread;
};