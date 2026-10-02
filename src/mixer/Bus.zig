// SPDX-License-Identifier: CC0-1.0

//! Where streams and other buses mix together, through its processors, into
//! another bus or as the master. A stream at another rate or speed is
//! resampled to the output's, and one with other channels mixed up or down
//! to them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Stream = @import("Stream.zig");
const Processor = @import("effects.zig").Processor;

const Bus = @This();

output: ?*Bus = null,
input_buses: std.ArrayList(*Bus) = .empty,
input_streams: std.ArrayList(*Stream) = .empty,
processors: std.ArrayList(*Processor) = .empty,

resample_buffer: std.ArrayList(f32) = .empty,
mix_buffer: std.ArrayList(f32) = .empty,
buffer: std.ArrayList(f32) = .empty,

pub fn create(gpa: Allocator) Allocator.Error!*Bus {
    const self = try gpa.create(Bus);
    self.* = .{};
    return self;
}

/// Taken out of what it feeds, and let go of by what feeds it.
pub fn destroy(self: *Bus, gpa: Allocator) void {
    if (self.output) |output| output.removeInputBus(self);
    for (self.input_buses.items) |bus| bus.output = null;
    for (self.input_streams.items) |stream| stream.output = null;
    for (self.processors.items) |processor| processor.bus = null;
    self.input_buses.deinit(gpa);
    self.input_streams.deinit(gpa);
    self.processors.deinit(gpa);
    self.resample_buffer.deinit(gpa);
    self.mix_buffer.deinit(gpa);
    self.buffer.deinit(gpa);
    gpa.destroy(self);
}

pub fn setOutput(self: *Bus, gpa: Allocator, output: ?*Bus) Allocator.Error!void {
    if (self.output) |old| old.removeInputBus(self);
    self.output = output;
    if (output) |new| try addUnique(*Bus, gpa, &new.input_buses, self);
}

pub fn addProcessor(self: *Bus, gpa: Allocator, processor: *Processor) Allocator.Error!void {
    if (std.mem.indexOfScalar(*Processor, self.processors.items, processor) != null) return;
    try self.processors.ensureUnusedCapacity(gpa, 1);
    if (processor.bus) |old| old.removeProcessor(processor);
    processor.bus = self;
    self.processors.appendAssumeCapacity(processor);
}

pub fn removeProcessor(self: *Bus, processor: *Processor) void {
    const at = std.mem.indexOfScalar(*Processor, self.processors.items, processor) orelse return;
    processor.bus = null;
    _ = self.processors.orderedRemove(at);
}

pub fn addInputStream(self: *Bus, gpa: Allocator, stream: *Stream) Allocator.Error!void {
    try addUnique(*Stream, gpa, &self.input_streams, stream);
}

pub fn removeInputStream(self: *Bus, stream: *Stream) void {
    const at = std.mem.indexOfScalar(*Stream, self.input_streams.items, stream) orelse return;
    _ = self.input_streams.orderedRemove(at);
}

fn removeInputBus(self: *Bus, bus: *Bus) void {
    const at = std.mem.indexOfScalar(*Bus, self.input_buses.items, bus) orelse return;
    _ = self.input_buses.orderedRemove(at);
}

fn addUnique(comptime T: type, gpa: Allocator, list: *std.ArrayList(T), item: T) Allocator.Error!void {
    if (std.mem.indexOfScalar(T, list.items, item) == null) try list.append(gpa, item);
}

/// `frames` of `channels` at `sample_rate` into `samples`, planar by
/// channel: every bus feeding this one, every stream that plays, then the
/// processors.
pub fn generate(self: *Bus, gpa: Allocator, frames: u32, channels: u32, sample_rate: u32, samples: *std.ArrayList(f32)) Allocator.Error!void {
    try samples.resize(gpa, @as(usize, frames) * channels);
    @memset(samples.items, 0);

    for (self.input_buses.items) |bus| {
        try bus.generate(gpa, frames, channels, sample_rate, &self.buffer);
        for (samples.items, self.buffer.items) |*sample, added| sample.* += added;
    }

    for (self.input_streams.items) |stream| {
        if (!stream.playing) continue;
        const source_rate = stream.data.sample_rate;
        const source_channels = stream.data.channels;

        // How many of the clip's frames these are: its rate against the
        // output's, times the voice's speed, and what the last mix owed
        // carried over, so a rate that is no whole number of frames a mix
        // keeps its time.
        const exact = @as(f64, @floatFromInt(frames)) * @as(f64, @floatFromInt(source_rate)) * @as(f64, stream.speed) / @as(f64, @floatFromInt(sample_rate)) + stream.carry;
        const source_frames: u32 = @intFromFloat(@max(exact, 1));
        stream.carry = std.math.clamp(exact - @as(f64, @floatFromInt(source_frames)), -1, 1);

        if (source_frames != frames) {
            try stream.generate(gpa, source_frames, &self.resample_buffer);
            try resample(gpa, source_channels, source_frames, self.resample_buffer.items, frames, &self.mix_buffer);
        } else try stream.generate(gpa, frames, &self.mix_buffer);

        const mixed = if (source_channels != channels) blk: {
            try convert(gpa, frames, source_channels, self.mix_buffer.items, channels, &self.buffer);
            break :blk self.buffer.items;
        } else self.mix_buffer.items;
        for (samples.items, mixed) |*sample, added| sample.* += added;
    }

    for (self.processors.items) |processor| {
        if (processor.enabled) processor.process(gpa, frames, channels, sample_rate, samples.items);
    }
}

/// `source_frames` of each channel laid over `frames`, by straight lines
/// between neighbours, the last frame on the last.
fn resample(gpa: Allocator, channels: u32, source_frames: u32, source: []const f32, frames: u32, samples: *std.ArrayList(f32)) Allocator.Error!void {
    try samples.resize(gpa, @as(usize, frames) * channels);
    if (source_frames == frames) return @memcpy(samples.items, source);
    if (source_frames < 2 or frames < 2) {
        // Too few on either side to lay one across the other: the last of
        // the source held.
        @memset(samples.items, 0);
        if (source_frames == 0) return;
        for (0..channels) |channel| @memset(samples.items[channel * frames ..][0..frames], source[channel * source_frames + source_frames - 1]);
        return;
    }
    // Each frame's place worked out on its own, not added up: a sum drifts,
    // and past the source's last pair.
    const scale = @as(f64, @floatFromInt(source_frames - 1)) / @as(f64, @floatFromInt(frames - 1));
    for (0..frames - 1) |frame| {
        const position = @as(f64, @floatFromInt(frame)) * scale;
        const current = @min(@as(usize, @intFromFloat(position)), source_frames - 2);
        const fraction: f32 = @floatCast(position - @as(f64, @floatFromInt(current)));
        for (0..channels) |channel| {
            const from = source[channel * source_frames ..];
            samples.items[channel * frames + frame] = from[current] + (from[current + 1] - from[current]) * fraction;
        }
    }
    // The last frame takes the source's last directly: the loop above
    // only ever comes up to it.
    for (0..channels) |channel| samples.items[channel * frames + frames - 1] = source[channel * source_frames + source_frames - 1];
}

/// `source_channels` mixed up or down to `channels`: mono, stereo,
/// quadraphonic and 5.1, the centre and the surrounds a little under the
/// fronts.
fn convert(gpa: Allocator, frames: u32, source_channels: u32, source: []const f32, channels: u32, samples: *std.ArrayList(f32)) Allocator.Error!void {
    try samples.resize(gpa, @as(usize, frames) * channels);
    if (source_channels == channels) return @memcpy(samples.items, source);
    @memset(samples.items, 0);
    const n = frames;
    const s = source;
    const out = samples.items;
    for (0..n) |f| {
        switch (source_channels) {
            1 => switch (channels) {
                2, 4 => {
                    out[0 * n + f] = s[f];
                    out[1 * n + f] = s[f];
                },
                6 => out[2 * n + f] = s[f],
                else => {},
            },
            2 => switch (channels) {
                1 => out[f] = (s[0 * n + f] + s[1 * n + f]) * 0.5,
                4, 6 => {
                    out[0 * n + f] = s[0 * n + f];
                    out[1 * n + f] = s[1 * n + f];
                },
                else => {},
            },
            4 => switch (channels) {
                1 => out[f] = (s[0 * n + f] + s[1 * n + f] + s[2 * n + f] + s[3 * n + f]) * 0.25,
                2 => {
                    out[0 * n + f] = (s[0 * n + f] + s[2 * n + f]) * 0.5;
                    out[1 * n + f] = (s[1 * n + f] + s[3 * n + f]) * 0.5;
                },
                6 => {
                    out[0 * n + f] = s[0 * n + f];
                    out[1 * n + f] = s[1 * n + f];
                    out[4 * n + f] = s[2 * n + f];
                    out[5 * n + f] = s[3 * n + f];
                },
                else => {},
            },
            6 => switch (channels) {
                1 => out[f] = (s[0 * n + f] + s[1 * n + f]) * 0.7071 + s[2 * n + f] + (s[4 * n + f] + s[5 * n + f]) * 0.5,
                2 => {
                    out[0 * n + f] = s[0 * n + f] + (s[2 * n + f] + s[4 * n + f]) * 0.7071;
                    out[1 * n + f] = s[1 * n + f] + (s[2 * n + f] + s[5 * n + f]) * 0.7071;
                },
                4 => {
                    out[0 * n + f] = s[0 * n + f] + s[2 * n + f] * 0.7071;
                    out[1 * n + f] = s[1 * n + f] + s[2 * n + f] * 0.7071;
                    out[2 * n + f] = s[4 * n + f];
                    out[3 * n + f] = s[5 * n + f];
                },
                else => {},
            },
            else => {},
        }
    }
}
