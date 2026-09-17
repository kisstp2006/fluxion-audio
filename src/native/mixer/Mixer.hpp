// SPDX-License-Identifier: CC0-1.0

#ifndef FLUXION_AUDIO_MIXER_MIXER_HPP
#define FLUXION_AUDIO_MIXER_MIXER_HPP

#include <cstdint>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
#include <vector>
#include "Commands.hpp"
#include "Object.hpp"
#include "Bus.hpp"

namespace fluxion_audio
{
    // The object table and the command queue that rebuilds it: the one
    // thread-safe seam between whatever thread calls `Device` and whatever
    // thread pulls samples out of the master bus.
    class Mixer final
    {
    public:
        Mixer() = default;
        ~Mixer() = default;

        Mixer(const Mixer&) = delete;
        Mixer& operator=(const Mixer&) = delete;
        Mixer(Mixer&&) = delete;
        Mixer& operator=(Mixer&&) = delete;

        // Applies every command queued since the last call, then mixes
        // `frames` of audio at `sampleRate` through the master bus. Called
        // from the thread that actually produces sound - the only thread
        // that ever reads the object table.
        void getSamples(std::uint32_t frames, std::uint32_t channels, std::uint32_t sampleRate, std::vector<float>& samples);

        using ObjectId = std::size_t;
        ObjectId getObjectId()
        {
            if (const auto i = deletedObjectIds.begin(); i != deletedObjectIds.end())
            {
                const auto objectId = *i;
                deletedObjectIds.erase(i);
                return objectId;
            }
            else
                return ++lastObjectId; // zero is reserved for null
        }

        void deleteObjectId(ObjectId objectId)
        {
            deletedObjectIds.insert(objectId);
        }

        // Reads the object table directly, bypassing the command queue.
        // Only `getSamples` is meant to touch `objects` from outside a
        // command - this is a second, deliberate exception for a read-only
        // status check, and it is safe only as long as `getSamples` is
        // pumped from the same thread that calls this. A backend with its
        // own independent output thread needs a real cross-thread flag
        // instead, not this.
        bool isStreamPlaying(ObjectId streamId) const;

        // Thread-safe: called from whatever thread `Device` is used on.
        void submitCommandBuffer(CommandBuffer&& commandBuffer)
        {
            std::scoped_lock lock{commandQueueMutex};
            commandQueue.push(std::move(commandBuffer));
        }

    private:
        void process();

        ObjectId lastObjectId = 0;
        std::set<ObjectId> deletedObjectIds;

        std::vector<std::unique_ptr<Object>> objects;
        Bus* masterBus = nullptr;

        std::queue<CommandBuffer> commandQueue;
        std::mutex commandQueueMutex;
    };
}

#endif // FLUXION_AUDIO_MIXER_MIXER_HPP
