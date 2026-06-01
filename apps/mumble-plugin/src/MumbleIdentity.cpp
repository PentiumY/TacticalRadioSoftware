#include "MumbleIdentity.hpp"

void MumbleIdentity::clear() noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_username.clear();
}

std::string MumbleIdentity::username() const noexcept {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_username;
}
