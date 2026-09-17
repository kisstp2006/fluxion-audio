// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_BACKENDS_OPENSL_HPP
#define FLUXION_AUDIO_BACKENDS_OPENSL_HPP

#include <cstdint>

struct fx_audio_mixer;

namespace fluxion_audio::opensl
{
    struct Output;

    // Opens an OpenSL ES output mix and starts it playing from `mixer`,
    // re-enqueuing a fresh buffer every time the last one finishes. Null on
    // failure. `channels` and `sample_rate` are asked for and answered with
    // what was actually opened.
    Output *open(fx_audio_mixer *mixer, std::uint32_t *channels, std::uint32_t *sample_rate);
    void close(Output *output);
}

#endif // FLUXION_AUDIO_BACKENDS_OPENSL_HPP
