// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_DATA_HPP
#define FLUXION_AUDIO_MIXER_DATA_HPP

#include <cstdint>
#include <memory>
#include "Object.hpp"
#include "VoiceState.hpp"

namespace fluxion_audio
{
    class Stream;

    // What a clip is: channels, a sample rate and a length, and a way to
    // open a `Stream` that reads through it from the start.
    class Data: public Object
    {
    public:
        Data() noexcept = default;
        Data(std::uint32_t initChannels, std::uint32_t initSampleRate) noexcept:
            channels{initChannels}, sampleRate{initSampleRate}
        {
        }

        // `state` is the stream's to write and to let go of.
        virtual std::unique_ptr<Stream> createStream(fx_audio_voice_state* state) = 0;

        auto getChannels() const noexcept { return channels; }
        auto getSampleRate() const noexcept { return sampleRate; }

        // How many frames it has: 0 for one with no end.
        virtual std::uint64_t getFrames() const noexcept { return 0; }

    protected:
        std::uint32_t channels = 0;
        std::uint32_t sampleRate = 0;
    };
}

#endif // FLUXION_AUDIO_MIXER_DATA_HPP
