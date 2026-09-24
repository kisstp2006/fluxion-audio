// SPDX-License-Identifier: CC0-1.0

#include "bridge.h"

#include <algorithm>
#include <memory>
#include <vector>
#include "mixer_handle.hpp"
#include "mixer/Commands.hpp"
#include "mixer/MixerError.hpp"
#include "clips/PcmClip.hpp"
#include "clips/VorbisClip.hpp"
#include "clips/OscillatorClip.hpp"
#include "clips/Mp3Clip.hpp"
#include "effects/VoiceEffects.hpp"

using namespace fluxion_audio;

namespace
{
    void submit(fx_audio_mixer *m, std::unique_ptr<Command> command)
    {
        CommandBuffer buffer;
        buffer.pushCommand(std::move(command));
        m->mixer.submitCommandBuffer(std::move(buffer));
    }

    // Decoded with `make`, told of in `info`, and handed to the mixer.
    template <typename Make>
    int initEncoded(fx_audio_mixer *m, size_t data_id, fx_audio_clip_info *info, Make make)
    {
        try
        {
            auto data = make();
            if (info)
            {
                info->channels = data->getChannels();
                info->sample_rate = data->getSampleRate();
                info->frames = data->getFrames();
            }
            submit(m, std::make_unique<InitDataCommand>(data_id, std::move(data)));
            return 0;
        }
        catch (const std::exception &)
        {
            return 1;
        }
    }
}

fx_audio_mixer *fx_audio_mixer_create(void)
{
    return new fx_audio_mixer;
}

void fx_audio_mixer_destroy(fx_audio_mixer *m)
{
    delete m;
}

void fx_audio_mixer_get_samples(fx_audio_mixer *m, uint32_t frames, uint32_t channels,
                                 uint32_t sample_rate, float *out)
{
    std::vector<float> samples;
    m->mixer.getSamples(frames, channels, sample_rate, samples);
    std::copy(samples.begin(), samples.end(), out);
}

size_t fx_audio_mixer_next_id(fx_audio_mixer *m)
{
    return m->mixer.getObjectId();
}

void fx_audio_mixer_delete_object(fx_audio_mixer *m, size_t object_id)
{
    submit(m, std::make_unique<DeleteObjectCommand>(object_id));
    m->mixer.deleteObjectId(object_id);
}

void fx_audio_mixer_init_bus(fx_audio_mixer *m, size_t bus_id)
{
    submit(m, std::make_unique<InitBusCommand>(bus_id));
}

void fx_audio_mixer_set_bus_output(fx_audio_mixer *m, size_t bus_id, size_t output_bus_id)
{
    submit(m, std::make_unique<SetBusOutputCommand>(bus_id, output_bus_id));
}

void fx_audio_mixer_set_master_bus(fx_audio_mixer *m, size_t bus_id)
{
    submit(m, std::make_unique<SetMasterBusCommand>(bus_id));
}

void fx_audio_mixer_add_processor(fx_audio_mixer *m, size_t bus_id, size_t processor_id)
{
    submit(m, std::make_unique<AddProcessorCommand>(bus_id, processor_id));
}

void fx_audio_mixer_remove_processor(fx_audio_mixer *m, size_t bus_id, size_t processor_id)
{
    submit(m, std::make_unique<RemoveProcessorCommand>(bus_id, processor_id));
}

void fx_audio_mixer_init_data_pcm_f32(fx_audio_mixer *m, size_t data_id, uint32_t channels,
                                       uint32_t sample_rate, const float *planar,
                                       size_t frame_count)
{
    std::vector<float> samples(planar, planar + frame_count * channels);
    auto data = makePcmData(channels, sample_rate, std::move(samples));
    submit(m, std::make_unique<InitDataCommand>(data_id, std::move(data)));
}

int fx_audio_mixer_init_data_vorbis(fx_audio_mixer *m, size_t data_id, const uint8_t *bytes,
                                     size_t length, fx_audio_clip_info *info)
{
    return initEncoded(m, data_id, info, [&] { return makeVorbisData(bytes, length); });
}

int fx_audio_mixer_init_data_mp3(fx_audio_mixer *m, size_t data_id, const uint8_t *bytes,
                                  size_t length, fx_audio_clip_info *info)
{
    return initEncoded(m, data_id, info, [&] { return makeMp3Data(bytes, length); });
}

void fx_audio_mixer_init_data_oscillator(fx_audio_mixer *m, size_t data_id, fx_audio_oscillator_type type,
                                          float frequency, float amplitude, float length_seconds,
                                          uint32_t sample_rate)
{
    OscillatorType oscillatorType;
    switch (type)
    {
        case FX_AUDIO_OSCILLATOR_SQUARE: oscillatorType = OscillatorType::square; break;
        case FX_AUDIO_OSCILLATOR_SAWTOOTH: oscillatorType = OscillatorType::sawtooth; break;
        case FX_AUDIO_OSCILLATOR_TRIANGLE: oscillatorType = OscillatorType::triangle; break;
        default: oscillatorType = OscillatorType::sine; break;
    }

    auto data = makeOscillatorData(oscillatorType, frequency, amplitude, length_seconds, sample_rate);
    submit(m, std::make_unique<InitDataCommand>(data_id, std::move(data)));
}

fx_audio_voice_state *fx_audio_mixer_init_stream(fx_audio_mixer *m, size_t stream_id, size_t data_id)
{
    // Held twice from the start: by the caller, and by the command until the
    // stream it makes takes its hold.
    auto state = new fx_audio_voice_state;
    submit(m, std::make_unique<InitStreamCommand>(stream_id, data_id, state));
    return state;
}

void fx_audio_mixer_play_stream(fx_audio_mixer *m, size_t stream_id)
{
    submit(m, std::make_unique<PlayStreamCommand>(stream_id));
}

void fx_audio_mixer_stop_stream(fx_audio_mixer *m, size_t stream_id, int reset)
{
    submit(m, std::make_unique<StopStreamCommand>(stream_id, reset != 0));
}

void fx_audio_mixer_set_stream_output(fx_audio_mixer *m, size_t stream_id, size_t bus_id)
{
    submit(m, std::make_unique<SetStreamOutputCommand>(stream_id, bus_id));
}

void fx_audio_mixer_seek_stream(fx_audio_mixer *m, size_t stream_id, uint64_t frame)
{
    submit(m, std::make_unique<UpdateStreamCommand>(stream_id, [frame](Stream *s) { s->seek(frame); }));
}

void fx_audio_mixer_set_stream_looping(fx_audio_mixer *m, size_t stream_id, int looping)
{
    submit(m, std::make_unique<UpdateStreamCommand>(stream_id, [looping](Stream *s) { s->setLooping(looping != 0); }));
}

void fx_audio_mixer_set_stream_speed(fx_audio_mixer *m, size_t stream_id, float speed)
{
    submit(m, std::make_unique<UpdateStreamCommand>(stream_id, [speed](Stream *s) { s->setSpeed(speed); }));
}

int fx_audio_voice_state_playing(const fx_audio_voice_state *state)
{
    return state->playing.load(std::memory_order_acquire);
}

uint64_t fx_audio_voice_state_frame(const fx_audio_voice_state *state)
{
    return state->frame.load(std::memory_order_relaxed);
}

uint32_t fx_audio_voice_state_ends(const fx_audio_voice_state *state)
{
    return state->ends.load(std::memory_order_acquire);
}

void fx_audio_voice_state_expect(fx_audio_voice_state *state, int playing, uint64_t frame)
{
    state->frame.store(frame, std::memory_order_relaxed);
    state->playing.store(playing, std::memory_order_release);
}

void fx_audio_voice_state_release(fx_audio_voice_state *state)
{
    releaseVoiceState(state);
}

void fx_audio_mixer_init_gain(fx_audio_mixer *m, size_t processor_id, float gain)
{
    submit(m, std::make_unique<InitProcessorCommand>(processor_id, std::make_unique<GainProcessor>(gain)));
}

void fx_audio_mixer_set_gain(fx_audio_mixer *m, size_t processor_id, float gain)
{
    submit(m, std::make_unique<UpdateProcessorCommand>(processor_id, [gain](Processor *p) {
        static_cast<GainProcessor *>(p)->setGain(gain);
    }));
}

void fx_audio_mixer_init_pan(fx_audio_mixer *m, size_t processor_id, float pan)
{
    submit(m, std::make_unique<InitProcessorCommand>(processor_id, std::make_unique<PanProcessor>(pan)));
}

void fx_audio_mixer_set_pan(fx_audio_mixer *m, size_t processor_id, float pan)
{
    submit(m, std::make_unique<UpdateProcessorCommand>(processor_id, [pan](Processor *p) {
        static_cast<PanProcessor *>(p)->setPan(pan);
    }));
}

void fx_audio_mixer_init_pitch_shift(fx_audio_mixer *m, size_t processor_id, float pitch)
{
    submit(m, std::make_unique<InitProcessorCommand>(processor_id, std::make_unique<PitchShiftProcessor>(pitch)));
}

void fx_audio_mixer_set_pitch_shift(fx_audio_mixer *m, size_t processor_id, float pitch)
{
    submit(m, std::make_unique<UpdateProcessorCommand>(processor_id, [pitch](Processor *p) {
        static_cast<PitchShiftProcessor *>(p)->setPitch(pitch);
    }));
}

#if defined(__linux__) && !defined(__ANDROID__)
#include "backends/alsa.hpp"

fx_audio_output *fx_audio_alsa_open(fx_audio_mixer *mixer, uint32_t *channels, uint32_t *sample_rate)
{
    return reinterpret_cast<fx_audio_output *>(alsa::open(mixer, channels, sample_rate));
}

void fx_audio_alsa_close(fx_audio_output *output)
{
    alsa::close(reinterpret_cast<alsa::Output *>(output));
}
#endif

#if defined(__ANDROID__)
#include "backends/opensl.hpp"

fx_audio_output *fx_audio_opensl_open(fx_audio_mixer *mixer, uint32_t *channels, uint32_t *sample_rate)
{
    return reinterpret_cast<fx_audio_output *>(opensl::open(mixer, channels, sample_rate));
}

void fx_audio_opensl_close(fx_audio_output *output)
{
    opensl::close(reinterpret_cast<opensl::Output *>(output));
}
#endif
