// SPDX-License-Identifier: CC0-1.0

//! The Linux output backend: ALSA, on its own thread, owned entirely by the
//! vendored C++ in `native/backends/alsa.cpp` rather than by this file -
//! unlike `wasapi.zig`, there is no Zig-side loop here at all. It is the
//! `mixer` backend with this attached as its `Output`, as `wasapi.zig` is.
//! The test below plays on whatever the default device is - the null device
//! under WSL, which takes sound as fast as it is given and so is the one a
//! clock has to pace - and skips itself where ALSA will not open.

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

// -------------------------------------------------------------------------
// Tests - on this machine's default device, when ALSA opens one
// -------------------------------------------------------------------------

const testing = std.testing;
const Device = @import("../Device.zig");

test "a voice on the default device moves on with the clock, and no further ahead of it than a buffer" {
    var device = Device.init(testing.allocator, .{ .backend = .alsa }) catch return error.SkipZigTest;
    defer device.deinit();
    try testing.expectEqual(types.Backend.alsa, device.info().backend);

    // Four seconds of silence, so nothing is heard.
    const silence = [_]i16{0} ** (44100 * 4);
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(&silence), .channels = 1 });
    const voice = try device.play(clip, .{});
    try std.Io.sleep(testing.io, .fromMilliseconds(300), .awake);
    const status = device.status(voice);
    try testing.expect(status.playing);
    try testing.expect(status.position > 0.1 and status.position < 1);
    device.stop(voice);
}
