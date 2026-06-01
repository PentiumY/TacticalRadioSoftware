#pragma once

#include "SharedState.hpp"

#include <string>

struct RadioRouteResult {
    bool audible = false;
    float volume = 0.0f;
    float quality = 0.0f;
    std::string channel;
    std::string ear = "both";

    int localRadioId = 0;
    int remoteRadioId = 0;
};

class RadioRouter {
public:
    RadioRouteResult evaluate(
        const PlayerRadioState& localPlayer,
        const PlayerRadioState& remotePlayer
    ) const;
};