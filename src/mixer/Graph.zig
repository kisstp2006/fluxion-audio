// SPDX-License-Identifier: CC0-1.0

//! The mixer graph: buses, clips, streams and processors in one table, one
//! id space, and the queue of changes that rebuilds it - the one seam
//! between whatever thread calls `Device` and whatever thread pulls samples
//! out of the master bus.
//!
//! The calling thread asks for an id with `nextId`, and every change -
//! making an object, wiring it, playing it, deleting it - is queued.
//! `getSamples`, on the thread that produces sound, applies the queue and
//! then mixes; it is the only thread that ever touches the table. A browser
//! has one thread, and the same order of things on it.
//!
//! What it allocates on the sound thread - a stream's reader, a bus's
//! buffers as they grow - goes through the same allocator as the rest, which
//! has to be one that two threads may share.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Stream = @import("Stream.zig");
const clips = @import("clips.zig");
const effects = @import("effects.zig");

pub const Data = clips.Data;
pub const Processor = effects.Processor;
pub const VoiceState = Stream.VoiceState;

const Graph = @This();

/// Zero never names a live object.
pub const Id = usize;

gpa: Allocator,

// The calling thread's.
last_id: Id = 0,
/// Ids let go of, handed out again smallest first.
free_ids: std.ArrayList(Id) = .empty,

// Shared, under `lock`.
lock: std.atomic.Value(bool) = .init(false),
pending: std.ArrayList(Command) = .empty,

// The sound thread's.
working: std.ArrayList(Command) = .empty,
objects: std.ArrayList(?Object) = .empty,
master: ?*Bus = null,
mixed: std.ArrayList(f32) = .empty,

const Object = union(enum) {
    bus: *Bus,
    data: *Data,
    stream: *Stream,
    processor: *Processor,

    fn destroy(self: Object, gpa: Allocator) void {
        switch (self) {
            inline else => |object| object.destroy(gpa),
        }
    }
};

pub const Command = union(enum) {
    delete: Id,
    init_bus: Id,
    set_bus_output: struct { bus: Id, output: Id },
    set_master_bus: Id,
    add_processor: struct { bus: Id, processor: Id },
    remove_processor: struct { bus: Id, processor: Id },
    init_data: struct { id: Id, data: *Data },
    init_stream: struct { id: Id, data: Id, state: *VoiceState },
    play_stream: Id,
    stop_stream: struct { id: Id, reset: bool },
    set_stream_output: struct { id: Id, bus: Id },
    seek_stream: struct { id: Id, frame: u64 },
    set_stream_looping: struct { id: Id, looping: bool },
    set_stream_speed: struct { id: Id, speed: f32 },
    init_processor: struct { id: Id, processor: *Processor },
    set_gain: struct { id: Id, value: f32 },
    set_pan: struct { id: Id, value: f32 },
    set_pitch: struct { id: Id, value: f32 },
};

pub fn init(gpa: Allocator) Graph {
    return .{ .gpa = gpa };
}

/// Every object, and what was queued and never applied. The sound thread
/// has stopped.
pub fn deinit(self: *Graph) void {
    const gpa = self.gpa;
    self.apply(&self.pending);
    for (self.objects.items) |maybe| if (maybe) |object| object.destroy(gpa);
    self.objects.deinit(gpa);
    self.free_ids.deinit(gpa);
    self.pending.deinit(gpa);
    self.working.deinit(gpa);
    self.mixed.deinit(gpa);
}

// -------------------------------------------------------------------------
// The calling thread
// -------------------------------------------------------------------------

/// An id for a new object: one let go of, smallest first, or the next.
pub fn nextId(self: *Graph) Id {
    if (self.free_ids.items.len > 0) {
        const least = std.mem.indexOfMin(Id, self.free_ids.items);
        return self.free_ids.swapRemove(least);
    }
    self.last_id += 1;
    return self.last_id;
}

/// Queue a change. What it carries - a clip made, a state held - is let go
/// of here when it cannot be queued.
pub fn submit(self: *Graph, command: Command) Allocator.Error!void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer self.lock.store(false, .release);
    self.pending.append(self.gpa, command) catch |err| {
        switch (command) {
            .init_data => |init_data| init_data.data.destroy(self.gpa),
            .init_stream => |init_stream| init_stream.state.release(self.gpa),
            .init_processor => |init_processor| init_processor.processor.destroy(self.gpa),
            else => {},
        }
        return err;
    };
}

/// `submit`, where nothing can be done about a queue that could not grow.
pub fn send(self: *Graph, command: Command) void {
    self.submit(command) catch {};
}

pub fn delete(self: *Graph, id: Id) void {
    self.send(.{ .delete = id });
    self.free_ids.append(self.gpa, id) catch {};
}

/// A stream of clip `data`, and the state it says how it plays in - held by
/// the caller, who lets go of it with `VoiceState.release` once done.
pub fn initStream(self: *Graph, id: Id, data: Id) Allocator.Error!*VoiceState {
    const state = try VoiceState.create(self.gpa);
    // The command holds it until the stream it makes takes the hold; the
    // caller's hold is the other.
    errdefer state.release(self.gpa);
    try self.submit(.{ .init_stream = .{ .id = id, .data = data, .state = state } });
    return state;
}

// -------------------------------------------------------------------------
// The sound thread
// -------------------------------------------------------------------------

/// Apply every change queued since the last time, then mix `frames` of
/// `channels` at `sample_rate` through the master bus into `out`, planar by
/// channel, each sample within -1 and 1.
pub fn getSamples(self: *Graph, frames: u32, channels: u32, sample_rate: u32, out: []f32) void {
    {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer self.lock.store(false, .release);
        std.mem.swap(std.ArrayList(Command), &self.pending, &self.working);
    }
    self.apply(&self.working);

    const wanted = @as(usize, frames) * channels;
    const master = self.master orelse return @memset(out[0..wanted], 0);
    master.generate(self.gpa, frames, channels, sample_rate, &self.mixed) catch return @memset(out[0..wanted], 0);
    for (out[0..wanted], self.mixed.items) |*sample, mixed| sample.* = std.math.clamp(mixed, -1, 1);
}

fn apply(self: *Graph, commands: *std.ArrayList(Command)) void {
    defer commands.clearRetainingCapacity();
    const gpa = self.gpa;
    for (commands.items) |command| switch (command) {
        .delete => |id| if (self.take(id)) |object| {
            if (object == .bus and self.master == object.bus) self.master = null;
            object.destroy(gpa);
        },
        .init_bus => |id| {
            const bus = Bus.create(gpa) catch continue;
            self.put(id, .{ .bus = bus });
        },
        .set_bus_output => |set| if (self.get(.bus, set.bus)) |bus| {
            bus.setOutput(gpa, self.get(.bus, set.output)) catch {};
        },
        .set_master_bus => |id| self.master = self.get(.bus, id),
        .add_processor => |add| if (self.get(.bus, add.bus)) |bus| if (self.get(.processor, add.processor)) |processor| {
            bus.addProcessor(gpa, processor) catch {};
        },
        .remove_processor => |remove| if (self.get(.bus, remove.bus)) |bus| if (self.get(.processor, remove.processor)) |processor| {
            bus.removeProcessor(processor);
        },
        .init_data => |init_data| self.put(init_data.id, .{ .data = init_data.data }),
        .init_stream => |init_stream| {
            // The stream takes the command's hold on its state.
            const data = self.get(.data, init_stream.data) orelse {
                init_stream.state.release(gpa);
                continue;
            };
            const stream = Stream.create(gpa, data, init_stream.state) catch {
                init_stream.state.release(gpa);
                continue;
            };
            self.put(init_stream.id, .{ .stream = stream });
        },
        .play_stream => |id| if (self.get(.stream, id)) |stream| stream.play(),
        .stop_stream => |stop| if (self.get(.stream, stop.id)) |stream| stream.stop(stop.reset),
        .set_stream_output => |set| if (self.get(.stream, set.id)) |stream| {
            stream.setOutput(gpa, self.get(.bus, set.bus)) catch {};
        },
        .seek_stream => |seek| if (self.get(.stream, seek.id)) |stream| stream.seek(seek.frame),
        .set_stream_looping => |set| if (self.get(.stream, set.id)) |stream| {
            stream.looping = set.looping;
        },
        .set_stream_speed => |set| if (self.get(.stream, set.id)) |stream| stream.setSpeed(set.speed),
        .init_processor => |init_processor| self.put(init_processor.id, .{ .processor = init_processor.processor }),
        .set_gain => |set| if (self.get(.processor, set.id)) |processor| {
            if (processor.kind == .gain) processor.kind.gain = set.value;
        },
        .set_pan => |set| if (self.get(.processor, set.id)) |processor| {
            if (processor.kind == .pan) processor.kind.pan = set.value;
        },
        .set_pitch => |set| if (self.get(.processor, set.id)) |processor| {
            if (processor.kind == .pitch) processor.kind.pitch.pitch = set.value;
        },
    };
}

/// Object `id` in the table, when it is a `kind`.
fn get(self: *Graph, comptime kind: std.meta.Tag(Object), id: Id) ?@FieldType(Object, @tagName(kind)) {
    if (id == 0 or id > self.objects.items.len) return null;
    const object = self.objects.items[id - 1] orelse return null;
    return if (object == kind) @field(object, @tagName(kind)) else null;
}

/// `object` in the table at `id`, in place of anything there before.
fn put(self: *Graph, id: Id, object: Object) void {
    if (id > self.objects.items.len) {
        const was = self.objects.items.len;
        self.objects.resize(self.gpa, id) catch return object.destroy(self.gpa);
        @memset(self.objects.items[was..], null);
    }
    if (self.objects.items[id - 1]) |old| old.destroy(self.gpa);
    self.objects.items[id - 1] = object;
}

fn take(self: *Graph, id: Id) ?Object {
    if (id == 0 or id > self.objects.items.len) return null;
    defer self.objects.items[id - 1] = null;
    return self.objects.items[id - 1];
}
