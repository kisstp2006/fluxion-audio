// SPDX-License-Identifier: CC0-1.0

//! The Linux output backend: ALSA, on its own thread, owned entirely by the
//! vendored C++ in `native/backends/alsa.cpp` rather than by this file -
//! unlike `wasapi.zig`, there is no Zig-side loop here at all. It is the
//! `mixer` backend with this attached as its `Output`, as `wasapi.zig` is.
//!
//! Untested on this machine: there is no ALSA here to open. Building this
//! file only proves it compiles against the vendored headers, not that it
//! plays anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const mixer_backend = @import("mixer.zig");
const c = @cImport(@cInclude("output.h"));

const Alsa = struct {
    gpa: Allocator,
    output: *c.fx_audio_output,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    const opened = try mixer_backend.open(gpa, desc);
    errdefer opened[1].deinit(opened[0]);

    var channels: u32 = desc.channels;
    var sample_rate: u32 = desc.sample_rate;
    const output = c.fx_audio_alsa_open(mixer_backend.pullFromC, opened[0], &channels, &sample_rate) orelse
        return error.NoDevice;
    errdefer c.fx_audio_alsa_close(output);

    const self = try gpa.create(Alsa);
    self.* = .{ .gpa = gpa, .output = output };
    mixer_backend.attach(opened[0], .{
        .context = self,
        .close = close,
        .info = .{ .backend = .alsa, .device_name = "ALSA default playback device" },
    });
    return opened;
}

fn close(context: *anyopaque) void {
    const self: *Alsa = @ptrCast(@alignCast(context));
    c.fx_audio_alsa_close(self.output);
    self.gpa.destroy(self);
}
