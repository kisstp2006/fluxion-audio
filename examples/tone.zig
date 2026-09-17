// SPDX-License-Identifier: CC0-1.0

//! Plays a one-second 440Hz tone through the real output backend. Not part
//! of `zig build test` - it needs an actual sound device, and it makes
//! actual sound - so it is `zig build example-tone`, run by hand.

const std = @import("std");
const audio = @import("fluxion_audio");

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var device = try audio.Device.init(gpa, .{ .backend = .wasapi });
    defer device.deinit();

    const sample_rate: f32 = 44100;
    const seconds: f32 = 1.0;
    const frame_count: usize = @intFromFloat(sample_rate * seconds);

    const samples = try gpa.alloc(i16, frame_count);
    defer gpa.free(samples);

    var t: f32 = 0;
    for (samples) |*sample| {
        sample.* = @intFromFloat(std.math.sin(t) * 0.2 * 32767.0);
        t += 2.0 * std.math.pi * 440.0 / sample_rate;
    }

    const clip = try device.loadClip(.{
        .format = .pcm_s16,
        .bytes = std.mem.sliceAsBytes(samples),
        .channels = 1,
        .sample_rate = @intFromFloat(sample_rate),
    });
    defer device.unloadClip(clip);

    std.debug.print("playing a 440Hz tone for one second...\n", .{});
    const voice = try device.play(clip, .{ .volume = 1.0 });
    defer device.stop(voice);

    Sleep(@intFromFloat(seconds * 1000));
    std.debug.print("done\n", .{});
}
