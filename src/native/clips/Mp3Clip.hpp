// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_CLIPS_MP3CLIP_HPP
#define FLUXION_AUDIO_CLIPS_MP3CLIP_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include "../mixer/Data.hpp"

namespace fluxion_audio
{
    // Throws `Error` if `bytes` has no MPEG audio frame in it.
    std::unique_ptr<Data> makeMp3Data(const std::uint8_t* bytes, std::size_t length);
}

#endif // FLUXION_AUDIO_CLIPS_MP3CLIP_HPP
