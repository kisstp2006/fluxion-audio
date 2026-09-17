// SPDX-License-Identifier: CC0-1.0

#include "alsa.hpp"
#include "../mixer_handle.hpp"

#include <alsa/asoundlib.h>
#include <atomic>
#include <cerrno>
#include <thread>
#include <vector>

namespace fluxion_audio::alsa
{
    struct Output
    {
        fx_audio_mixer *mixer;
        snd_pcm_t *playback_handle = nullptr;
        unsigned int channels = 2;
        unsigned int sample_rate = 44100;
        bool is_float = true;
        unsigned int periods = 4;
        snd_pcm_uframes_t period_size = 1024;

        std::vector<float> planar;
        std::vector<std::uint8_t> interleaved;

        std::atomic_bool running{false};
        std::thread audio_thread;

        void run();
    };

    namespace
    {
        // True if the negotiated buffer is IEEE float; false for signed
        // 16-bit - the two formats ALSA is asked to try, in that order.
        bool negotiateFormat(snd_pcm_t *handle, snd_pcm_hw_params_t *hw_params)
        {
            if (snd_pcm_hw_params_test_format(handle, hw_params, SND_PCM_FORMAT_FLOAT_LE) == 0)
            {
                snd_pcm_hw_params_set_format(handle, hw_params, SND_PCM_FORMAT_FLOAT_LE);
                return true;
            }
            if (snd_pcm_hw_params_test_format(handle, hw_params, SND_PCM_FORMAT_S16_LE) == 0)
            {
                snd_pcm_hw_params_set_format(handle, hw_params, SND_PCM_FORMAT_S16_LE);
                return false;
            }
            return false;
        }
    }

    Output *open(fx_audio_mixer *mixer, std::uint32_t *channels, std::uint32_t *sample_rate)
    {
        auto output = std::make_unique<Output>();
        output->mixer = mixer;
        output->channels = *channels != 0 ? *channels : 2;
        output->sample_rate = *sample_rate != 0 ? *sample_rate : 44100;

        if (snd_pcm_open(&output->playback_handle, "default", SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0)
            return nullptr;

        snd_pcm_hw_params_t *hw_params = nullptr;
        snd_pcm_hw_params_alloca(&hw_params);

        if (snd_pcm_hw_params_any(output->playback_handle, hw_params) < 0)
            return nullptr;
        if (snd_pcm_hw_params_set_access(output->playback_handle, hw_params, SND_PCM_ACCESS_RW_INTERLEAVED) != 0)
            return nullptr;

        output->is_float = negotiateFormat(output->playback_handle, hw_params);

        if (snd_pcm_hw_params_set_rate(output->playback_handle, hw_params, output->sample_rate, 0) != 0)
            return nullptr;
        if (snd_pcm_hw_params_set_channels(output->playback_handle, hw_params, output->channels) != 0)
            return nullptr;

        unsigned int period_length = static_cast<unsigned int>(output->period_size) * 1000000U / output->sample_rate;
        unsigned int buffer_length = period_length * output->periods;
        int dir;
        snd_pcm_hw_params_set_buffer_time_near(output->playback_handle, hw_params, &buffer_length, &dir);
        snd_pcm_hw_params_set_period_time_near(output->playback_handle, hw_params, &period_length, &dir);
        snd_pcm_hw_params_get_period_size(hw_params, &output->period_size, &dir);
        snd_pcm_hw_params_get_periods(hw_params, &output->periods, &dir);

        if (snd_pcm_hw_params(output->playback_handle, hw_params) != 0)
            return nullptr;

        snd_pcm_sw_params_t *sw_params = nullptr;
        snd_pcm_sw_params_alloca(&sw_params);
        if (snd_pcm_sw_params_current(output->playback_handle, sw_params) != 0)
            return nullptr;
        snd_pcm_sw_params_set_avail_min(output->playback_handle, sw_params, 4096);
        snd_pcm_sw_params_set_start_threshold(output->playback_handle, sw_params, 0);
        if (snd_pcm_sw_params(output->playback_handle, sw_params) != 0)
            return nullptr;

        if (snd_pcm_prepare(output->playback_handle) != 0)
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
        if (output->playback_handle) snd_pcm_close(output->playback_handle);
        delete output;
    }

    void Output::run()
    {
        while (running)
        {
            snd_pcm_sframes_t frames = snd_pcm_avail_update(playback_handle);
            if (frames < 0)
            {
                if (frames == -EPIPE)
                {
                    snd_pcm_prepare(playback_handle);
                    continue;
                }
                break;
            }
            if (static_cast<snd_pcm_uframes_t>(frames) > periods * period_size)
            {
                snd_pcm_reset(playback_handle);
                continue;
            }
            if (static_cast<snd_pcm_uframes_t>(frames) < period_size)
                continue;

            const auto frame_count = static_cast<std::uint32_t>(frames);
            planar.resize(static_cast<std::size_t>(frame_count) * channels);
            mixer->mixer.getSamples(frame_count, channels, sample_rate, planar);

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

            const auto result = snd_pcm_writei(playback_handle, interleaved.data(), frames);
            if (result == -EPIPE)
                snd_pcm_prepare(playback_handle);
        }
    }
}
