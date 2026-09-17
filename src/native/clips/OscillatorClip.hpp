// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_CLIPS_OSCILLATORCLIP_HPP
#define FLUXION_AUDIO_CLIPS_OSCILLATORCLIP_HPP

#include <cstdint>
#include <memory>
#include "../mixer/Data.hpp"

namespace fluxion_audio
{
    enum class OscillatorType
    {
        sine,
        square,
        sawtooth,
        triangle
    };

    // A clip with no bytes behind it: a waveform generated one frame at a
    // time as it plays. `length` is in seconds; 0 means it never finishes on
    // its own.
    std::unique_ptr<Data> makeOscillatorData(OscillatorType type, float frequency,
                                              float amplitude, float length,
                                              std::uint32_t sampleRate);
}

#endif // FLUXION_AUDIO_CLIPS_OSCILLATORCLIP_HPP
