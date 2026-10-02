// SPDX-License-Identifier: CC0-1.0

//! The browser's output backend: a Web Audio AudioWorklet, played from
//! what the mixer gives. It is the `mixer` backend with this attached as its
//! `Output`, as `wasapi.zig` is.
//!
//! A page runs the program on one thread, so nothing here pulls on a thread
//! of its own: `web.js` (installed as `fluxion-audio.js`) calls
//! `fluxion_audio_pull` between the page's frames, whenever the worklet has
//! less queued than it wants, and sends what it gets to the worklet. It is
//! JavaScript that opens the sound card and keeps it fed; this file is the
//! buffer it is fed from.
//!
//! The browser target is `wasm32-wasi`: the decoders are C, and want a C
//! library.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const mixer_backend = @import("mixer.zig");

/// The most frames one pull mixes. `web.js` asks for no more (`MAX_FRAMES`).
const max_frames = 4096;

const glue = struct {
    /// An output of `channels` - fewer if the page's sound card has fewer -
    /// that pulls from `web`, or 0 if this browser has no Web Audio.
    extern "fluxion_audio" fn open(web: *Web, channels: u32) u32;
    extern "fluxion_audio" fn channels(output: u32) u32;
    extern "fluxion_audio" fn sampleRate(output: u32) u32;
    extern "fluxion_audio" fn close(output: u32) void;
};

const Web = struct {
    gpa: Allocator,
    mixer: backend.Impl,
    output: u32 = 0,
    channels: u32,
    sample_rate: u32 = 0,
    /// `max_frames` of `channels`, planar: where a pull mixes to.
    samples: []f32,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    const opened = try mixer_backend.open(gpa, desc);
    errdefer opened[1].deinit(opened[0]);

    const self = try gpa.create(Web);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .mixer = opened[0], .channels = 0, .samples = &.{} };

    const output = glue.open(self, if (desc.channels != 0) desc.channels else 2);
    if (output == 0) return error.NoDevice;
    errdefer glue.close(output);
    self.output = output;
    self.channels = glue.channels(output);
    self.sample_rate = glue.sampleRate(output);
    self.samples = try gpa.alloc(f32, max_frames * self.channels);

    mixer_backend.attach(opened[0], .{
        .context = self,
        .close = close,
        .info = .{ .backend = .web, .device_name = "Web Audio" },
    });
    return opened;
}

fn close(context: *anyopaque) void {
    const self: *Web = @ptrCast(@alignCast(context));
    glue.close(self.output);
    self.gpa.free(self.samples);
    self.gpa.destroy(self);
}

/// `frames` frames mixed - at most `max_frames` - and where they are: one
/// channel's in full, then the next. Called by `web.js` between the
/// program's own calls (or while it waits for a frame), never in the middle
/// of one.
export fn fluxion_audio_pull(web: *Web, frames: u32) [*]f32 {
    const out = web.samples[0 .. @min(frames, max_frames) * web.channels];
    mixer_backend.pull(web.mixer, web.channels, web.sample_rate, out);
    return out.ptr;
}
