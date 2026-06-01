#pragma once

#include <mutex>
#include <string>

class PluginLogger {
public:
    PluginLogger() = default;

    void setDefaultPath() noexcept;
    void setPath(std::string path) noexcept;
    std::string path() const noexcept;

    template <typename MumbleApi>
    void log(MumbleApi& api, const std::string& message) noexcept {
        writeSinks(message);

        try {
            api.log(message.c_str());
        } catch (...) {
            // Never throw through Mumble callback boundaries.
        }
    }

    void logWithoutMumble(const std::string& message) noexcept;

    static std::string defaultLogFilePath() noexcept;
    static std::string nowTimestamp() noexcept;

private:
    void writeSinks(const std::string& message) noexcept;

private:
    mutable std::mutex m_mutex;
    std::string m_path;
};
