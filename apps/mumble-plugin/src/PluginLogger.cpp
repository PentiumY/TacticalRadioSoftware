#include "PluginLogger.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

void PluginLogger::setDefaultPath() noexcept {
    setPath(defaultLogFilePath());
}

void PluginLogger::setPath(std::string path) noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_path = std::move(path);
}

std::string PluginLogger::path() const noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_path;
}

void PluginLogger::logWithoutMumble(const std::string& message) noexcept {
    writeSinks(message);
}

std::string PluginLogger::defaultLogFilePath() noexcept {
#ifdef _WIN32
    const char* appData = std::getenv("APPDATA");

    if (appData != nullptr && appData[0] != '\0') {
        return std::string(appData) + "\\Mumble\\Mumble\\roblox_spatial_plugin.log";
    }

    return "roblox_spatial_plugin.log";
#else
    return "/tmp/roblox_spatial_plugin.log";
#endif
}

std::string PluginLogger::nowTimestamp() noexcept {
    using Clock = std::chrono::system_clock;
    const auto now = Clock::now();
    const std::time_t time = Clock::to_time_t(now);

    char buffer[64] = {};

#ifdef _WIN32
    std::tm tmValue = {};
    localtime_s(&tmValue, &time);
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", &tmValue);
#else
    std::tm* tmValue = std::localtime(&time);

    if (tmValue != nullptr) {
        std::strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", tmValue);
    } else {
        std::snprintf(buffer, sizeof(buffer), "unknown-time");
    }
#endif

    return std::string(buffer);
}

void PluginLogger::writeSinks(const std::string& message) noexcept {
    const std::string fullMessage = nowTimestamp() + " " + message;

    {
        std::lock_guard<std::mutex> lock(m_mutex);

        if (!m_path.empty()) {
            std::ofstream file(m_path, std::ios::app);

            if (file) {
                file << fullMessage << '\n';
            }
        }
    }

    try {
        std::fprintf(stderr, "%s\n", fullMessage.c_str());
        std::fflush(stderr);
    } catch (...) {
        // Ignore logging failures.
    }

#ifdef _WIN32
    try {
        OutputDebugStringA((fullMessage + "\n").c_str());
    } catch (...) {
        // Ignore logging failures.
    }
#endif
}
