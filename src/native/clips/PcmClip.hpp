// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_CLIPS_PCMCLIP_HPP
#define FLUXION_AUDIO_CLIPS_PCMCLIP_HPP

#include <cstdint>
#include <memory>
#include <vector>
#include "../mixer/Data.hpp"

namespace fluxion_audio
{
    // `planar` is one channel's samples in full, then the next - the shape
    // the mixer already works in internally, so nothing here has to guess at
    // an interleaving or a sample format the caller might have used.
    std::unique_ptr<Data> makePcmData(std::uint32_t channels, std::uint32_t sampleRate,
                                      std::vector<float> planar);
}

#endif // FLUXION_AUDIO_CLIPS_PCMCLIP_HPP
