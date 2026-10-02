// SPDX-License-Identifier: CC0-1.0

//! The Android output backend: OpenSL ES, re-enqueuing on its own callback
//! rather than a Zig-owned loop. It is the `mixer` backend with this
//! attached as its `Output`, as `alsa.zig` and `wasapi.zig` are.
//!
//! Untested on this machine: there is no Android runtime here. Building
//! this file only proves it compiles against the vendored headers, not
//! that it plays anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const mixer_backend = @import("mixer.zig");
const c = @cImport(@cInclude("output.h"));

const OpenSl = struct {
    gpa: Allocator,
    output: *c.fx_audio_output,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    const opened = try mixer_backend.open(gpa, desc);
    errdefer opened[1].deinit(opened[0]);

    var channels: u32 = desc.channels;
    var sample_rate: u32 = desc.sample_rate;
    const output = c.fx_audio_opensl_open(mixer_backend.pullFromC, opened[0], &channels, &sample_rate) orelse
        return error.NoDevice;
    errdefer c.fx_audio_opensl_close(output);

    const self = try gpa.create(OpenSl);
    self.* = .{ .gpa = gpa, .output = output };
    mixer_backend.attach(opened[0], .{
        .context = self,
        .close = close,
        .info = .{ .backend = .opensl, .device_name = "OpenSL ES output mix" },
    });
    return opened;
}

fn close(context: *anyopaque) void {
    const self: *OpenSl = @ptrCast(@alignCast(context));
    c.fx_audio_opensl_close(self.output);
    self.gpa.destroy(self);
}
