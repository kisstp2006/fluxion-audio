/* SPDX-License-Identifier: CC0-1.0 */

#ifndef FLUXION_AUDIO_BRIDGE_H
#define FLUXION_AUDIO_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fx_audio_mixer fx_audio_mixer;

/* What a clip is, as its bytes said: `frames` is how long it is, 0 for one
   with no end. */
typedef struct fx_audio_clip_info
{
    uint32_t channels;
    uint32_t sample_rate;
    uint64_t frames;
} fx_audio_clip_info;

fx_audio_mixer *fx_audio_mixer_create(void);
void fx_audio_mixer_destroy(fx_audio_mixer *mixer);

/* Applies every queued change, then mixes `frames` frames of `channels`
   channels at `sample_rate` into `out`, planar by channel: `out[0 ..
   frames]` is channel 0, and so on. `out` must hold `frames * channels`
   floats. */
void fx_audio_mixer_get_samples(fx_audio_mixer *mixer, uint32_t frames,
                                 uint32_t channels, uint32_t sample_rate,
                                 float *out);

/* Object ids, shared across buses, clips, streams and processors. 0 never
   names a live object. */
size_t fx_audio_mixer_next_id(fx_audio_mixer *mixer);
void fx_audio_mixer_delete_object(fx_audio_mixer *mixer, size_t object_id);

void fx_audio_mixer_init_bus(fx_audio_mixer *mixer, size_t bus_id);
void fx_audio_mixer_set_bus_output(fx_audio_mixer *mixer, size_t bus_id,
                                    size_t output_bus_id);
void fx_audio_mixer_set_master_bus(fx_audio_mixer *mixer, size_t bus_id);
void fx_audio_mixer_add_processor(fx_audio_mixer *mixer, size_t bus_id,
                                   size_t processor_id);
void fx_audio_mixer_remove_processor(fx_audio_mixer *mixer, size_t bus_id,
                                      size_t processor_id);

/* `planar` is `frame_count * channels` floats, one channel's samples in
   full and then the next - the shape the mixer works in internally. */
void fx_audio_mixer_init_data_pcm_f32(fx_audio_mixer *mixer, size_t data_id,
                                       uint32_t channels, uint32_t sample_rate,
                                       const float *planar,
                                       size_t frame_count);
/* Each returns 0 on success, non-zero if `bytes` did not decode, and says
   what the clip is in `info`. The bytes are copied, and decoded as the clip
   plays. */
int fx_audio_mixer_init_data_vorbis(fx_audio_mixer *mixer, size_t data_id,
                                     const uint8_t *bytes, size_t length,
                                     fx_audio_clip_info *info);
int fx_audio_mixer_init_data_mp3(fx_audio_mixer *mixer, size_t data_id,
                                  const uint8_t *bytes, size_t length,
                                  fx_audio_clip_info *info);

typedef enum fx_audio_oscillator_type
{
    FX_AUDIO_OSCILLATOR_SINE,
    FX_AUDIO_OSCILLATOR_SQUARE,
    FX_AUDIO_OSCILLATOR_SAWTOOTH,
    FX_AUDIO_OSCILLATOR_TRIANGLE
} fx_audio_oscillator_type;

/* A clip with no bytes behind it, generated one waveform at a time as it
   plays. `length_seconds` is how much of it there is before the stream
   reports itself finished; 0 means it never finishes on its own. */
void fx_audio_mixer_init_data_oscillator(fx_audio_mixer *mixer, size_t data_id,
                                          fx_audio_oscillator_type type,
                                          float frequency, float amplitude,
                                          float length_seconds,
                                          uint32_t sample_rate);

/* What a stream says of itself as it plays, safe to read from any thread
   while another mixes: see `fx_audio_voice_state_*`. */
typedef struct fx_audio_voice_state fx_audio_voice_state;

/* Returns the stream's state, for the caller to read and to let go of with
   `fx_audio_voice_state_release` once done with the stream. */
fx_audio_voice_state *fx_audio_mixer_init_stream(fx_audio_mixer *mixer,
                                                  size_t stream_id,
                                                  size_t data_id);
void fx_audio_mixer_play_stream(fx_audio_mixer *mixer, size_t stream_id);
void fx_audio_mixer_stop_stream(fx_audio_mixer *mixer, size_t stream_id,
                                 int reset);
void fx_audio_mixer_set_stream_output(fx_audio_mixer *mixer, size_t stream_id,
                                       size_t bus_id);
/* From `frame` of its clip on. */
void fx_audio_mixer_seek_stream(fx_audio_mixer *mixer, size_t stream_id,
                                 uint64_t frame);
/* From the start again at the end, rather than stopping. */
void fx_audio_mixer_set_stream_looping(fx_audio_mixer *mixer, size_t stream_id,
                                        int looping);
/* 1 plays the clip as recorded; 2 twice as fast and an octave up - the clip
   resampled, which costs next to nothing. */
void fx_audio_mixer_set_stream_speed(fx_audio_mixer *mixer, size_t stream_id,
                                      float speed);

int fx_audio_voice_state_playing(const fx_audio_voice_state *state);
/* Frames into its clip. */
uint64_t fx_audio_voice_state_frame(const fx_audio_voice_state *state);
/* How many times it has come to its end and stopped. */
uint32_t fx_audio_voice_state_ends(const fx_audio_voice_state *state);
/* What the caller has just asked for, said before the mixing thread gets to
   it, so a read right after a play or a seek is not the old state. */
void fx_audio_voice_state_expect(fx_audio_voice_state *state, int playing,
                                  uint64_t frame);
void fx_audio_voice_state_release(fx_audio_voice_state *state);

void fx_audio_mixer_init_gain(fx_audio_mixer *mixer, size_t processor_id,
                               float gain);
void fx_audio_mixer_set_gain(fx_audio_mixer *mixer, size_t processor_id,
                              float gain);
void fx_audio_mixer_init_pan(fx_audio_mixer *mixer, size_t processor_id,
                              float pan);
void fx_audio_mixer_set_pan(fx_audio_mixer *mixer, size_t processor_id,
                             float pan);

/* 1.0 is unchanged, 0.5 is an octave down, 2.0 is an octave up. */
void fx_audio_mixer_init_pitch_shift(fx_audio_mixer *mixer, size_t processor_id,
                                      float pitch);
void fx_audio_mixer_set_pitch_shift(fx_audio_mixer *mixer, size_t processor_id,
                                     float pitch);

/* One of these per platform, compiled in only when the target has it. Each
   opens the real output device and starts a thread that pulls from `mixer`
   - after this, `mixer` is read from that thread, so nothing else may call
   `fx_audio_mixer_get_samples` or `fx_audio_mixer_is_stream_playing` on it.
   Null on failure; `channels`/`sample_rate` are asked for and answered with
   what was actually opened. */
typedef struct fx_audio_output fx_audio_output;

#if defined(__linux__) && !defined(__ANDROID__)
fx_audio_output *fx_audio_alsa_open(fx_audio_mixer *mixer, uint32_t *channels, uint32_t *sample_rate);
void fx_audio_alsa_close(fx_audio_output *output);
#endif

#if defined(__ANDROID__)
fx_audio_output *fx_audio_opensl_open(fx_audio_mixer *mixer, uint32_t *channels, uint32_t *sample_rate);
void fx_audio_opensl_close(fx_audio_output *output);
#endif

#ifdef __cplusplus
}
#endif

#endif /* FLUXION_AUDIO_BRIDGE_H */
