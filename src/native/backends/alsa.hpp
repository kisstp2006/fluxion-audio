// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_BACKENDS_ALSA_HPP
#define FLUXION_AUDIO_BACKENDS_ALSA_HPP

#include "../output.h"

#include <cstdint>

namespace fluxion_audio::alsa
{
    struct Output;

    // Opens ALSA's default playback device and starts a thread that pulls
    // from `mixer` and writes to it. Null on failure. `channels` and
    // `sample_rate` are asked for and answered with what was actually
    // opened.
    Output *open(fx_audio_pull pull, void *mixer, std::uint32_t *channels, std::uint32_t *sample_rate);
    void close(Output *output);
}

#endif // FLUXION_AUDIO_BACKENDS_ALSA_HPP
