// SPDX-License-Identifier: CC0-1.0

#include "OscillatorClip.hpp"
#include "../mixer/Stream.hpp"

#include <algorithm>
#include <cmath>

namespace fluxion_audio
{
    namespace
    {
        constexpr float tau = 6.28318530717958647692F;

        // `phase` is the fraction of one cycle completed, wrapped to [0, 1)
        // by the caller - each shape is defined directly from that, not
        // pieced together from magic offsets.
        float waveAt(OscillatorType type, float phase) noexcept
        {
            switch (type)
            {
                case OscillatorType::sine: return std::sin(phase * tau);
                case OscillatorType::square: return phase < 0.5F ? 1.0F : -1.0F;
                case OscillatorType::sawtooth: return phase * 2.0F - 1.0F;
                case OscillatorType::triangle: return 1.0F - 4.0F * std::fabs(phase - 0.5F);
            }
            return 0.0F;
        }

        class OscillatorData final: public Data
        {
        public:
            OscillatorData(OscillatorType initType, float initFrequency, float initAmplitude,
                          float initLength, std::uint32_t initSampleRate) noexcept:
                Data{1, initSampleRate},
                type{initType}, frequency{initFrequency}, amplitude{initAmplitude},
                frames{initLength > 0.0F ? static_cast<std::uint64_t>(std::llround(static_cast<double>(initLength) * initSampleRate)) : 0}
            {
            }

            auto getType() const noexcept { return type; }
            auto getFrequency() const noexcept { return frequency; }
            auto getAmplitude() const noexcept { return amplitude; }

            std::uint64_t getFrames() const noexcept override { return frames; }

            std::unique_ptr<Stream> createStream(fx_audio_voice_state* state) override;

        private:
            OscillatorType type;
            float frequency;
            float amplitude;
            // 0 for one that plays for ever.
            std::uint64_t frames;
        };

        class OscillatorStream final: public Stream
        {
        public:
            OscillatorStream(OscillatorData& oscillatorData, fx_audio_voice_state* state) noexcept:
                Stream{oscillatorData, state}
            {
            }

        protected:
            std::uint32_t read(float* samples, std::uint32_t stride, std::uint32_t offset, std::uint32_t count) override
            {
                (void)stride;
                const auto& oscillatorData = static_cast<const OscillatorData&>(data);
                const auto sampleRate = static_cast<float>(data.getSampleRate());
                const auto totalFrames = oscillatorData.getFrames();

                std::uint32_t written = 0;
                while (written < count && (totalFrames == 0 || cursor < totalFrames))
                {
                    const auto cycles = static_cast<float>(cursor) * oscillatorData.getFrequency() / sampleRate;
                    const auto phase = cycles - std::floor(cycles);
                    samples[offset + written] = waveAt(oscillatorData.getType(), phase) * oscillatorData.getAmplitude();
                    ++cursor;
                    ++written;
                }
                return written;
            }

            void rewind(std::uint64_t frame) override
            {
                cursor = frame;
            }

        private:
            std::uint64_t cursor = 0;
        };

        std::unique_ptr<Stream> OscillatorData::createStream(fx_audio_voice_state* state)
        {
            return std::make_unique<OscillatorStream>(*this, state);
        }
    }

    std::unique_ptr<Data> makeOscillatorData(OscillatorType type, float frequency,
                                              float amplitude, float length,
                                              std::uint32_t sampleRate)
    {
        return std::make_unique<OscillatorData>(type, frequency, amplitude, length, sampleRate);
    }
}
