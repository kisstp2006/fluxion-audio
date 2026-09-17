// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_OBJECT_HPP
#define FLUXION_AUDIO_MIXER_OBJECT_HPP

namespace fluxion_audio
{
    // The common base `Mixer::objects` is stored as, so a `Bus`, a `Data`, a
    // `Stream` and a `Processor` can share one table and one id space.
    class Object
    {
    public:
        virtual ~Object() = default;
    };
}

#endif // FLUXION_AUDIO_MIXER_OBJECT_HPP
