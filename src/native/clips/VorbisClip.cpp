// SPDX-License-Identifier: CC0-1.0

#include "VorbisClip.hpp"
#include "../mixer/Stream.hpp"
#include "../mixer/MixerError.hpp"

#ifdef _MSC_VER
#  pragma warning( push )
#  pragma warning( disable : 4100 )
#  pragma warning( disable : 4244 )
#  pragma warning( disable : 4245 )
#  pragma warning( disable : 4456 )
#  pragma warning( disable : 4457 )
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wconversion"
#  pragma GCC diagnostic ignored "-Wdouble-promotion"
#  pragma GCC diagnostic ignored "-Wold-style-cast"
#  pragma GCC diagnostic ignored "-Wshadow"
#  pragma GCC diagnostic ignored "-Wsign-conversion"
#  pragma GCC diagnostic ignored "-Wtype-limits"
#  pragma GCC diagnostic ignored "-Wunused-function"
#  pragma GCC diagnostic ignored "-Wunused-parameter"
#  pragma GCC diagnostic ignored "-Wunused-value"
#  ifdef __clang__
#    pragma GCC diagnostic ignored "-Wcomma"
#    pragma GCC diagnostic ignored "-Wconditional-uninitialized"
#  else
#    pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#  endif
#endif

#include "../third_party/stb_vorbis.c"

#ifdef _MSC_VER
#  pragma warning( pop )
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif

namespace fluxion_audio
{
    namespace
    {
        class VorbisData;

        class VorbisStream final: public Stream
        {
        public:
            explicit VorbisStream(VorbisData& vorbisData);

            ~VorbisStream() override
            {
                if (vorbisStream)
                    stb_vorbis_close(vorbisStream);
            }

            void reset() override
            {
                stb_vorbis_seek_start(vorbisStream);
            }

            void generateSamples(std::uint32_t frames, std::vector<float>& samples) override;

        private:
            stb_vorbis* vorbisStream = nullptr;
        };

        class VorbisData final: public Data
        {
        public:
            explicit VorbisData(const std::uint8_t* bytes, std::size_t length):
                encoded(bytes, bytes + length)
            {
                stb_vorbis* vorbisStream = stb_vorbis_open_memory(encoded.data(),
                                                                  static_cast<int>(encoded.size()),
                                                                  nullptr, nullptr);
                if (!vorbisStream)
                    throw Error{"Failed to load Vorbis stream"};

                const stb_vorbis_info info = stb_vorbis_get_info(vorbisStream);
                channels = static_cast<std::uint32_t>(info.channels);
                sampleRate = info.sample_rate;

                stb_vorbis_close(vorbisStream);
            }

            auto& getEncoded() const noexcept { return encoded; }

            std::unique_ptr<Stream> createStream() override
            {
                return std::make_unique<VorbisStream>(*this);
            }

        private:
            std::vector<std::uint8_t> encoded;
        };

        VorbisStream::VorbisStream(VorbisData& vorbisData):
            Stream{vorbisData}
        {
            vorbisStream = stb_vorbis_open_memory(vorbisData.getEncoded().data(),
                                                  static_cast<int>(vorbisData.getEncoded().size()),
                                                  nullptr, nullptr);
        }

        void VorbisStream::generateSamples(std::uint32_t frames, std::vector<float>& samples)
        {
            const auto channels = data.getChannels();
            const auto neededSize = frames * channels;
            samples.resize(neededSize);

            int resultFrames = 0;

            if (neededSize > 0)
            {
                if (vorbisStream->eof)
                    reset();

                std::vector<float*> channelData(channels);
                for (std::uint32_t channel = 0; channel < channels; ++channel)
                    channelData[channel] = &samples[channel * frames];

                resultFrames = stb_vorbis_get_samples_float(vorbisStream,
                                                            static_cast<int>(channels),
                                                            channelData.data(),
                                                            static_cast<int>(frames));
            }

            if (vorbisStream->eof)
            {
                playing = false;
                reset();
            }

            for (std::uint32_t channel = 0; channel < channels; ++channel)
                for (auto frame = static_cast<std::uint32_t>(resultFrames); frame < frames; ++frame)
                    samples[channel * frames + frame] = 0.0F;
        }
    }

    std::unique_ptr<Data> makeVorbisData(const std::uint8_t* bytes, std::size_t length)
    {
        return std::make_unique<VorbisData>(bytes, length);
    }
}
