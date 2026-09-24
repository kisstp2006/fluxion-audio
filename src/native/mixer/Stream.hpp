// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_STREAM_HPP
#define FLUXION_AUDIO_MIXER_STREAM_HPP

#include <cstdint>
#include <vector>
#include "Object.hpp"
#include "Data.hpp"
#include "Bus.hpp"
#include "VoiceState.hpp"

namespace fluxion_audio
{
    // A clip being played: a place in its `Data`, the bus it feeds, and how
    // it goes - looping or not, at what speed. What each kind of clip does
    // is read from where it is and go back to a frame; coming to the end,
    // going round again, and saying so are this class's.
    class Stream: public Object
    {
        friend Bus;
    public:
        Stream(Data& initData, fx_audio_voice_state* initState) noexcept:
            data{initData}, state{initState}
        {
        }

        ~Stream() override
        {
            if (output) output->removeInput(this);
            releaseVoiceState(state);
        }

        Stream(const Stream&) = delete;
        Stream& operator=(const Stream&) = delete;
        Stream(Stream&&) = delete;
        Stream& operator=(Stream&&) = delete;

        auto& getData() const noexcept { return data; }

        void setOutput(Bus* newOutput)
        {
            if (output) output->removeInput(this);
            output = newOutput;
            if (output) output->addInput(this);
        }

        auto isPlaying() const noexcept { return playing; }

        void play() noexcept
        {
            playing = true;
            publish();
        }

        // Held where it is, or with `shouldReset`, back at the start.
        void stop(bool shouldReset)
        {
            playing = false;
            if (shouldReset)
                seek(0);
            else
                publish();
        }

        void setLooping(bool newLooping) noexcept { looping = newLooping; }

        // 1 plays the clip as it was recorded; 2 twice as fast, an octave up.
        void setSpeed(float newSpeed) noexcept { speed = newSpeed > 0.0F ? newSpeed : 0.0F; }

        // From `frame` of the clip on - its end, for one past it.
        void seek(std::uint64_t frame);

        // `frames` frames in the clip's own channels, planar: what it has from
        // where it is, from the start again when it loops, and silence past
        // the end of one that does not.
        void generateSamples(std::uint32_t frames, std::vector<float>& samples);

    protected:
        // Up to `count` frames from where it is, channel `c`'s frame `i` at
        // `samples[c * stride + offset + i]`. Fewer only at the end.
        virtual std::uint32_t read(float* samples, std::uint32_t stride, std::uint32_t offset, std::uint32_t count) = 0;

        // Read from `frame` on.
        virtual void rewind(std::uint64_t frame) = 0;

        Data& data;

    private:
        void publish() noexcept;
        // Stopped at its end, back at the start, and said.
        void end();

        Bus* output = nullptr;
        fx_audio_voice_state* state;
        std::uint64_t position = 0;
        // The part of a frame of the clip the last mix owed, at a speed or a
        // rate that is not a whole number of frames a mix.
        double carry = 0.0;
        float speed = 1.0F;
        bool playing = false;
        bool looping = false;
    };
}

#endif // FLUXION_AUDIO_MIXER_STREAM_HPP
