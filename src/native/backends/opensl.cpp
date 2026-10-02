// SPDX-License-Identifier: CC0-1.0

#include "opensl.hpp"

#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>
#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace fluxion_audio::opensl
{
    namespace
    {
        // Destroys the object it holds when it goes out of scope, as every
        // `SLObjectItf` here must be.
        template <class T>
        class Pointer final
        {
        public:
            Pointer() noexcept = default;
            Pointer(T a) noexcept : p{a} {}
            Pointer(const Pointer &) = delete;
            Pointer &operator=(const Pointer &) = delete;

            Pointer &operator=(T a) noexcept
            {
                if (p) (*p)->Destroy(p);
                p = a;
                return *this;
            }

            ~Pointer()
            {
                if (p) (*p)->Destroy(p);
            }

            auto operator->() const noexcept { return *p; }
            auto get() const noexcept { return p; }
            explicit operator bool() const noexcept { return p != nullptr; }

        private:
            T p = nullptr;
        };

        constexpr SLuint32 channelMask(std::uint32_t channels)
        {
            switch (channels)
            {
                case 1: return SL_SPEAKER_FRONT_CENTER;
                case 2: return SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT;
                case 4: return SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT | SL_SPEAKER_BACK_LEFT | SL_SPEAKER_BACK_RIGHT;
                case 6: return SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT | SL_SPEAKER_FRONT_CENTER | SL_SPEAKER_LOW_FREQUENCY | SL_SPEAKER_SIDE_LEFT | SL_SPEAKER_SIDE_RIGHT;
                default: return 0;
            }
        }
    }

    struct Output
    {
        fx_audio_pull pull;
        void *mixer;
        std::uint32_t channels = 2;
        std::uint32_t sample_rate = 44100;

        Pointer<SLObjectItf> engine_object;
        SLEngineItf engine = nullptr;
        Pointer<SLObjectItf> output_mix_object;
        Pointer<SLObjectItf> player_object;
        SLPlayItf player = nullptr;
        SLAndroidSimpleBufferQueueItf buffer_queue = nullptr;

        std::vector<float> planar;
        std::vector<std::int16_t> interleaved;

        void enqueueNext();
    };

    namespace
    {
        void playerCallback(SLAndroidSimpleBufferQueueItf, void *context)
        {
            static_cast<Output *>(context)->enqueueNext();
        }
    }

    Output *open(fx_audio_pull pull, void *mixer, std::uint32_t *channels, std::uint32_t *sample_rate)
    {
        auto output = std::make_unique<Output>();
        output->pull = pull;
        output->mixer = mixer;
        output->channels = *channels != 0 ? *channels : 2;
        output->sample_rate = *sample_rate != 0 ? *sample_rate : 44100;
        if (channelMask(output->channels) == 0) return nullptr;

        const std::array<SLInterfaceID, 2> engine_interfaces = {SL_IID_ENGINE, SL_IID_ENGINECAPABILITIES};
        const std::array<SLboolean, 2> engine_requirements = {SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE};

        SLObjectItf engine_object_ptr;
        if (slCreateEngine(&engine_object_ptr, 0, nullptr, static_cast<SLuint32>(engine_interfaces.size()),
                           engine_interfaces.data(), engine_requirements.data()) != SL_RESULT_SUCCESS)
            return nullptr;
        output->engine_object = engine_object_ptr;
        if (output->engine_object->Realize(output->engine_object.get(), SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS)
            return nullptr;
        if (output->engine_object->GetInterface(output->engine_object.get(), SL_IID_ENGINE, &output->engine) != SL_RESULT_SUCCESS)
            return nullptr;

        SLObjectItf output_mix_ptr;
        if ((*output->engine)->CreateOutputMix(output->engine, &output_mix_ptr, 0, nullptr, nullptr) != SL_RESULT_SUCCESS)
            return nullptr;
        output->output_mix_object = output_mix_ptr;
        if (output->output_mix_object->Realize(output->output_mix_object.get(), SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS)
            return nullptr;

        SLDataLocator_AndroidSimpleBufferQueue location = {SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 2};
        SLDataFormat_PCM data_format;
        data_format.formatType = SL_DATAFORMAT_PCM;
        data_format.numChannels = output->channels;
        data_format.samplesPerSec = output->sample_rate * 1000; // mHz
        data_format.bitsPerSample = sizeof(std::int16_t) * 8;
        data_format.containerSize = data_format.bitsPerSample;
        data_format.channelMask = channelMask(output->channels);
        data_format.endianness = SL_BYTEORDER_LITTLEENDIAN;

        SLDataSource data_source{&location, &data_format};
        SLDataLocator_OutputMix data_locator_out{SL_DATALOCATOR_OUTPUTMIX, output->output_mix_object.get()};
        SLDataSink data_sink{&data_locator_out, nullptr};
        const SLInterfaceID player_iids[] = {SL_IID_BUFFERQUEUE, SL_IID_PLAY};
        const SLboolean player_reqs[] = {SL_BOOLEAN_TRUE, SL_BOOLEAN_TRUE};

        SLObjectItf player_object_ptr;
        if ((*output->engine)->CreateAudioPlayer(output->engine, &player_object_ptr, &data_source, &data_sink, 2, player_iids, player_reqs) != SL_RESULT_SUCCESS)
            return nullptr;
        output->player_object = player_object_ptr;
        if (output->player_object->Realize(output->player_object.get(), SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS)
            return nullptr;
        if (output->player_object->GetInterface(output->player_object.get(), SL_IID_PLAY, &output->player) != SL_RESULT_SUCCESS)
            return nullptr;
        if (output->player_object->GetInterface(output->player_object.get(), SL_IID_BUFFERQUEUE, &output->buffer_queue) != SL_RESULT_SUCCESS)
            return nullptr;
        if ((*output->buffer_queue)->RegisterCallback(output->buffer_queue, playerCallback, output.get()) != SL_RESULT_SUCCESS)
            return nullptr;

        *channels = output->channels;
        *sample_rate = output->sample_rate;

        // The first buffer: everything after this is `enqueueNext`, called
        // back once this one has played.
        output->enqueueNext();
        if ((*output->player)->SetPlayState(output->player, SL_PLAYSTATE_PLAYING) != SL_RESULT_SUCCESS)
            return nullptr;

        return output.release();
    }

    void close(Output *output)
    {
        if (!output) return;
        if (output->player) (*output->player)->SetPlayState(output->player, SL_PLAYSTATE_STOPPED);
        delete output;
    }

    void Output::enqueueNext()
    {
        // One buffer's worth per callback - Android's OpenSL ES wants the
        // queue kept fed, not a fixed period size the way ALSA does.
        const std::uint32_t frame_count = sample_rate / 50; // 20ms
        planar.resize(static_cast<std::size_t>(frame_count) * channels);
        pull(mixer, frame_count, channels, sample_rate, planar.data());

        interleaved.resize(static_cast<std::size_t>(frame_count) * channels);
        for (std::uint32_t frame = 0; frame < frame_count; ++frame)
            for (std::uint32_t ch = 0; ch < channels; ++ch)
            {
                float sample = planar[static_cast<std::size_t>(ch) * frame_count + frame];
                sample = sample < -1.0F ? -1.0F : (sample > 1.0F ? 1.0F : sample);
                interleaved[frame * channels + ch] = static_cast<std::int16_t>(sample * 32767.0F);
            }

        (*buffer_queue)->Enqueue(buffer_queue, interleaved.data(), interleaved.size() * sizeof(std::int16_t));
    }
}

extern "C" fx_audio_output *fx_audio_opensl_open(fx_audio_pull pull, void *mixer, uint32_t *channels, uint32_t *sample_rate)
{
    return reinterpret_cast<fx_audio_output *>(fluxion_audio::opensl::open(pull, mixer, channels, sample_rate));
}

extern "C" void fx_audio_opensl_close(fx_audio_output *output)
{
    fluxion_audio::opensl::close(reinterpret_cast<fluxion_audio::opensl::Output *>(output));
}
