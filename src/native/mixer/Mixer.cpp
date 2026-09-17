// SPDX-License-Identifier: CC0-1.0

#include <algorithm>
#include "Mixer.hpp"
#include "Bus.hpp"
#include "Data.hpp"
#include "MixerError.hpp"
#include "Stream.hpp"

namespace fluxion_audio
{
    void Mixer::process()
    {
        CommandBuffer commandBuffer;
        std::unique_ptr<Command> command;

        for (;;)
        {
            std::unique_lock lock{commandQueueMutex};
            if (commandQueue.empty()) break;
            commandBuffer = std::move(commandQueue.front());
            commandQueue.pop();
            lock.unlock();

            while (!commandBuffer.isEmpty())
            {
                command = commandBuffer.popCommand();

                switch (command->type)
                {
                    case Command::Type::deleteObject:
                    {
                        const auto deleteObjectCommand = static_cast<const DeleteObjectCommand*>(command.get());
                        objects[deleteObjectCommand->objectId - 1].reset();
                        break;
                    }
                    case Command::Type::initBus:
                    {
                        const auto initBusCommand = static_cast<const InitBusCommand*>(command.get());

                        if (initBusCommand->busId > objects.size())
                            objects.resize(initBusCommand->busId);

                        objects[initBusCommand->busId - 1] = std::make_unique<Bus>();
                        break;
                    }
                    case Command::Type::setBusOutput:
                    {
                        const auto setBusOutputCommand = static_cast<const SetBusOutputCommand*>(command.get());

                        const auto bus = static_cast<Bus*>(objects[setBusOutputCommand->busId - 1].get());
                        bus->setOutput(setBusOutputCommand->outputBusId ? static_cast<Bus*>(objects[setBusOutputCommand->outputBusId - 1].get()) : nullptr);
                        break;
                    }
                    case Command::Type::addProcessor:
                    {
                        const auto addProcessorCommand = static_cast<const AddProcessorCommand*>(command.get());

                        const auto bus = static_cast<Bus*>(objects[addProcessorCommand->busId - 1].get());
                        const auto processor = static_cast<Processor*>(objects[addProcessorCommand->processorId - 1].get());
                        bus->addProcessor(processor);
                        break;
                    }
                    case Command::Type::removeProcessor:
                    {
                        const auto removeProcessorCommand = static_cast<const RemoveProcessorCommand*>(command.get());

                        const auto bus = static_cast<Bus*>(objects[removeProcessorCommand->busId - 1].get());
                        const auto processor = static_cast<Processor*>(objects[removeProcessorCommand->processorId - 1].get());
                        bus->removeProcessor(processor);
                        break;
                    }
                    case Command::Type::setMasterBus:
                    {
                        const auto setMasterBusCommand = static_cast<const SetMasterBusCommand*>(command.get());

                        masterBus = setMasterBusCommand->busId ? static_cast<Bus*>(objects[setMasterBusCommand->busId - 1].get()) : nullptr;
                        break;
                    }
                    case Command::Type::initStream:
                    {
                        const auto initStreamCommand = static_cast<const InitStreamCommand*>(command.get());

                        if (initStreamCommand->streamId > objects.size())
                            objects.resize(initStreamCommand->streamId);

                        const auto data = static_cast<Data*>(objects[initStreamCommand->dataId - 1].get());
                        objects[initStreamCommand->streamId - 1] = data->createStream();
                        break;
                    }
                    case Command::Type::playStream:
                    {
                        const auto playStreamCommand = static_cast<const PlayStreamCommand*>(command.get());

                        const auto stream = static_cast<Stream*>(objects[playStreamCommand->streamId - 1].get());
                        stream->play();
                        break;
                    }
                    case Command::Type::stopStream:
                    {
                        const auto stopStreamCommand = static_cast<const StopStreamCommand*>(command.get());

                        const auto stream = static_cast<Stream*>(objects[stopStreamCommand->streamId - 1].get());
                        stream->stop(stopStreamCommand->reset);
                        break;
                    }
                    case Command::Type::setStreamOutput:
                    {
                        const auto setStreamOutputCommand = static_cast<const SetStreamOutputCommand*>(command.get());

                        const auto stream = static_cast<Stream*>(objects[setStreamOutputCommand->streamId - 1].get());
                        stream->setOutput(setStreamOutputCommand->busId ? static_cast<Bus*>(objects[setStreamOutputCommand->busId - 1].get()) : nullptr);
                        break;
                    }
                    case Command::Type::initData:
                    {
                        const auto initDataCommand = static_cast<InitDataCommand*>(command.get());

                        if (initDataCommand->dataId > objects.size())
                            objects.resize(initDataCommand->dataId);

                        objects[initDataCommand->dataId - 1] = std::move(initDataCommand->data);
                        break;
                    }
                    case Command::Type::initProcessor:
                    {
                        const auto initProcessorCommand = static_cast<InitProcessorCommand*>(command.get());

                        if (initProcessorCommand->processorId > objects.size())
                            objects.resize(initProcessorCommand->processorId);

                        objects[initProcessorCommand->processorId - 1] = std::move(initProcessorCommand->processor);
                        break;
                    }
                    case Command::Type::updateProcessor:
                    {
                        const auto updateProcessorCommand = static_cast<const UpdateProcessorCommand*>(command.get());

                        const auto processor = static_cast<Processor*>(objects[updateProcessorCommand->processorId - 1].get());
                        updateProcessorCommand->updateFunction(processor);
                        break;
                    }
                    default:
                        throw Error{"Invalid command"};
                }
            }
        }
    }

    void Mixer::getSamples(std::uint32_t frames, std::uint32_t channels, std::uint32_t sampleRate, std::vector<float>& samples)
    {
        process();

        samples.resize(frames * channels);

        if (masterBus)
            masterBus->generateSamples(frames, channels, sampleRate, samples);
        else
            std::fill(samples.begin(), samples.end(), 0.0F);

        for (auto& sample : samples)
            sample = std::clamp(sample, -1.0F, 1.0F);
    }

    bool Mixer::isStreamPlaying(ObjectId streamId) const
    {
        if (streamId == 0 || streamId > objects.size() || !objects[streamId - 1])
            return false;
        return static_cast<Stream*>(objects[streamId - 1].get())->isPlaying();
    }
}
