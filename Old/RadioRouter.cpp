#include "RadioRouter.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>

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

float clamp01(float value)
{
    return std::max(0.0f, std::min(1.0f, value));
}

float distanceBetween(const Vec3& a, const Vec3& b)
{
    const float dx = a.x - b.x;
    const float dy = a.y - b.y;
    const float dz = a.z - b.z;
    
    return std::sqrt(dx * dx + dy * dy + dz * dz);
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

RadioRouteResult RadioRouter::evaluate(
    const PlayerRadioState& localPlayer,
    const PlayerRadioState& remotePlayer
) const
{
    RadioRouteResult best;
    
    const float distance = distanceBetween(
        localPlayer.position,
        remotePlayer.position
    );
    
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
            
            const float clearRange = 500.0f;
            const float maxRange = 3000.0f;
            
            const float quality = calculateRadioQuality(
                distance,
                clearRange,
                maxRange
            );
            
            if (quality <= 0.02f) {
                continue;
            }
            
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