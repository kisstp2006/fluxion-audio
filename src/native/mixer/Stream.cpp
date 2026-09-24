// SPDX-License-Identifier: CC0-1.0

#include "Stream.hpp"

namespace fluxion_audio
{
    void Stream::seek(std::uint64_t frame)
    {
        const auto frames = data.getFrames();
        if (frames != 0 && frame > frames) frame = frames;
        rewind(frame);
        position = frame;
        carry = 0.0;
        publish();
    }

    void Stream::generateSamples(std::uint32_t frames, std::vector<float>& samples)
    {
        const auto channels = data.getChannels();
        samples.assign(static_cast<std::size_t>(frames) * channels, 0.0F);

        const auto length = data.getFrames();
        std::uint32_t done = 0;
        while (done < frames && playing)
        {
            const auto wanted = frames - done;
            const auto got = read(samples.data(), frames, done, wanted);
            done += got;
            position += got;
            // All that was asked for - and one of a known length that has
            // played its last frame with it ends now, not a mix later.
            if (got == wanted && (looping || length == 0 || position < length)) break;

            // The end. A clip that looped round and read nothing has nothing
            // in it, and ends rather than going round for ever.
            if (looping && position > 0)
            {
                rewind(0);
                position = 0;
                continue;
            }
            end();
        }

        publish();
    }

    void Stream::end()
    {
        playing = false;
        rewind(0);
        position = 0;
        if (state) state->ends.fetch_add(1, std::memory_order_release);
    }

    void Stream::publish() noexcept
    {
        if (!state) return;
        state->frame.store(position, std::memory_order_relaxed);
        state->playing.store(playing ? 1 : 0, std::memory_order_release);
    }
}
