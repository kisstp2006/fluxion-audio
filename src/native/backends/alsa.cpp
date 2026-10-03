// SPDX-License-Identifier: CC0-1.0

#include "alsa.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <dlfcn.h>
#include <memory>
#include <thread>
#include <vector>

// ALSA is opened when the first output is, not linked: a program built for
// Linux runs on a machine without it - silent - and builds on one without its
// headers. What is declared here is the part of `alsa/asoundlib.h` this file
// uses, with the numbers the headers give.
namespace
{
    struct snd_pcm_t;
    struct snd_pcm_hw_params_t;
    struct snd_pcm_sw_params_t;
    using snd_pcm_uframes_t = unsigned long;
    using snd_pcm_sframes_t = long;

    constexpr int stream_playback = 0;       // SND_PCM_STREAM_PLAYBACK
    constexpr int open_nonblock = 0x1;       // SND_PCM_NONBLOCK
    constexpr int access_rw_interleaved = 3; // SND_PCM_ACCESS_RW_INTERLEAVED
    constexpr int format_s16_le = 2;         // SND_PCM_FORMAT_S16_LE
    constexpr int format_float_le = 14;      // SND_PCM_FORMAT_FLOAT_LE

    struct Alsa
    {
        int (*pcm_open)(snd_pcm_t **, const char *, int, int);
        int (*pcm_close)(snd_pcm_t *);
        int (*pcm_prepare)(snd_pcm_t *);
        int (*pcm_recover)(snd_pcm_t *, int, int);
        int (*pcm_wait)(snd_pcm_t *, int);
        snd_pcm_sframes_t (*pcm_avail_update)(snd_pcm_t *);
        snd_pcm_sframes_t (*pcm_writei)(snd_pcm_t *, const void *, snd_pcm_uframes_t);
        int (*hw_params_malloc)(snd_pcm_hw_params_t **);
        void (*hw_params_free)(snd_pcm_hw_params_t *);
        int (*hw_params_any)(snd_pcm_t *, snd_pcm_hw_params_t *);
        int (*hw_params_set_access)(snd_pcm_t *, snd_pcm_hw_params_t *, int);
        int (*hw_params_test_format)(snd_pcm_t *, snd_pcm_hw_params_t *, int);
        int (*hw_params_set_format)(snd_pcm_t *, snd_pcm_hw_params_t *, int);
        int (*hw_params_set_rate)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int, int);
        int (*hw_params_set_channels)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int);
        int (*hw_params_set_buffer_time_near)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int *, int *);
        int (*hw_params_set_period_time_near)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int *, int *);
        int (*hw_params_get_period_size)(const snd_pcm_hw_params_t *, snd_pcm_uframes_t *, int *);
        int (*hw_params_get_periods)(const snd_pcm_hw_params_t *, unsigned int *, int *);
        int (*hw_params_get_buffer_size)(const snd_pcm_hw_params_t *, snd_pcm_uframes_t *);
        int (*hw_params)(snd_pcm_t *, snd_pcm_hw_params_t *);
        int (*sw_params_malloc)(snd_pcm_sw_params_t **);
        void (*sw_params_free)(snd_pcm_sw_params_t *);
        int (*sw_params_current)(snd_pcm_t *, snd_pcm_sw_params_t *);
        int (*sw_params_set_avail_min)(snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t);
        int (*sw_params_set_start_threshold)(snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t);
        int (*sw_params)(snd_pcm_t *, snd_pcm_sw_params_t *);
    };

    template <typename F>
    bool find(void *library, const char *name, F &into)
    {
        into = reinterpret_cast<F>(dlsym(library, name));
        return into != nullptr;
    }

    // The library, opened once and kept: an output closed and opened again
    // finds it where it was. Null when this machine has no ALSA.
    const Alsa *library()
    {
        static const Alsa *const loaded = []() -> const Alsa * {
            void *library = dlopen("libasound.so.2", RTLD_NOW | RTLD_LOCAL);
            if (!library) return nullptr;
            static Alsa a;
            const bool all =
                find(library, "snd_pcm_open", a.pcm_open) &&
                find(library, "snd_pcm_close", a.pcm_close) &&
                find(library, "snd_pcm_prepare", a.pcm_prepare) &&
                find(library, "snd_pcm_recover", a.pcm_recover) &&
                find(library, "snd_pcm_wait", a.pcm_wait) &&
                find(library, "snd_pcm_avail_update", a.pcm_avail_update) &&
                find(library, "snd_pcm_writei", a.pcm_writei) &&
                find(library, "snd_pcm_hw_params_malloc", a.hw_params_malloc) &&
                find(library, "snd_pcm_hw_params_free", a.hw_params_free) &&
                find(library, "snd_pcm_hw_params_any", a.hw_params_any) &&
                find(library, "snd_pcm_hw_params_set_access", a.hw_params_set_access) &&
                find(library, "snd_pcm_hw_params_test_format", a.hw_params_test_format) &&
                find(library, "snd_pcm_hw_params_set_format", a.hw_params_set_format) &&
                find(library, "snd_pcm_hw_params_set_rate", a.hw_params_set_rate) &&
                find(library, "snd_pcm_hw_params_set_channels", a.hw_params_set_channels) &&
                find(library, "snd_pcm_hw_params_set_buffer_time_near", a.hw_params_set_buffer_time_near) &&
                find(library, "snd_pcm_hw_params_set_period_time_near", a.hw_params_set_period_time_near) &&
                find(library, "snd_pcm_hw_params_get_period_size", a.hw_params_get_period_size) &&
                find(library, "snd_pcm_hw_params_get_periods", a.hw_params_get_periods) &&
                find(library, "snd_pcm_hw_params_get_buffer_size", a.hw_params_get_buffer_size) &&
                find(library, "snd_pcm_hw_params", a.hw_params) &&
                find(library, "snd_pcm_sw_params_malloc", a.sw_params_malloc) &&
                find(library, "snd_pcm_sw_params_free", a.sw_params_free) &&
                find(library, "snd_pcm_sw_params_current", a.sw_params_current) &&
                find(library, "snd_pcm_sw_params_set_avail_min", a.sw_params_set_avail_min) &&
                find(library, "snd_pcm_sw_params_set_start_threshold", a.sw_params_set_start_threshold) &&
                find(library, "snd_pcm_sw_params", a.sw_params);
            if (!all)
            {
                dlclose(library);
                return nullptr;
            }
            return &a;
        }();
        return loaded;
    }
}

namespace fluxion_audio::alsa
{
    struct Output
    {
        const Alsa *api;
        fx_audio_pull pull;
        void *mixer;
        snd_pcm_t *playback_handle = nullptr;
        unsigned int channels = 2;
        unsigned int sample_rate = 44100;
        bool is_float = true;
        unsigned int periods = 4;
        snd_pcm_uframes_t period_size = 1024;
        snd_pcm_uframes_t buffer_size = 4096;

        std::vector<float> planar;
        std::vector<std::uint8_t> interleaved;

        std::atomic_bool running{false};
        std::thread audio_thread;

        ~Output()
        {
            if (playback_handle) api->pcm_close(playback_handle);
        }

        void run();
        bool write(std::uint32_t frame_count);
    };

    namespace
    {
        struct HwParams
        {
            const Alsa *api;
            snd_pcm_hw_params_t *params = nullptr;
            ~HwParams()
            {
                if (params) api->hw_params_free(params);
            }
        };

        struct SwParams
        {
            const Alsa *api;
            snd_pcm_sw_params_t *params = nullptr;
            ~SwParams()
            {
                if (params) api->sw_params_free(params);
            }
        };

        // True if the negotiated buffer is IEEE float; false for signed
        // 16-bit - the two formats ALSA is asked to try, in that order.
        bool negotiateFormat(const Alsa *api, snd_pcm_t *handle, snd_pcm_hw_params_t *hw_params)
        {
            if (api->hw_params_test_format(handle, hw_params, format_float_le) == 0)
            {
                api->hw_params_set_format(handle, hw_params, format_float_le);
                return true;
            }
            if (api->hw_params_test_format(handle, hw_params, format_s16_le) == 0)
            {
                api->hw_params_set_format(handle, hw_params, format_s16_le);
                return false;
            }
            return false;
        }
    }

    Output *open(fx_audio_pull pull, void *mixer, std::uint32_t *channels, std::uint32_t *sample_rate)
    {
        const Alsa *api = library();
        if (!api) return nullptr;

        auto output = std::make_unique<Output>();
        output->api = api;
        output->pull = pull;
        output->mixer = mixer;
        output->channels = *channels != 0 ? *channels : 2;
        output->sample_rate = *sample_rate != 0 ? *sample_rate : 44100;

        if (api->pcm_open(&output->playback_handle, "default", stream_playback, open_nonblock) < 0)
        {
            output->playback_handle = nullptr;
            return nullptr;
        }

        HwParams hw{api};
        if (api->hw_params_malloc(&hw.params) != 0) return nullptr;
        if (api->hw_params_any(output->playback_handle, hw.params) < 0)
            return nullptr;
        if (api->hw_params_set_access(output->playback_handle, hw.params, access_rw_interleaved) != 0)
            return nullptr;

        output->is_float = negotiateFormat(api, output->playback_handle, hw.params);

        if (api->hw_params_set_rate(output->playback_handle, hw.params, output->sample_rate, 0) != 0)
            return nullptr;
        if (api->hw_params_set_channels(output->playback_handle, hw.params, output->channels) != 0)
            return nullptr;

        unsigned int period_length = static_cast<unsigned int>(output->period_size) * 1000000U / output->sample_rate;
        unsigned int buffer_length = period_length * output->periods;
        int dir;
        api->hw_params_set_buffer_time_near(output->playback_handle, hw.params, &buffer_length, &dir);
        api->hw_params_set_period_time_near(output->playback_handle, hw.params, &period_length, &dir);
        api->hw_params_get_period_size(hw.params, &output->period_size, &dir);
        api->hw_params_get_periods(hw.params, &output->periods, &dir);

        if (api->hw_params(output->playback_handle, hw.params) != 0)
            return nullptr;
        if (api->hw_params_get_buffer_size(hw.params, &output->buffer_size) != 0)
            output->buffer_size = output->periods * output->period_size;

        SwParams sw{api};
        if (api->sw_params_malloc(&sw.params) != 0) return nullptr;
        if (api->sw_params_current(output->playback_handle, sw.params) != 0)
            return nullptr;
        // Woken as soon as a period has room: 4096 frames was the whole
        // buffer, so a device that made the thread wait let it run dry.
        api->sw_params_set_avail_min(output->playback_handle, sw.params, output->period_size);
        api->sw_params_set_start_threshold(output->playback_handle, sw.params, 0);
        if (api->sw_params(output->playback_handle, sw.params) != 0)
            return nullptr;

        if (api->pcm_prepare(output->playback_handle) != 0)
            return nullptr;

        *channels = output->channels;
        *sample_rate = output->sample_rate;

        output->running = true;
        output->audio_thread = std::thread(&Output::run, output.get());
        return output.release();
    }

    void close(Output *output)
    {
        if (!output) return;
        output->running = false;
        if (output->audio_thread.joinable()) output->audio_thread.join();
        delete output;
    }

    // Mixed sound goes no further ahead of what has been heard than the
    // device's buffer. A device that keeps time - a sound card, a sound
    // server - makes this thread wait when it is full, and that wait is the
    // clock. One that never fills - the null device takes any amount at once
    // - would let the mixer race through its clips, every voice ending in an
    // instant; the steady clock keeps it to time instead.
    void Output::run()
    {
        using clock = std::chrono::steady_clock;
        const int wait_ms = std::max(1, static_cast<int>(period_size * 2000 / sample_rate));
        // Frames written since `since`, when the device last kept time.
        auto since = clock::now();
        std::uint64_t written = 0;

        while (running)
        {
            const snd_pcm_sframes_t avail = api->pcm_avail_update(playback_handle);
            if (avail < 0)
            {
                if (api->pcm_recover(playback_handle, static_cast<int>(avail), 1) < 0) break;
                continue;
            }
            if (static_cast<snd_pcm_uframes_t>(avail) < period_size)
            {
                // Full: what is queued is all that is ahead of the ear.
                since = clock::now();
                written = buffer_size - std::min(buffer_size, static_cast<snd_pcm_uframes_t>(avail));
                api->pcm_wait(playback_handle, wait_ms);
                continue;
            }

            const double heard = std::chrono::duration<double>(clock::now() - since).count() * sample_rate;
            const double room = heard + static_cast<double>(buffer_size) - static_cast<double>(written);
            if (room < static_cast<double>(period_size))
            {
                const double short_by = static_cast<double>(period_size) - room;
                std::this_thread::sleep_for(std::chrono::duration<double>(short_by / sample_rate));
                continue;
            }

            const auto frame_count = static_cast<std::uint32_t>(std::min(static_cast<double>(avail), room));
            planar.resize(static_cast<std::size_t>(frame_count) * channels);
            pull(mixer, frame_count, channels, sample_rate, planar.data());

            if (is_float)
            {
                interleaved.resize(static_cast<std::size_t>(frame_count) * channels * sizeof(float));
                auto *out = reinterpret_cast<float *>(interleaved.data());
                for (std::uint32_t frame = 0; frame < frame_count; ++frame)
                    for (unsigned int ch = 0; ch < channels; ++ch)
                        out[frame * channels + ch] = planar[static_cast<std::size_t>(ch) * frame_count + frame];
            }
            else
            {
                interleaved.resize(static_cast<std::size_t>(frame_count) * channels * sizeof(std::int16_t));
                auto *out = reinterpret_cast<std::int16_t *>(interleaved.data());
                for (std::uint32_t frame = 0; frame < frame_count; ++frame)
                    for (unsigned int ch = 0; ch < channels; ++ch)
                    {
                        float sample = planar[static_cast<std::size_t>(ch) * frame_count + frame];
                        sample = sample < -1.0F ? -1.0F : (sample > 1.0F ? 1.0F : sample);
                        out[frame * channels + ch] = static_cast<std::int16_t>(sample * 32767.0F);
                    }
            }

            if (!write(frame_count)) break;
            written += frame_count;
        }
    }

    // All of `frame_count` frames, waiting for room as the device plays:
    // what the mixer gave is never dropped, or its voices would run ahead of
    // what is heard. False when the device cannot go on.
    bool Output::write(std::uint32_t frame_count)
    {
        const std::size_t frame_bytes = static_cast<std::size_t>(channels) * (is_float ? sizeof(float) : sizeof(std::int16_t));
        const int wait_ms = std::max(1, static_cast<int>(period_size * 2000 / sample_rate));
        std::uint32_t done = 0;
        while (done < frame_count && running)
        {
            const snd_pcm_sframes_t result = api->pcm_writei(playback_handle, interleaved.data() + done * frame_bytes, frame_count - done);
            if (result >= 0)
                done += static_cast<std::uint32_t>(result);
            else if (result == -EAGAIN)
                api->pcm_wait(playback_handle, wait_ms);
            else if (api->pcm_recover(playback_handle, static_cast<int>(result), 1) < 0)
                return false;
        }
        return true;
    }
}

extern "C" fx_audio_output *fx_audio_alsa_open(fx_audio_pull pull, void *mixer, uint32_t *channels, uint32_t *sample_rate)
{
    return reinterpret_cast<fx_audio_output *>(fluxion_audio::alsa::open(pull, mixer, channels, sample_rate));
}

extern "C" void fx_audio_alsa_close(fx_audio_output *output)
{
    fluxion_audio::alsa::close(reinterpret_cast<fluxion_audio::alsa::Output *>(output));
}
