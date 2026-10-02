// SPDX-License-Identifier: CC0-1.0

//! A clip being played: a place in its `Data`, the bus it feeds, and how it
//! goes - looping or not, at what speed. Reading is the clip's; coming to
//! the end, going round again, and saying so are this file's - and what it
//! says goes to a `VoiceState`, which whoever started it reads from any
//! thread.

const std = @import("std");
const Allocator = std.mem.Allocator;

const clips = @import("clips.zig");
const Data = clips.Data;
const Bus = @import("Bus.zig");

const Stream = @This();

data: *Data,
reader: clips.Reader,
state: ?*VoiceState,
output: ?*Bus = null,
position: u64 = 0,
/// The part of a frame of the clip the last mix owed, at a speed or a rate
/// that is not a whole number of frames a mix.
carry: f64 = 0,
speed: f32 = 1,
playing: bool = false,
looping: bool = false,

/// What a playing stream says of itself to the thread that asked for it:
/// whether it plays, how far into its clip it is, and how many times it has
/// come to its end. The stream writes it as it mixes; anyone reads it, from
/// any thread, without waiting on the mix.
///
/// Two hold it - the stream, and whoever made the stream - and the last to
/// let go frees it, so neither outlives the other's reading or writing.
pub const VoiceState = struct {
    holders: std.atomic.Value(u32) = .init(2),
    playing_flag: std.atomic.Value(u32) = .init(0),
    /// A word, which every target has atomics for: on a 32-bit one (the
    /// browser) it comes round after 2^32 frames - 27 hours at 44.1 kHz.
    frame_at: std.atomic.Value(usize) = .init(0),
    end_count: std.atomic.Value(u32) = .init(0),

    pub fn create(gpa: Allocator) Allocator.Error!*VoiceState {
        const self = try gpa.create(VoiceState);
        self.* = .{};
        return self;
    }

    pub fn release(self: *VoiceState, gpa: Allocator) void {
        if (self.holders.fetchSub(1, .acq_rel) == 1) gpa.destroy(self);
    }

    pub fn playing(self: *const VoiceState) bool {
        return self.playing_flag.load(.acquire) != 0;
    }

    pub fn frame(self: *const VoiceState) u64 {
        return self.frame_at.load(.monotonic);
    }

    pub fn ends(self: *const VoiceState) u32 {
        return self.end_count.load(.acquire);
    }

    /// What it will be once a change asked for now is mixed: said at once,
    /// so a status read straight after the asking is already right.
    pub fn expect(self: *VoiceState, is_playing: bool, at: u64) void {
        self.frame_at.store(@truncate(at), .monotonic);
        self.playing_flag.store(@intFromBool(is_playing), .release);
    }
};

/// A stream of `data`, at its start; `state` is the stream's to write and to
/// let go of.
pub fn create(gpa: Allocator, data: *Data, state: ?*VoiceState) Allocator.Error!*Stream {
    var reader = try data.reader(gpa);
    errdefer reader.deinit(gpa);
    const self = try gpa.create(Stream);
    self.* = .{ .data = data, .reader = reader, .state = state };
    return self;
}

pub fn destroy(self: *Stream, gpa: Allocator) void {
    if (self.output) |output| output.removeInputStream(self);
    if (self.state) |state| state.release(gpa);
    self.reader.deinit(gpa);
    gpa.destroy(self);
}

pub fn setOutput(self: *Stream, gpa: Allocator, output: ?*Bus) Allocator.Error!void {
    if (self.output) |old| old.removeInputStream(self);
    self.output = output;
    if (output) |new| try new.addInputStream(gpa, self);
}

pub fn play(self: *Stream) void {
    self.playing = true;
    self.publish();
}

/// Held where it is, or with `reset`, back at the start.
pub fn stop(self: *Stream, reset: bool) void {
    self.playing = false;
    if (reset) self.seek(0) else self.publish();
}

/// 1 plays the clip as it was recorded; 2 twice as fast, an octave up.
pub fn setSpeed(self: *Stream, speed: f32) void {
    self.speed = if (speed > 0) speed else 0;
}

/// From `to` frame of the clip on - its end, for one past it.
pub fn seek(self: *Stream, to: u64) void {
    const frames = self.data.frames();
    const at = if (frames != 0 and to > frames) frames else to;
    self.reader.rewind(self.data, at);
    self.position = at;
    self.carry = 0;
    self.publish();
}

/// `frames` frames in the clip's own channels, planar: what it has from
/// where it is, from the start again when it loops, and silence past the end
/// of one that does not.
pub fn generate(self: *Stream, gpa: Allocator, frames: u32, samples: *std.ArrayList(f32)) Allocator.Error!void {
    try samples.resize(gpa, @as(usize, frames) * self.data.channels);
    @memset(samples.items, 0);

    const length = self.data.frames();
    var done: u32 = 0;
    while (done < frames and self.playing) {
        const wanted = frames - done;
        const got = self.reader.read(self.data, samples.items, frames, done, wanted);
        done += got;
        self.position += got;
        // All that was asked for - and one of a known length that has played
        // its last frame with it ends now, not a mix later.
        if (got == wanted and (self.looping or length == 0 or self.position < length)) break;

        // The end. A clip that looped round and read nothing has nothing in
        // it, and ends rather than going round for ever.
        if (self.looping and self.position > 0) {
            self.reader.rewind(self.data, 0);
            self.position = 0;
            continue;
        }
        self.end();
    }

    self.publish();
}

/// Stopped at its end, back at the start, and said.
fn end(self: *Stream) void {
    self.playing = false;
    self.reader.rewind(self.data, 0);
    self.position = 0;
    if (self.state) |state| _ = state.end_count.fetchAdd(1, .release);
}

fn publish(self: *Stream) void {
    const state = self.state orelse return;
    state.frame_at.store(@truncate(self.position), .monotonic);
    state.playing_flag.store(@intFromBool(self.playing), .release);
}
