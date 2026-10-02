/* SPDX-License-Identifier: CC0-1.0 */

/* The sound devices written in C++ - ALSA on Linux, OpenSL ES on Android -
   and what they call for more sound. The mixer is Zig's (`backend/mixer.zig`);
   a device only knows it as `mixer` and the function that fills a buffer
   from it. */

#ifndef FLUXION_AUDIO_OUTPUT_H
#define FLUXION_AUDIO_OUTPUT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* `frames` frames of `channels` at `sample_rate` into `out`, planar by
   channel, from `mixer`. Called on the device's own thread. */
typedef void (*fx_audio_pull)(void *mixer, uint32_t frames, uint32_t channels,
                              uint32_t sample_rate, float *out);

/* Opens the real output device and starts it pulling from `mixer` - after
   this, `mixer` is read from the device's thread, until the close. Null on
   failure; `channels`/`sample_rate` are asked for and answered with what was
   actually opened. */
typedef struct fx_audio_output fx_audio_output;

#if defined(__linux__) && !defined(__ANDROID__)
fx_audio_output *fx_audio_alsa_open(fx_audio_pull pull, void *mixer, uint32_t *channels, uint32_t *sample_rate);
void fx_audio_alsa_close(fx_audio_output *output);
#endif

#if defined(__ANDROID__)
fx_audio_output *fx_audio_opensl_open(fx_audio_pull pull, void *mixer, uint32_t *channels, uint32_t *sample_rate);
void fx_audio_opensl_close(fx_audio_output *output);
#endif

#ifdef __cplusplus
}
#endif

#endif /* FLUXION_AUDIO_OUTPUT_H */
