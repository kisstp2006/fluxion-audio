// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_HANDLE_HPP
#define FLUXION_AUDIO_MIXER_HANDLE_HPP

#include "mixer/Mixer.hpp"

// What `fx_audio_mixer*` in `bridge.h` actually points at - shared by
// `bridge.cpp` and by the output backends, which pull samples straight out
// of the `Mixer` rather than through the C boundary.
struct fx_audio_mixer
{
    fluxion_audio::Mixer mixer;
};

#endif // FLUXION_AUDIO_MIXER_HANDLE_HPP
