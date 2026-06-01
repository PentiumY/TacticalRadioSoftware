#pragma once

#include "mumble/plugin/MumblePlugin.h"

#include <mutex>
#include <string>

class MumbleIdentity {
public:
    MumbleIdentity() = default;

    template <typename MumbleApi>
    void refreshIfSynchronized(MumbleApi& api) noexcept {
        try {
            const mumble_connection_t connection = api.getActiveServerConnection();

            if (!api.isConnectionSynchronized(connection)) {
                return;
            }

            update(api, connection);
        } catch (...) {
            // No active synchronized connection yet.
        }
    }

    template <typename MumbleApi>
    void update(MumbleApi& api, mumble_connection_t connection) noexcept {
        try {
            const mumble_userid_t localUserId = api.getLocalUserID(connection);
            const MumbleString username = api.getUserName(connection, localUserId);
            const std::string usernameString = static_cast<std::string>(username);

            if (usernameString.empty()) {
                return;
            }

            std::lock_guard<std::mutex> lock(m_mutex);
            m_username = usernameString;
        } catch (...) {
            // Keep the previous username if reading it fails temporarily.
        }
    }

    void clear() noexcept;
    std::string username() const noexcept;

private:
    mutable std::mutex m_mutex;
    std::string m_username;
};
