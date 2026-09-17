// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_CLIPS_VORBISCLIP_HPP
#define FLUXION_AUDIO_CLIPS_VORBISCLIP_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include "../mixer/Data.hpp"

namespace fluxion_audio
{
    // Throws `Error` if `bytes` does not decode as Ogg Vorbis.
    std::unique_ptr<Data> makeVorbisData(const std::uint8_t* bytes, std::size_t length);
}

#endif // FLUXION_AUDIO_CLIPS_VORBISCLIP_HPP
