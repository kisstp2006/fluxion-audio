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

        class OscillatorData;

        class OscillatorStream final: public Stream
        {
        public:
            explicit OscillatorStream(OscillatorData& oscillatorData) noexcept;

            void reset() override
            {
                position = 0;
            }

            void generateSamples(std::uint32_t frames, std::vector<float>& samples) override;

        private:
            std::uint64_t position = 0;
        };

        class OscillatorData final: public Data
        {
        public:
            OscillatorData(OscillatorType initType, float initFrequency, float initAmplitude,
                          float initLength, std::uint32_t initSampleRate) noexcept:
                Data{1, initSampleRate},
                type{initType}, frequency{initFrequency}, amplitude{initAmplitude}, length{initLength}
            {
            }

            auto getType() const noexcept { return type; }
            auto getFrequency() const noexcept { return frequency; }
            auto getAmplitude() const noexcept { return amplitude; }
            auto getLength() const noexcept { return length; }

            std::unique_ptr<Stream> createStream() override
            {
                return std::make_unique<OscillatorStream>(*this);
            }

        private:
            OscillatorType type;
            float frequency;
            float amplitude;
            float length;
        };

        OscillatorStream::OscillatorStream(OscillatorData& oscillatorData) noexcept:
            Stream{oscillatorData}
        {
        }

        void OscillatorStream::generateSamples(std::uint32_t frames, std::vector<float>& samples)
        {
            const auto& oscillatorData = static_cast<const OscillatorData&>(data);
            samples.resize(frames);

            const auto sampleRate = data.getSampleRate();
            const auto length = oscillatorData.getLength();
            const std::uint64_t totalFrames = length > 0.0F
                ? static_cast<std::uint64_t>(length * static_cast<float>(sampleRate))
                : 0; // 0 means endless

            std::uint32_t written = 0;
            while (written < frames && (totalFrames == 0 || position < totalFrames))
            {
                const auto cycles = static_cast<float>(position) * oscillatorData.getFrequency() / static_cast<float>(sampleRate);
                const auto phase = cycles - std::floor(cycles);
                samples[written] = waveAt(oscillatorData.getType(), phase) * oscillatorData.getAmplitude();
                ++position;
                ++written;
            }

            if (written < frames)
            {
                std::fill(samples.begin() + written, samples.end(), 0.0F);
                playing = false;
                reset();
            }
        }
    }

    std::unique_ptr<Data> makeOscillatorData(OscillatorType type, float frequency,
                                              float amplitude, float length,
                                              std::uint32_t sampleRate)
    {
        return std::make_unique<OscillatorData>(type, frequency, amplitude, length, sampleRate);
    }
}
