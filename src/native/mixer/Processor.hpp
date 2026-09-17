// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_PROCESSOR_HPP
#define FLUXION_AUDIO_MIXER_PROCESSOR_HPP

#include <cstdint>
#include <vector>
#include "Object.hpp"
#include "Bus.hpp"

namespace fluxion_audio
{
    // A DSP effect attached to a `Bus`: gain, a filter, a delay line.
    class Processor: public Object
    {
        friend Bus;
    public:
        Processor() noexcept = default;
        ~Processor() override
        {
            if (bus) bus->removeProcessor(this);
        }

        Processor(const Processor&) = delete;
        Processor& operator=(const Processor&) = delete;
        Processor(Processor&&) = delete;
        Processor& operator=(Processor&&) = delete;

        virtual void process(std::uint32_t frames, std::uint32_t channels, std::uint32_t sampleRate,
                             std::vector<float>& samples) = 0;

        auto isEnabled() const noexcept { return enabled; }
        void setEnabled(bool newEnabled) { enabled = newEnabled; }

    private:
        Bus* bus = nullptr;
        bool enabled = true;
    };
}

#endif // FLUXION_AUDIO_MIXER_PROCESSOR_HPP
