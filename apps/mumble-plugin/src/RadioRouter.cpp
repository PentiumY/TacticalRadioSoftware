#include "RadioRouter.hpp"

#include <algorithm>
#include <cctype>

namespace {

std::string normalizeChannel(std::string value)
{
    value.erase(
        std::remove_if(
            value.begin(),
            value.end(),
            [](unsigned char ch) {
                return std::isspace(ch) != 0;
            }
        ),
        value.end()
    );

    std::transform(
        value.begin(),
        value.end(),
        value.begin(),
        [](unsigned char ch) {
            return static_cast<char>(std::toupper(ch));
        }
    );

    return value;
}

std::string normalizeEar(const std::string& value)
{
    std::string ear = value;

    std::transform(
        ear.begin(),
        ear.end(),
        ear.begin(),
        [](unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        }
    );

    if (ear == "left" || ear == "right" || ear == "both") {
        return ear;
    }

    return "both";
}

float clampNonNegative(float value)
{
    return std::max(0.0f, value);
}

} // namespace

RadioRouteResult RadioRouter::evaluate(
    const PlayerRadioState& localPlayer,
    const PlayerRadioState& remotePlayer
) const
{
    RadioRouteResult best;

    for (const auto& remoteRadio : remotePlayer.radios) {
        if (!remoteRadio.transmitting) {
            continue;
        }

        const std::string remoteChannel = normalizeChannel(remoteRadio.channel);

        if (remoteChannel.empty()) {
            continue;
        }

        for (const auto& localRadio : localPlayer.radios) {
            if (!localRadio.listening) {
                continue;
            }

            const std::string localChannel = normalizeChannel(localRadio.channel);

            if (localChannel.empty()) {
                continue;
            }

            if (localChannel != remoteChannel) {
                continue;
            }

            const float volume = clampNonNegative(localRadio.volume);

            if (!best.audible || volume > best.volume) {
                best.audible = true;
                best.volume = volume;
                best.quality = 1.0f;
                best.channel = localRadio.channel;
                best.ear = normalizeEar(localRadio.ear);
                best.localRadioId = localRadio.id;
                best.remoteRadioId = remoteRadio.id;
            }
        }
    }

    return best;
}