#pragma once

#include <cstdint>
#include <string>

namespace AudioRadioEffects {

void applyRadioEffect(
    float* outputPCM,
    uint32_t sampleCount,
    uint16_t channelCount,
    float volume,
    float quality
);

void applyHeadsetPan(
    float* outputPCM,
    uint32_t sampleCount,
    uint16_t channelCount,
    const std::string& ear
);

}