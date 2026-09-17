// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_EFFECTS_VOICEEFFECTS_HPP
#define FLUXION_AUDIO_EFFECTS_VOICEEFFECTS_HPP

#include <cstdint>
#include <vector>
#include "../mixer/Processor.hpp"
#include "../third_party/smbPitchShift.hpp"

namespace fluxion_audio
{
    // A linear gain multiplier, one per voice, so `Device.setVolume` has
    // something in the bus graph to update.
    class GainProcessor final: public Processor
    {
    public:
        explicit GainProcessor(float initGain = 1.0F) noexcept: gain{initGain} {}

        void process(std::uint32_t, std::uint32_t, std::uint32_t, std::vector<float>& samples) override
        {
            for (auto& sample : samples)
                sample *= gain;
        }

        void setGain(float newGain) noexcept { gain = newGain; }

    private:
        float gain;
    };

    // Linear stereo pan: -1 is fully left, 0 is centre, 1 is fully right.
    // A no-op on anything but two channels, which is what `pan` means at all.
    class PanProcessor final: public Processor
    {
    public:
        explicit PanProcessor(float initPan = 0.0F) noexcept: pan{initPan} {}

        void process(std::uint32_t frames, std::uint32_t channels, std::uint32_t, std::vector<float>& samples) override
        {
            if (channels != 2) return;

            const float left = pan <= 0.0F ? 1.0F : 1.0F - pan;
            const float right = pan >= 0.0F ? 1.0F : 1.0F + pan;

            for (std::uint32_t frame = 0; frame < frames; ++frame)
            {
                samples[0 * frames + frame] *= left;
                samples[1 * frames + frame] *= right;
            }
        }

        void setPan(float newPan) noexcept { pan = newPan; }

    private:
        float pan;
    };

    // A phase-vocoder pitch shift, one octave down to one octave up, at
    // unity a straight passthrough that skips the FFT round trip entirely.
    // One `smb::PitchShift` per channel - each keeps its own overlap-add
    // history, so a stereo voice needs two independent ones, not one fed
    // twice.
    class PitchShiftProcessor final: public Processor
    {
    public:
        explicit PitchShiftProcessor(float initPitch = 1.0F) noexcept: pitch{initPitch} {}

        void process(std::uint32_t frames, std::uint32_t channels, std::uint32_t sampleRate,
                     std::vector<float>& samples) override
        {
            if (pitch == 1.0F) return;

            while (shifters.size() < channels)
                shifters.emplace_back();

            scratch.resize(frames);
            for (std::uint32_t channel = 0; channel < channels; ++channel)
            {
                float* channelSamples = &samples[channel * frames];
                shifters[channel].process(pitch, frames, sampleRate, channelSamples, scratch.data());
                std::copy(scratch.begin(), scratch.end(), channelSamples);
            }
        }

        void setPitch(float newPitch) noexcept { pitch = newPitch; }

    private:
        float pitch;
        std::vector<smb::PitchShift<1024, 4>> shifters;
        std::vector<float> scratch;
    };
}

#endif // FLUXION_AUDIO_EFFECTS_VOICEEFFECTS_HPP
