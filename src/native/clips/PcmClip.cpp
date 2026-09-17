// SPDX-License-Identifier: CC0-1.0

#include "PcmClip.hpp"
#include "../mixer/Stream.hpp"

namespace fluxion_audio
{
    namespace
    {
        class PcmData;

        class PcmStream final: public Stream
        {
        public:
            explicit PcmStream(PcmData& pcmData) noexcept;

            void reset() override
            {
                position = 0;
            }

            void generateSamples(std::uint32_t frames, std::vector<float>& samples) override;

        private:
            std::uint32_t position = 0;
        };

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

            std::unique_ptr<Stream> createStream() override
            {
                return std::make_unique<PcmStream>(*this);
            }

        private:
            std::vector<float> samples;
        };

        PcmStream::PcmStream(PcmData& pcmData) noexcept:
            Stream{pcmData}
        {
        }

        void PcmStream::generateSamples(std::uint32_t frames, std::vector<float>& samples)
        {
            const auto& pcmData = static_cast<PcmData&>(data);
            const auto& dataSamples = pcmData.getSamples();
            const auto channels = pcmData.getChannels();

            const auto neededSize = frames * channels;
            samples.resize(neededSize);

            const auto sourceFrames = static_cast<std::uint32_t>(dataSamples.size() / channels);
            const auto copyFrames = (frames > sourceFrames - position) ? sourceFrames - position : frames;

            for (std::uint32_t channel = 0; channel < channels; ++channel)
            {
                const auto sourceChannel = &dataSamples[channel * sourceFrames];
                const auto outputChannel = &samples[channel * frames];

                for (std::uint32_t frame = 0; frame < copyFrames; ++frame)
                    outputChannel[frame] = sourceChannel[frame + position];

                for (std::uint32_t frame = copyFrames; frame < frames; ++frame)
                    outputChannel[frame] = 0.0F;
            }

            position += copyFrames;

            if (sourceFrames - position == 0)
            {
                playing = false;
                reset();
            }
        }
    }

    std::unique_ptr<Data> makePcmData(std::uint32_t channels, std::uint32_t sampleRate,
                                      std::vector<float> planar)
    {
        return std::make_unique<PcmData>(channels, sampleRate, std::move(planar));
    }
}
