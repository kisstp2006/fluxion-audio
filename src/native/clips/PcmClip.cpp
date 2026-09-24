// SPDX-License-Identifier: CC0-1.0

#include <algorithm>
#include "PcmClip.hpp"
#include "../mixer/Stream.hpp"

namespace fluxion_audio
{
    namespace
    {
        class PcmData final: public Data
        {
        public:
            PcmData(std::uint32_t initChannels, std::uint32_t initSampleRate,
                    std::vector<float> initData):
                Data{initChannels, initSampleRate},
                samples{std::move(initData)}
            {
            }

            auto& getSamples() const noexcept { return samples; }

            std::uint64_t getFrames() const noexcept override
            {
                return channels == 0 ? 0 : samples.size() / channels;
            }

            std::unique_ptr<Stream> createStream(fx_audio_voice_state* state) override;

        private:
            std::vector<float> samples;
        };

        class PcmStream final: public Stream
        {
        public:
            PcmStream(PcmData& pcmData, fx_audio_voice_state* state) noexcept:
                Stream{pcmData, state}
            {
            }

        protected:
            std::uint32_t read(float* samples, std::uint32_t stride, std::uint32_t offset, std::uint32_t count) override
            {
                const auto& pcmData = static_cast<const PcmData&>(data);
                const auto& source = pcmData.getSamples();
                const auto channels = pcmData.getChannels();
                const auto sourceFrames = pcmData.getFrames();
                if (cursor >= sourceFrames) return 0;

                const auto taken = static_cast<std::uint32_t>(std::min<std::uint64_t>(count, sourceFrames - cursor));
                for (std::uint32_t channel = 0; channel < channels; ++channel)
                {
                    const auto from = source.begin() + static_cast<std::ptrdiff_t>(channel * sourceFrames + cursor);
                    std::copy(from, from + taken, samples + channel * stride + offset);
                }
                cursor += taken;
                return taken;
            }

            void rewind(std::uint64_t frame) override
            {
                cursor = frame;
            }

        private:
            std::uint64_t cursor = 0;
        };

        std::unique_ptr<Stream> PcmData::createStream(fx_audio_voice_state* state)
        {
            return std::make_unique<PcmStream>(*this, state);
        }
    }

    std::unique_ptr<Data> makePcmData(std::uint32_t channels, std::uint32_t sampleRate,
                                      std::vector<float> planar)
    {
        return std::make_unique<PcmData>(channels, sampleRate, std::move(planar));
    }
}
