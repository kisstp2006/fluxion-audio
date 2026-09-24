// SPDX-License-Identifier: CC0-1.0

#include "Mp3Clip.hpp"
#include "../mixer/Stream.hpp"
#include "../mixer/MixerError.hpp"

#include <algorithm>
#include <climits>
#include <cstring>
#include <vector>

#if defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wconversion"
#  pragma GCC diagnostic ignored "-Wsign-conversion"
#  pragma GCC diagnostic ignored "-Wold-style-cast"
#  pragma GCC diagnostic ignored "-Wshadow"
#  pragma GCC diagnostic ignored "-Wunused-function"
#endif

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#include "../third_party/minimp3.h"

#if defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif

namespace fluxion_audio
{
    namespace
    {
        // One MPEG frame of the file: where it is, and which of the clip's
        // frames of sound it holds.
        struct Mp3Frame
        {
            std::size_t offset;
            std::uint64_t first;
            std::uint32_t count;
        };

        // The frames of sound an encoder put before the music and after it,
        // as the LAME tag in a first, silent frame says - what a clip that
        // loops leaves out, so it goes round without a gap.
        struct Gaps
        {
            std::uint32_t delay;
            std::uint32_t padding;
        };

        // Whether `frame` is such a first frame, and what it says.
        bool tagOf(const std::uint8_t* frame, std::size_t length, Gaps& gaps)
        {
            if (length < 4) return false;
            const bool mpeg1 = (frame[1] & 0x08) != 0;
            const bool mono = (frame[3] & 0xC0) == 0xC0;
            const bool crc = (frame[1] & 0x01) == 0;
            std::size_t at = 4 + (crc ? 2 : 0) + (mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17));
            if (at + 8 > length) return false;
            if (std::memcmp(frame + at, "Xing", 4) != 0 && std::memcmp(frame + at, "Info", 4) != 0) return false;
            const std::uint32_t flags = (std::uint32_t{frame[at + 4]} << 24) | (std::uint32_t{frame[at + 5]} << 16) |
                                        (std::uint32_t{frame[at + 6]} << 8) | frame[at + 7];
            at += 8;
            if (flags & 1) at += 4;
            if (flags & 2) at += 4;
            if (flags & 4) at += 100;
            if (flags & 8) at += 4;
            gaps = {0, 0};
            // The encoder's tag - LAME's, or one laid out as it is - after
            // the table: the delay and the padding, twelve bits each.
            if (at + 24 <= length && frame[at] != 0)
            {
                const std::uint8_t* tag = frame + at + 21;
                const int delay = ((tag[0] << 4) | (tag[1] >> 4)) + 529;
                const int padding = (((tag[1] & 0x0F) << 8) | tag[2]) - 529;
                gaps.delay = static_cast<std::uint32_t>(std::max(delay, 0));
                gaps.padding = static_cast<std::uint32_t>(std::max(padding, 0));
            }
            return true;
        }

        class Mp3Data final: public Data
        {
        public:
            Mp3Data(const std::uint8_t* bytes, std::size_t length):
                encoded(bytes, bytes + length)
            {
                mp3dec_t decoder;
                mp3dec_init(&decoder);
                std::size_t at = 0;
                std::uint64_t total = 0;
                Gaps gaps{0, 0};
                bool first = true;
                while (at < encoded.size())
                {
                    mp3dec_frame_info_t info{};
                    const int remaining = static_cast<int>(std::min<std::size_t>(encoded.size() - at, INT_MAX));
                    const int count = mp3dec_decode_frame(&decoder, encoded.data() + at, remaining, nullptr, &info);
                    if (info.frame_bytes == 0) break;
                    if (count > 0)
                    {
                        const std::size_t start = at + static_cast<std::size_t>(info.frame_offset);
                        const auto frameLength = static_cast<std::size_t>(info.frame_bytes - info.frame_offset);
                        // A first frame that only says how the file was
                        // encoded is no sound.
                        const bool tag = first && tagOf(encoded.data() + start, frameLength, gaps);
                        first = false;
                        if (tag)
                        {
                            channels = static_cast<std::uint32_t>(info.channels);
                            sampleRate = static_cast<std::uint32_t>(info.hz);
                            at += static_cast<std::size_t>(info.frame_bytes);
                            continue;
                        }
                        if (frames.empty() && channels == 0)
                        {
                            channels = static_cast<std::uint32_t>(info.channels);
                            sampleRate = static_cast<std::uint32_t>(info.hz);
                        }
                        frames.push_back({start, total, static_cast<std::uint32_t>(count)});
                        total += static_cast<std::uint64_t>(count);
                    }
                    at += static_cast<std::size_t>(info.frame_bytes);
                }
                if (frames.empty() || channels == 0)
                    throw Error{"Failed to load MP3 stream"};

                skip = std::min<std::uint64_t>(gaps.delay, total);
                const auto end = total - std::min<std::uint64_t>(gaps.padding, total - skip);
                music = end - skip;
            }

            auto& getEncoded() const noexcept { return encoded; }
            auto& getIndex() const noexcept { return frames; }
            auto getSkip() const noexcept { return skip; }

            std::uint64_t getFrames() const noexcept override { return music; }

            std::unique_ptr<Stream> createStream(fx_audio_voice_state* state) override;

        private:
            std::vector<std::uint8_t> encoded;
            std::vector<Mp3Frame> frames;
            // Frames of sound before the music: the encoder's delay.
            std::uint64_t skip = 0;
            // Frames of the music itself.
            std::uint64_t music = 0;
        };

        // Decoded a frame at a time as it plays.
        class Mp3Stream final: public Stream
        {
        public:
            Mp3Stream(Mp3Data& mp3Data, fx_audio_voice_state* state):
                Stream{mp3Data, state}
            {
                rewind(0);
            }

        protected:
            std::uint32_t read(float* samples, std::uint32_t stride, std::uint32_t offset, std::uint32_t count) override
            {
                const auto channels = data.getChannels();
                std::uint32_t got = 0;
                while (got < count && left > 0)
                {
                    if (at == decoded)
                    {
                        if (!decodeNext()) break;
                        continue;
                    }
                    const auto taken = static_cast<std::uint32_t>(std::min<std::uint64_t>(
                        std::min<std::uint32_t>(count - got, decoded - at), left));
                    for (std::uint32_t frame = 0; frame < taken; ++frame)
                    {
                        const float* from = &pcm[static_cast<std::size_t>(at + frame) * frameChannels];
                        for (std::uint32_t channel = 0; channel < channels; ++channel)
                        {
                            float sample;
                            if (frameChannels == channels)
                                sample = from[channel];
                            else if (frameChannels == 1)
                                sample = from[0];
                            else
                                sample = (from[0] + from[1]) * 0.5F;
                            samples[channel * stride + offset + got + frame] = sample;
                        }
                    }
                    at += taken;
                    got += taken;
                    left -= taken;
                }
                return got;
            }

            // From the frame holding `frame`, with the few before it decoded
            // and let go: a frame's sound may start in the bytes of the ones
            // before it.
            void rewind(std::uint64_t frame) override
            {
                const auto& mp3Data = static_cast<const Mp3Data&>(data);
                const auto& index = mp3Data.getIndex();
                const auto target = frame + mp3Data.getSkip();
                const auto found = std::upper_bound(index.begin(), index.end(), target,
                    [](std::uint64_t wanted, const Mp3Frame& f) { return wanted < f.first; });
                const std::size_t holding = found == index.begin() ? 0 : static_cast<std::size_t>(found - index.begin()) - 1;

                mp3dec_init(&decoder);
                pending = 0;
                cursor = holding >= 3 ? holding - 3 : 0;
                while (cursor < holding) decodeNext();
                decoded = 0;
                at = 0;
                pending = holding < index.size() && target > index[holding].first ? target - index[holding].first : 0;
                const auto length = mp3Data.getFrames();
                left = frame < length ? length - frame : 0;
            }

        private:
            bool decodeNext()
            {
                const auto& mp3Data = static_cast<const Mp3Data&>(data);
                const auto& index = mp3Data.getIndex();
                const auto& encoded = mp3Data.getEncoded();
                if (cursor >= index.size()) return false;
                const auto from = index[cursor].offset;
                ++cursor;
                mp3dec_frame_info_t info{};
                const int remaining = static_cast<int>(std::min<std::size_t>(encoded.size() - from, INT_MAX));
                const int count = mp3dec_decode_frame(&decoder, encoded.data() + from, remaining, pcm, &info);
                frameChannels = info.channels > 0 ? static_cast<std::uint32_t>(info.channels) : 1;
                decoded = count > 0 ? static_cast<std::uint32_t>(count) : 0;
                const auto skipped = static_cast<std::uint32_t>(std::min<std::uint64_t>(pending, decoded));
                at = skipped;
                pending -= skipped;
                return true;
            }

            mp3dec_t decoder{};
            float pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
            // The next frame of the index to decode.
            std::size_t cursor = 0;
            std::uint32_t frameChannels = 1;
            // Frames of sound decoded from the last one, and how many are used.
            std::uint32_t decoded = 0;
            std::uint32_t at = 0;
            // Frames of sound still to let go of before the place asked for.
            std::uint64_t pending = 0;
            // Frames of sound before the end of the music.
            std::uint64_t left = 0;
        };

        std::unique_ptr<Stream> Mp3Data::createStream(fx_audio_voice_state* state)
        {
            return std::make_unique<Mp3Stream>(*this, state);
        }
    }

    std::unique_ptr<Data> makeMp3Data(const std::uint8_t* bytes, std::size_t length)
    {
        return std::make_unique<Mp3Data>(bytes, length);
    }
}
