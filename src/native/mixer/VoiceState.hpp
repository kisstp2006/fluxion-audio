// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_VOICESTATE_HPP
#define FLUXION_AUDIO_MIXER_VOICESTATE_HPP

#include <atomic>
#include <cstdint>

// What a playing stream says of itself to the thread that asked for it:
// whether it plays, how far into its clip it is, and how many times it has
// come to its end. The stream writes it as it mixes, on the mixing thread;
// anyone reads it, from any thread, without waiting on the mix.
//
// Two hold it - the stream, and whoever made the stream - and the last to
// let go frees it, so neither outlives the other's reading or writing.
struct fx_audio_voice_state
{
    std::atomic<int> holders{2};
    std::atomic<int> playing{0};
    std::atomic<std::uint64_t> frame{0};
    std::atomic<std::uint32_t> ends{0};
};

namespace fluxion_audio
{
    inline void releaseVoiceState(fx_audio_voice_state* state) noexcept
    {
        if (state && state->holders.fetch_sub(1, std::memory_order_acq_rel) == 1)
            delete state;
    }
}

#endif // FLUXION_AUDIO_MIXER_VOICESTATE_HPP
