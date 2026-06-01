#include "AudioRadioEffects.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>

namespace {

constexpr float PI = 3.14159265358979323846f;
constexpr float SampleRate = 48000.0f;

struct RadioFilterState {
    float highpassState = 0.0f;
    float lowpassStateA = 0.0f;
    float lowpassStateB = 0.0f;
    float previousInput = 0.0f;

    uint32_t noiseState = 0x12345678u;
};

static RadioFilterState g_radioState;

float clampFloat(float value, float minValue, float maxValue)
{
    return std::max(minValue, std::min(maxValue, value));
}

float lerp(float a, float b, float t)
{
    return a + (b - a) * t;
}

float noise(RadioFilterState& state)
{
    state.noiseState = 1664525u * state.noiseState + 1013904223u;

    const float normalized =
        static_cast<float>((state.noiseState >> 8) & 0xFFFFu) / 65535.0f;

    return normalized * 2.0f - 1.0f;
}

float softSaturate(float x)
{
    return std::tanh(x);
}

float lowpassAlpha(float cutoffHz)
{
    cutoffHz = clampFloat(cutoffHz, 20.0f, SampleRate * 0.45f);

    return 1.0f - std::exp((-2.0f * PI * cutoffHz) / SampleRate);
}

float highpassAlpha(float cutoffHz)
{
    cutoffHz = clampFloat(cutoffHz, 20.0f, SampleRate * 0.45f);

    const float rc = 1.0f / (2.0f * PI * cutoffHz);
    const float dt = 1.0f / SampleRate;

    return rc / (rc + dt);
}

float onePoleLowpass(
    float input,
    float& state,
    float cutoffHz
)
{
    const float alpha = lowpassAlpha(cutoffHz);

    state += alpha * (input - state);

    return state;
}

float onePoleHighpass(
    float input,
    float& state,
    float& previousInput,
    float cutoffHz
)
{
    const float alpha = highpassAlpha(cutoffHz);

    state = alpha * (state + input - previousInput);
    previousInput = input;

    return state;
}

}

namespace AudioRadioEffects {

void applyRadioEffect(
    float* outputPCM,
    uint32_t sampleCount,
    uint16_t channelCount,
    float volume,
    float quality
)
{
    if (!outputPCM || sampleCount == 0 || channelCount == 0) {
        return;
    }

    quality = clampFloat(quality, 0.0f, 1.0f);
    volume = clampFloat(volume, 0.0f, 2.0f);

    const float badness = 1.0f - quality;

    // Good signal: wider and clearer.
    // Bad signal: thinner, more restricted, and slightly harsher.
    const float highpassCutoff = lerp(280.0f, 520.0f, badness);
    const float lowpassCutoff = lerp(3900.0f, 2300.0f, badness);

    // Radio compression/distortion.
    const float drive = lerp(2.0f, 3.35f, badness);

    // Keep static subtle. The voice should still be the main thing.
    const float staticAmount = lerp(0.0025f, 0.0140f, badness);

    // Tiny random crackles at lower quality.
    const float crackleChance = lerp(0.0002f, 0.0100f, badness);
    const float crackleAmount = lerp(0.0020f, 0.0350f, badness);

    const float outputGain = volume * 0.95f;

    RadioFilterState& state = g_radioState;

    for (uint32_t frame = 0; frame < sampleCount; ++frame) {
        float mono = 0.0f;

        for (uint16_t ch = 0; ch < channelCount; ++ch) {
            mono += outputPCM[frame * channelCount + ch];
        }

        mono /= static_cast<float>(channelCount);

        // Remove low boom / bass.
        float filtered = onePoleHighpass(
            mono,
            state.highpassState,
            state.previousInput,
            highpassCutoff
        );

        // Remove high-fidelity detail.
        // Two passes gives a stronger radio-band effect.
        filtered = onePoleLowpass(
            filtered,
            state.lowpassStateA,
            lowpassCutoff
        );

        filtered = onePoleLowpass(
            filtered,
            state.lowpassStateB,
            lowpassCutoff
        );

        // Push the voice forward like a compressed radio transmission.
        filtered *= drive;
        filtered = softSaturate(filtered);
        filtered *= 0.72f;

        // Light constant radio hiss.
        filtered += noise(state) * staticAmount;

        // Occasional crackle, mostly noticeable when quality is low.
        const float crackleRoll = (noise(state) + 1.0f) * 0.5f;

        if (crackleRoll < crackleChance) {
            filtered += noise(state) * crackleAmount;
        }

        filtered *= outputGain;

        // Safety clamp.
        filtered = clampFloat(filtered, -1.0f, 1.0f);

        // Keep radio effect centered.
        // Left/right routing is handled later by applyHeadsetPan().
        for (uint16_t ch = 0; ch < channelCount; ++ch) {
            outputPCM[frame * channelCount + ch] = filtered;
        }
    }
}

void applyHeadsetPan(
    float* outputPCM,
    uint32_t sampleCount,
    uint16_t channelCount,
    const std::string& ear
)
{
    if (!outputPCM || sampleCount == 0 || channelCount < 2) {
        return;
    }

    float leftGain = 1.0f;
    float rightGain = 1.0f;

    if (ear == "left") {
        leftGain = 1.0f;
        rightGain = 0.0f;
    } else if (ear == "right") {
        leftGain = 0.0f;
        rightGain = 1.0f;
    } else {
        leftGain = 1.0f;
        rightGain = 1.0f;
    }

    for (uint32_t frame = 0; frame < sampleCount; ++frame) {
        outputPCM[frame * channelCount + 0] *= leftGain;
        outputPCM[frame * channelCount + 1] *= rightGain;
    }
}

}