#include "AudioRadioEffects.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>

namespace {

constexpr float PI = 3.14159265358979323846f;
constexpr float SampleRate = 48000.0f;

float clampFloat(float value, float minValue, float maxValue)
{
    return std::max(minValue, std::min(maxValue, value));
}

float lerp(float a, float b, float t)
{
    return a + (b - a) * t;
}

float smoothstep(float t)
{
    t = clampFloat(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

float fastSaturate(float x)
{
    // Fast tanh-like soft clip. This avoids calling std::tanh per audio sample.
    x = clampFloat(x, -3.0f, 3.0f);
    const float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

struct Biquad {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;

    float z1 = 0.0f;
    float z2 = 0.0f;

    float process(float input)
    {
        const float output = b0 * input + z1;

        z1 = b1 * input - a1 * output + z2;
        z2 = b2 * input - a2 * output;

        return output;
    }

    void setCoefficients(
        float newB0,
        float newB1,
        float newB2,
        float newA0,
        float newA1,
        float newA2
    )
    {
        if (std::fabs(newA0) < 0.000001f) {
            return;
        }

        const float invA0 = 1.0f / newA0;

        b0 = newB0 * invA0;
        b1 = newB1 * invA0;
        b2 = newB2 * invA0;
        a1 = newA1 * invA0;
        a2 = newA2 * invA0;
    }

    void setLowpass(float cutoffHz, float q)
    {
        cutoffHz = clampFloat(cutoffHz, 20.0f, SampleRate * 0.45f);
        q = clampFloat(q, 0.1f, 10.0f);

        const float omega = 2.0f * PI * cutoffHz / SampleRate;
        const float sinOmega = std::sin(omega);
        const float cosOmega = std::cos(omega);
        const float alpha = sinOmega / (2.0f * q);

        const float newB0 = (1.0f - cosOmega) * 0.5f;
        const float newB1 = 1.0f - cosOmega;
        const float newB2 = (1.0f - cosOmega) * 0.5f;
        const float newA0 = 1.0f + alpha;
        const float newA1 = -2.0f * cosOmega;
        const float newA2 = 1.0f - alpha;

        setCoefficients(
            newB0,
            newB1,
            newB2,
            newA0,
            newA1,
            newA2
        );
    }

    void setHighpass(float cutoffHz, float q)
    {
        cutoffHz = clampFloat(cutoffHz, 20.0f, SampleRate * 0.45f);
        q = clampFloat(q, 0.1f, 10.0f);

        const float omega = 2.0f * PI * cutoffHz / SampleRate;
        const float sinOmega = std::sin(omega);
        const float cosOmega = std::cos(omega);
        const float alpha = sinOmega / (2.0f * q);

        const float newB0 = (1.0f + cosOmega) * 0.5f;
        const float newB1 = -(1.0f + cosOmega);
        const float newB2 = (1.0f + cosOmega) * 0.5f;
        const float newA0 = 1.0f + alpha;
        const float newA1 = -2.0f * cosOmega;
        const float newA2 = 1.0f - alpha;

        setCoefficients(
            newB0,
            newB1,
            newB2,
            newA0,
            newA1,
            newA2
        );
    }

    void setPeak(float centerHz, float q, float gainDb)
    {
        centerHz = clampFloat(centerHz, 20.0f, SampleRate * 0.45f);
        q = clampFloat(q, 0.1f, 10.0f);

        const float gain = std::pow(10.0f, gainDb / 40.0f);
        const float omega = 2.0f * PI * centerHz / SampleRate;
        const float sinOmega = std::sin(omega);
        const float cosOmega = std::cos(omega);
        const float alpha = sinOmega / (2.0f * q);

        const float newB0 = 1.0f + alpha * gain;
        const float newB1 = -2.0f * cosOmega;
        const float newB2 = 1.0f - alpha * gain;
        const float newA0 = 1.0f + alpha / gain;
        const float newA1 = -2.0f * cosOmega;
        const float newA2 = 1.0f - alpha / gain;

        setCoefficients(
            newB0,
            newB1,
            newB2,
            newA0,
            newA1,
            newA2
        );
    }
};

struct RadioFilterState {
    Biquad voiceHighpassA;
    Biquad voiceHighpassB;

    Biquad voiceLowpassA;
    Biquad voiceLowpassB;
    Biquad voiceLowpassC;

    Biquad voicePresence;

    Biquad hissHighpass;
    Biquad hissLowpass;

    Biquad crackleHighpass;
    Biquad crackleLowpass;

    Biquad failureNoiseHighpass;
    Biquad failureNoiseLowpass;

    float compressorEnvelope = 0.0f;

    float failureGain = 1.0f;
    float failureTargetGain = 1.0f;
    float failureNoiseEnvelope = 0.0f;
    uint32_t failureHoldFrames = 0;

    uint32_t noiseState = 0x12345678u;
};

struct CompressorParams {
    float threshold = 0.1f;
    float invRatio = 0.05f;
    float attackCoeff = 0.5f;
    float releaseCoeff = 0.01f;
    float makeupGain = 3.0f;
    float limiterDrive = 2.0f;
    float postLimiterGain = 0.7f;
};

static RadioFilterState g_radioState;

float noise(RadioFilterState& state)
{
    state.noiseState = 1664525u * state.noiseState + 1013904223u;

    const float normalized =
        static_cast<float>((state.noiseState >> 8) & 0xFFFFu) / 65535.0f;

    return normalized * 2.0f - 1.0f;
}

float random01(RadioFilterState& state)
{
    return (noise(state) + 1.0f) * 0.5f;
}

float quantizeSample(float value, float levels)
{
    levels = clampFloat(levels, 8.0f, 4096.0f);
    return std::round(value * levels) / levels;
}

float calculateNearFailure(float quality)
{
    return smoothstep(
        clampFloat((0.55f - quality) / 0.55f, 0.0f, 1.0f)
    );
}

float calculateExtremeFailure(float quality)
{
    return smoothstep(
        clampFloat((0.24f - quality) / 0.24f, 0.0f, 1.0f)
    );
}

CompressorParams makeCompressorParams(
    float quality,
    float compressionBadness,
    float nearFailure,
    float extremeFailure
)
{
    CompressorParams params;

    const float threshold =
        lerp(0.16f, 0.035f, compressionBadness) -
        extremeFailure * 0.018f;

    const float ratio =
        lerp(12.0f, 40.0f, compressionBadness) +
        extremeFailure * 20.0f;

    const float attackMs =
        lerp(2.0f, 0.45f, compressionBadness);

    const float releaseMs =
        lerp(90.0f, 260.0f, compressionBadness) +
        nearFailure * 160.0f;

    params.threshold = std::max(0.001f, threshold);
    params.invRatio = 1.0f / std::max(1.0f, ratio);
    params.attackCoeff =
        1.0f - std::exp(-1.0f / ((attackMs / 1000.0f) * SampleRate));
    params.releaseCoeff =
        1.0f - std::exp(-1.0f / ((releaseMs / 1000.0f) * SampleRate));
    params.makeupGain =
        lerp(2.8f, 5.5f, compressionBadness) +
        nearFailure * 1.2f;
    params.limiterDrive =
        lerp(2.0f, 4.5f, compressionBadness) +
        extremeFailure * 2.2f;
    params.postLimiterGain =
        lerp(0.72f, 0.50f, compressionBadness) -
        extremeFailure * 0.10f;

    (void) quality;
    return params;
}

float processWalkieTalkieCompressor(
    float input,
    RadioFilterState& state,
    const CompressorParams& params
)
{
    const float detector = std::fabs(input);

    if (detector > state.compressorEnvelope) {
        state.compressorEnvelope +=
            params.attackCoeff * (detector - state.compressorEnvelope);
    } else {
        state.compressorEnvelope +=
            params.releaseCoeff * (detector - state.compressorEnvelope);
    }

    float gain = 1.0f;

    if (state.compressorEnvelope > params.threshold) {
        const float targetLevel =
            params.threshold +
            (state.compressorEnvelope - params.threshold) * params.invRatio;

        gain = targetLevel / (state.compressorEnvelope + 0.000001f);
    }

    float output = input * gain * params.makeupGain;

    output = fastSaturate(output * params.limiterDrive);
    output *= params.postLimiterGain;

    return output;
}

float processFailureGain(
    RadioFilterState& state,
    float nearFailure,
    float extremeFailure
)
{
    if (nearFailure <= 0.0f) {
        state.failureTargetGain = 1.0f;
        state.failureGain += (1.0f - state.failureGain) * 0.02f;
        state.failureNoiseEnvelope +=
            (0.0f - state.failureNoiseEnvelope) * 0.02f;

        return state.failureGain;
    }

    /*
        Random signal breakup.

        This creates small gaps and level collapses before the real max range
        cutoff happens, hiding the hard cutoff.
    */
    if (state.failureHoldFrames == 0) {
        const float eventChance =
            0.000015f +
            nearFailure * 0.00012f +
            extremeFailure * 0.00085f;

        if (random01(state) < eventChance) {
            const float dropoutRoll = random01(state);

            if (dropoutRoll < lerp(0.35f, 0.88f, extremeFailure)) {
                /*
                    Deep dropout.
                    At extreme failure this can almost fully mute syllables.
                */
                state.failureTargetGain =
                    lerp(0.22f, 0.0f, extremeFailure) *
                    random01(state);
            } else {
                /*
                    Smaller flutter dip.
                */
                state.failureTargetGain =
                    lerp(0.75f, 0.18f, nearFailure) *
                    lerp(0.65f, 1.0f, random01(state));
            }

            const float minHold = lerp(80.0f, 220.0f, nearFailure);
            const float maxHold = lerp(360.0f, 3200.0f, extremeFailure);

            state.failureHoldFrames =
                static_cast<uint32_t>(
                    lerp(minHold, maxHold, random01(state))
                );

            state.failureNoiseEnvelope =
                std::max(
                    state.failureNoiseEnvelope,
                    lerp(0.15f, 1.0f, extremeFailure)
                );
        } else {
            /*
                Small constant flutter near failure,
                even when there is no full dropout event.
            */
            state.failureTargetGain =
                1.0f -
                nearFailure * lerp(0.02f, 0.22f, random01(state)) -
                extremeFailure * lerp(0.10f, 0.55f, random01(state));

            state.failureHoldFrames =
                static_cast<uint32_t>(
                    lerp(40.0f, 260.0f, random01(state))
                );
        }
    } else {
        --state.failureHoldFrames;
    }

    /*
        Fast enough to sound broken,
        smooth enough to avoid digital clicking.
    */
    const float gainSmoothing =
        lerp(0.055f, 0.018f, extremeFailure);

    state.failureGain +=
        (state.failureTargetGain - state.failureGain) * gainSmoothing;

    state.failureNoiseEnvelope +=
        (0.0f - state.failureNoiseEnvelope) *
        lerp(0.006f, 0.0025f, extremeFailure);

    return clampFloat(state.failureGain, 0.0f, 1.0f);
}

float processRadioFrame(
    float mono,
    RadioFilterState& state,
    const CompressorParams& compressorParams,
    float quality,
    float filterBadness,
    float nearFailure,
    float extremeFailure,
    float roughMix,
    float roughLevels,
    float staticAmount,
    float crackleChance,
    float crackleAmount,
    float outputGain
)
{
    /*
        Strong radio bandpass.

        Two high-pass filters remove low-end voice body.
        Three low-pass filters remove high-end clarity.
    */
    float filtered = mono;

    filtered = state.voiceHighpassA.process(filtered);
    filtered = state.voiceHighpassB.process(filtered);

    filtered = state.voiceLowpassA.process(filtered);
    filtered = state.voiceLowpassB.process(filtered);
    filtered = state.voiceLowpassC.process(filtered);

    filtered = state.voicePresence.process(filtered);

    /*
        Aggressive walkie-talkie compression.
    */
    filtered = processWalkieTalkieCompressor(
        filtered,
        state,
        compressorParams
    );

    /*
        Extra transmitter grit.
    */
    const float transmitterGrit =
        lerp(1.15f, 2.10f, filterBadness) +
        nearFailure * 0.35f +
        extremeFailure * 0.95f;

    filtered = fastSaturate(filtered * transmitterGrit);

    /*
        Codec roughness near failure.
    */
    if (roughMix > 0.0f) {
        const float rough = quantizeSample(filtered, roughLevels);
        filtered = lerp(filtered, rough, roughMix);
    }

    /*
        Failure gain creates signal breakup/dropouts.
    */
    const float failureGain =
        processFailureGain(state, nearFailure, extremeFailure);

    filtered *= failureGain;

    /*
        Band-limited hiss.
    */
    float hiss = noise(state);

    hiss = state.hissHighpass.process(hiss);
    hiss = state.hissLowpass.process(hiss);

    filtered += hiss * staticAmount;

    /*
        Extra squelch noise during dropouts.
        This makes near-zero quality sound like a broken radio signal
        instead of just quiet voice.
    */
    if (state.failureNoiseEnvelope > 0.0001f) {
        float failureNoise = noise(state);

        failureNoise = state.failureNoiseHighpass.process(failureNoise);
        failureNoise = state.failureNoiseLowpass.process(failureNoise);

        const float dropoutNoiseAmount =
            state.failureNoiseEnvelope *
            lerp(0.010f, 0.075f, extremeFailure);

        filtered += failureNoise * dropoutNoiseAmount;
    }

    /*
        Occasional filtered crackle.
    */
    const float crackleRoll = random01(state);

    if (crackleRoll < crackleChance) {
        float crackle = noise(state) * crackleAmount;

        crackle = state.crackleHighpass.process(crackle);
        crackle = state.crackleLowpass.process(crackle);

        filtered += crackle;
    }

    /*
        Near absolute failure, some frames become mostly noise.
        This smears the edge before max range cuts the transmission.
    */
    if (extremeFailure > 0.0f) {
        const float smearChance =
            extremeFailure * 0.0018f;

        if (random01(state) < smearChance) {
            const float smearMix =
                lerp(0.15f, 0.75f, extremeFailure) *
                random01(state);

            float smearNoise = noise(state);

            smearNoise = state.failureNoiseHighpass.process(smearNoise);
            smearNoise = state.failureNoiseLowpass.process(smearNoise);

            filtered = lerp(filtered, smearNoise * 0.12f, smearMix);
        }
    }

    filtered *= outputGain;
    filtered = clampFloat(filtered, -1.0f, 1.0f);

    (void) quality;
    return filtered;
}

} // namespace

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

    RadioFilterState& state = g_radioState;

    /*
        quality:
            1.0 = best signal
            0.0 = worst signal

        badness:
            0.0 = best signal
            1.0 = worst signal
    */
    const float badness = 1.0f - quality;

    /*
        Main degradation curve.
    */
    const float filterBadness = smoothstep(badness);

    /*
        Near failure starts before quality reaches zero.
        Extreme failure is the "almost unreadable" area.
    */
    const float nearFailure = calculateNearFailure(quality);
    const float extremeFailure = calculateExtremeFailure(quality);

    /*
        Voice bandwidth.

        Good quality:
            roughly 260 Hz - 3900 Hz

        Medium quality:
            normal radio degradation

        Near zero quality:
            bandwidth collapses into a very narrow unreadable band
    */
    const float rawHighpassCutoff =
        lerp(260.0f, 620.0f, filterBadness) +
        nearFailure * 360.0f +
        extremeFailure * 210.0f;

    const float rawLowpassCutoff =
        lerp(3900.0f, 2200.0f, filterBadness) -
        nearFailure * 690.0f -
        extremeFailure * 640.0f;

    const float highpassCutoff =
        clampFloat(rawHighpassCutoff, 220.0f, 1500.0f);

    /*
        Keep the lowpass barely above the highpass at extreme failure.
        This creates a tiny tunnel-like band instead of invalid filter values.
    */
    const float minimumBrokenBandwidth =
        lerp(520.0f, 130.0f, extremeFailure);

    const float lowpassCutoff =
        clampFloat(
            std::max(rawLowpassCutoff, highpassCutoff + minimumBrokenBandwidth),
            highpassCutoff + 80.0f,
            4200.0f
        );

    /*
        Midrange radio presence.

        Strong near failure, but pulled back slightly at total failure
        so it does not turn into a painful whistle.
    */
    const float presenceFrequency =
        lerp(1150.0f, 1420.0f, filterBadness) +
        extremeFailure * 120.0f;

    const float presenceGainDb =
        lerp(3.0f, 8.5f, filterBadness) +
        nearFailure * 2.0f -
        extremeFailure * 1.5f;

    /*
        Subtle codec roughness.

        Extreme failure uses more roughness, but still avoids the old
        obvious hard stepping.
    */
    const float roughMix =
        nearFailure * 0.05f +
        extremeFailure * 0.16f;

    const float roughLevels =
        lerp(768.0f, 72.0f, extremeFailure);

    /*
        Hiss and crackle.

        At extreme failure this gets stronger, but the voice also drops out,
        so it feels like a failing radio rather than just louder noise.
    */
    const float staticAmount =
        lerp(0.00020f, 0.0035f, filterBadness) +
        nearFailure * 0.0030f +
        extremeFailure * 0.0095f;

    const float crackleChance =
        lerp(0.00001f, 0.0015f, filterBadness) +
        nearFailure * 0.0035f +
        extremeFailure * 0.0100f;

    const float crackleAmount =
        lerp(0.0015f, 0.0180f, filterBadness) +
        nearFailure * 0.0220f +
        extremeFailure * 0.0450f;

    /*
        Set filter coefficients once per audio block.
    */
    state.voiceHighpassA.setHighpass(highpassCutoff, 0.707f);
    state.voiceHighpassB.setHighpass(highpassCutoff, 0.707f);

    state.voiceLowpassA.setLowpass(lowpassCutoff, 0.707f);
    state.voiceLowpassB.setLowpass(lowpassCutoff, 0.707f);
    state.voiceLowpassC.setLowpass(lowpassCutoff, 0.707f);

    state.voicePresence.setPeak(
        presenceFrequency,
        1.1f,
        presenceGainDb
    );

    /*
        Filter static and failure noise so it sounds like radio noise.
    */
    state.hissHighpass.setHighpass(800.0f, 0.707f);
    state.hissLowpass.setLowpass(3600.0f, 0.707f);

    state.crackleHighpass.setHighpass(900.0f, 0.707f);
    state.crackleLowpass.setLowpass(3000.0f, 0.707f);

    state.failureNoiseHighpass.setHighpass(650.0f, 0.707f);
    state.failureNoiseLowpass.setLowpass(2600.0f, 0.707f);

    /*
        Fade the whole radio slightly near absolute failure.
        This helps prevent a sudden hard edge at max range.
    */
    const float failureOutputFade =
        lerp(1.0f, 0.35f, extremeFailure);

    const float outputGain =
        volume * 0.95f * failureOutputFade;

    const CompressorParams compressorParams =
        makeCompressorParams(
            quality,
            filterBadness,
            nearFailure,
            extremeFailure
        );

    if (channelCount == 2) {
        float* frame = outputPCM;

        for (uint32_t i = 0; i < sampleCount; ++i) {
            const float mono = (frame[0] + frame[1]) * 0.5f;

            const float filtered = processRadioFrame(
                mono,
                state,
                compressorParams,
                quality,
                filterBadness,
                nearFailure,
                extremeFailure,
                roughMix,
                roughLevels,
                staticAmount,
                crackleChance,
                crackleAmount,
                outputGain
            );

            frame[0] = filtered;
            frame[1] = filtered;
            frame += 2;
        }

        return;
    }

    for (uint32_t frameIndex = 0; frameIndex < sampleCount; ++frameIndex) {
        float* frame = outputPCM + static_cast<std::size_t>(frameIndex) * channelCount;
        float mono = 0.0f;

        for (uint16_t ch = 0; ch < channelCount; ++ch) {
            mono += frame[ch];
        }

        mono /= static_cast<float>(channelCount);

        const float filtered = processRadioFrame(
            mono,
            state,
            compressorParams,
            quality,
            filterBadness,
            nearFailure,
            extremeFailure,
            roughMix,
            roughLevels,
            staticAmount,
            crackleChance,
            crackleAmount,
            outputGain
        );

        for (uint16_t ch = 0; ch < channelCount; ++ch) {
            frame[ch] = filtered;
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
    }

    float* frame = outputPCM;

    for (uint32_t i = 0; i < sampleCount; ++i) {
        frame[0] *= leftGain;
        frame[1] *= rightGain;
        frame += channelCount;
    }
}

}
