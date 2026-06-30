#include "RadioRouter.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>

namespace {

float clamp01(float value)
{
    return std::max(0.0f, std::min(1.0f, value));
}

float clampRange(float value, float minValue, float maxValue)
{
    return std::max(minValue, std::min(maxValue, value));
}

float clampNonNegative(float value)
{
    return std::max(0.0f, value);
}

char upperAscii(char ch)
{
    return static_cast<char>(
        std::toupper(static_cast<unsigned char>(ch))
    );
}

char lowerAscii(char ch)
{
    return static_cast<char>(
        std::tolower(static_cast<unsigned char>(ch))
    );
}

bool hasNonSpaceCharacter(const std::string& value)
{
    for (char ch : value) {
        if (std::isspace(static_cast<unsigned char>(ch)) == 0) {
            return true;
        }
    }

    return false;
}

bool normalizedChannelEquals(const std::string& a, const std::string& b)
{
    std::size_t ai = 0;
    std::size_t bi = 0;

    while (true) {
        while (ai < a.size() && std::isspace(static_cast<unsigned char>(a[ai])) != 0) {
            ++ai;
        }

        while (bi < b.size() && std::isspace(static_cast<unsigned char>(b[bi])) != 0) {
            ++bi;
        }

        const bool aDone = ai >= a.size();
        const bool bDone = bi >= b.size();

        if (aDone || bDone) {
            return aDone && bDone;
        }

        if (upperAscii(a[ai]) != upperAscii(b[bi])) {
            return false;
        }

        ++ai;
        ++bi;
    }
}

bool equalsIgnoreCase(const std::string& value, const char* literal)
{
    std::size_t i = 0;

    for (; i < value.size() && literal[i] != '\0'; ++i) {
        if (lowerAscii(value[i]) != literal[i]) {
            return false;
        }
    }

    return i == value.size() && literal[i] == '\0';
}

std::string normalizeEar(const std::string& value)
{
    if (equalsIgnoreCase(value, "left")) {
        return "left";
    }

    if (equalsIgnoreCase(value, "right")) {
        return "right";
    }

    return "both";
}

float distanceSquared(const Vec3& a, const Vec3& b)
{
    const float dx = a.x - b.x;
    const float dy = a.y - b.y;
    const float dz = a.z - b.z;

    return dx * dx + dy * dy + dz * dz;
}

float calculateRadioQuality(float distance, float clearRange, float maxRange)
{
    if (maxRange <= clearRange) {
        return distance <= maxRange ? 1.0f : 0.0f;
    }

    if (distance <= clearRange) {
        return 1.0f;
    }

    if (distance >= maxRange) {
        return 0.0f;
    }

    const float t = clamp01((distance - clearRange) / (maxRange - clearRange));

    // Smooth degradation curve.
    const float smooth = t * t * (3.0f - 2.0f * t);

    return 1.0f - smooth;
}

} // namespace

RadioRouteResult RadioRouter::evaluate(
    const PlayerRadioState& localPlayer,
    const PlayerRadioState& remotePlayer
) const
{
    RadioRouteResult best;

    const float distSq = distanceSquared(localPlayer.position, remotePlayer.position);
    bool haveDistance = false;
    float distance = 0.0f;

    for (const auto& remoteRadio : remotePlayer.radios) {
        if (!remoteRadio.transmitting || !hasNonSpaceCharacter(remoteRadio.channel)) {
            continue;
        }

        const float clearRange = clampNonNegative(remoteRadio.minDistance);
        const float maxRange = std::max(
            clearRange + 1.0f,
            clampNonNegative(remoteRadio.maxDistance)
        );

        if (distSq > maxRange * maxRange) {
            continue;
        }

        for (const auto& localRadio : localPlayer.radios) {
            if (!localRadio.listening || !hasNonSpaceCharacter(localRadio.channel)) {
                continue;
            }

            if (!normalizedChannelEquals(localRadio.channel, remoteRadio.channel)) {
                continue;
            }

            if (!haveDistance) {
                distance = std::sqrt(distSq);
                haveDistance = true;
            }

            const float quality = calculateRadioQuality(
                distance,
                clearRange,
                maxRange
            );

            if (quality <= 0.02f) {
                continue;
            }

            const float volume = clampRange(localRadio.volume, 0.0f, 2.0f);
            const float effectiveVolume = volume * (0.35f + 0.65f * quality);

            const float score = effectiveVolume * quality;
            const float bestScore = best.volume * best.quality;

            if (!best.audible || score > bestScore) {
                best.audible = true;
                best.volume = effectiveVolume;
                best.quality = quality;
                best.channel = localRadio.channel;
                best.ear = normalizeEar(localRadio.ear);
                best.localRadioId = localRadio.id;
                best.remoteRadioId = remoteRadio.id;
            }
        }
    }

    return best;
}
