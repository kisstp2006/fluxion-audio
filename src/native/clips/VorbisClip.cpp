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
                frames = stb_vorbis_stream_length_in_samples(vorbisStream);

                stb_vorbis_close(vorbisStream);
            }

            auto& getEncoded() const noexcept { return encoded; }

            std::uint64_t getFrames() const noexcept override { return frames; }

            std::unique_ptr<Stream> createStream(fx_audio_voice_state* state) override;

        private:
            std::vector<std::uint8_t> encoded;
            std::uint64_t frames = 0;
        };

        // Decoded as it plays, from the file's bytes in memory: a long piece
        // of music is never all samples at once.
        class VorbisStream final: public Stream
        {
        public:
            VorbisStream(VorbisData& vorbisData, fx_audio_voice_state* state):
                Stream{vorbisData, state}
            {
                vorbisStream = stb_vorbis_open_memory(vorbisData.getEncoded().data(),
                                                      static_cast<int>(vorbisData.getEncoded().size()),
                                                      nullptr, nullptr);
            }

            ~VorbisStream() override
            {
                if (vorbisStream)
                    stb_vorbis_close(vorbisStream);
            }

        protected:
            std::uint32_t read(float* samples, std::uint32_t stride, std::uint32_t offset, std::uint32_t count) override
            {
                if (!vorbisStream || count == 0) return 0;
                const auto channels = data.getChannels();
                channelData.resize(channels);
                std::uint32_t got = 0;
                // stb_vorbis hands out what one packet decodes to at a time.
                while (got < count)
                {
                    for (std::uint32_t channel = 0; channel < channels; ++channel)
                        channelData[channel] = samples + channel * stride + offset + got;
                    const int read = stb_vorbis_get_samples_float(vorbisStream,
                                                                  static_cast<int>(channels),
                                                                  channelData.data(),
                                                                  static_cast<int>(count - got));
                    if (read <= 0) break;
                    got += static_cast<std::uint32_t>(read);
                }
                return got;
            }

            void rewind(std::uint64_t frame) override
            {
                if (!vorbisStream) return;
                if (frame == 0)
                    stb_vorbis_seek_start(vorbisStream);
                else
                    stb_vorbis_seek(vorbisStream, static_cast<unsigned int>(frame));
            }

        private:
            stb_vorbis* vorbisStream = nullptr;
            std::vector<float*> channelData;
        };

        std::unique_ptr<Stream> VorbisData::createStream(fx_audio_voice_state* state)
        {
            return std::make_unique<VorbisStream>(*this, state);
        }
    }

    std::unique_ptr<Data> makeVorbisData(const std::uint8_t* bytes, std::size_t length)
    {
        return std::make_unique<VorbisData>(bytes, length);
    }
}
