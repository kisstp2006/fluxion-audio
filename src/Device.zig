// SPDX-License-Identifier: CC0-1.0

//! A device: one backend, the clips loaded on it, and the voices playing.
//!
//! ```zig
//! var device = try audio.Device.init(gpa, .{});
//! defer device.deinit();
//!
//! const clip = try device.loadClip(.{ .format = .vorbis, .bytes = ogg_bytes });
//! const voice = try device.play(clip, .{ .volume = 0.8 });
//! // ...
//! device.stop(voice);
//! device.unloadClip(clip);
//! ```
//!
//! **Handles, not pointers.** Everything `loadClip` and `play` return is
//! eight bytes with a generation in them. A destroyed handle is
//! `error.InvalidHandle`, from `Device` and before the backend sees it.
//!
//! **One thread.** A device is used from the thread that made it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const resources = @import("resources.zig");
const backend = @import("backend.zig");

const is_android = builtin.target.abi == .android;
const is_linux_desktop = builtin.os.tag == .linux and !is_android;

const none_backend = @import("backend/none.zig");
const mixer_backend = @import("backend/mixer.zig");
const wasapi_backend = if (builtin.os.tag == .windows) @import("backend/wasapi.zig") else void;
const alsa_backend = if (is_linux_desktop) @import("backend/alsa.zig") else void;
const opensl_backend = if (is_android) @import("backend/opensl.zig") else void;

const Device = @This();

pub const Error = types.Error;

gpa: Allocator,
impl: backend.Impl,
vtable: *const backend.Vtable,
tag: types.Backend,
/// From the opener; borrowed.
name: []const u8,

clips: resources.ClipTable = .empty,
voices: resources.VoiceTable = .empty,
submixes: resources.SubmixTable = .empty,

/// Which backends this build could open. `.none` is always among them.
pub fn available() []const types.Backend {
    return if (builtin.os.tag == .windows)
        &.{ .none, .mixer, .wasapi }
    else if (is_linux_desktop)
        &.{ .none, .mixer, .alsa }
    else if (is_android)
        &.{ .none, .mixer, .opensl }
    else
        &.{ .none, .mixer };
}

/// How to open one of the backends this build brings, or null if it does not
/// bring it: `.wasapi` off Windows, `.alsa` off desktop Linux, `.opensl` off
/// Android, and `.other`, which is whatever a caller supplies.
///
/// A program that keeps its backends in a registry registers these by `name`.
pub fn opener(which: types.Backend) ?backend.Opener {
    return switch (which) {
        .none => .{ .name = "none", .tag = .none, .open = none_backend.open },
        .mixer => .{ .name = "mixer", .tag = .mixer, .open = mixer_backend.open },
        .wasapi => if (builtin.os.tag == .windows) .{ .name = "wasapi", .tag = .wasapi, .open = wasapi_backend.open } else null,
        .alsa => if (is_linux_desktop) .{ .name = "alsa", .tag = .alsa, .open = alsa_backend.open } else null,
        .opensl => if (is_android) .{ .name = "opensl", .tag = .opensl, .open = opensl_backend.open } else null,
        .other => null,
    };
}

/// Opens a device on the backend an opener describes: one of `opener`'s, or one
/// the caller made. `desc.backend` is not looked at, the opener has already
/// chosen. The opener's name is borrowed until `deinit`.
pub fn initWith(gpa: Allocator, desc: types.DeviceDesc, how: backend.Opener) Error!Device {
    const opened = try how.open(gpa, desc);
    return .{
        .gpa = gpa,
        .impl = opened[0],
        .vtable = opened[1],
        .tag = how.tag,
        .name = how.name,
    };
}

pub fn init(gpa: Allocator, desc: types.DeviceDesc) Error!Device {
    return initWith(gpa, desc, opener(desc.backend) orelse return error.Unsupported);
}

/// Stop everything still playing, unload everything still loaded, then the
/// backend.
pub fn deinit(self: *Device) void {
    var voices = self.voices.iterator();
    while (voices.next()) |entry| self.vtable.stopVoice(self.impl, entry.value.native);
    var submixes = self.submixes.iterator();
    while (submixes.next()) |entry| self.vtable.destroySubmix(self.impl, entry.value.native);
    var clips = self.clips.iterator();
    while (clips.next()) |entry| self.vtable.unloadClip(self.impl, entry.value.native);

    self.voices.deinit(self.gpa);
    self.submixes.deinit(self.gpa);
    self.clips.deinit(self.gpa);

    self.vtable.deinit(self.impl);
    self.* = undefined;
}

/// Which of the built-in backends this is, or `.other` for one that came from
/// `initWith`. `info().name` says which in either case.
pub fn backendTag(self: *const Device) types.Backend {
    return self.tag;
}

pub fn info(self: *const Device) types.Info {
    var answer = self.vtable.info(self.impl);
    answer.backend = self.tag;
    answer.name = self.name;
    return answer;
}

pub fn loadClip(self: *Device, desc: types.ClipDesc) Error!types.Clip {
    const native = try self.vtable.loadClip(self.impl, desc);
    errdefer self.vtable.unloadClip(self.impl, native);
    return self.clips.add(self.gpa, .{ .native = native });
}

pub fn loadOscillator(self: *Device, desc: types.OscillatorDesc) Error!types.Clip {
    const native = try self.vtable.loadOscillator(self.impl, desc);
    errdefer self.vtable.unloadClip(self.impl, native);
    return self.clips.add(self.gpa, .{ .native = native });
}

pub fn unloadClip(self: *Device, clip: types.Clip) void {
    if (self.clips.remove(clip)) |entry| self.vtable.unloadClip(self.impl, entry.native);
}

pub fn play(self: *Device, clip: types.Clip, desc: types.PlayDesc) Error!types.Voice {
    const clip_entry = self.clips.get(clip) orelse return error.InvalidHandle;
    const output_native = if (desc.output) |submix|
        (self.submixes.get(submix) orelse return error.InvalidHandle).native
    else
        null;
    const native = try self.vtable.play(self.impl, clip_entry.native, output_native, desc);
    errdefer self.vtable.stopVoice(self.impl, native);
    return self.voices.add(self.gpa, .{ .native = native });
}

pub fn stop(self: *Device, voice: types.Voice) void {
    if (self.voices.remove(voice)) |entry| self.vtable.stopVoice(self.impl, entry.native);
}

/// A bus of its own that voices (or other submixes) can be routed into
/// instead of straight to the master - a "music" bus, a "sfx" bus, each
/// with its own volume.
pub fn createSubmix(self: *Device, desc: types.SubmixDesc) Error!types.Submix {
    const output_native = if (desc.output) |submix|
        (self.submixes.get(submix) orelse return error.InvalidHandle).native
    else
        null;
    const native = try self.vtable.createSubmix(self.impl, output_native, desc.volume);
    errdefer self.vtable.destroySubmix(self.impl, native);
    return self.submixes.add(self.gpa, .{ .native = native });
}

pub fn destroySubmix(self: *Device, submix: types.Submix) void {
    if (self.submixes.remove(submix)) |entry| self.vtable.destroySubmix(self.impl, entry.native);
}

pub fn setSubmixVolume(self: *Device, submix: types.Submix, volume: f32) Error!void {
    const entry = self.submixes.get(submix) orelse return error.InvalidHandle;
    self.vtable.setSubmixVolume(self.impl, entry.native, volume);
}

pub fn setSubmixOutput(self: *Device, submix: types.Submix, output: ?types.Submix) Error!void {
    const entry = self.submixes.get(submix) orelse return error.InvalidHandle;
    const output_native = if (output) |o|
        (self.submixes.get(o) orelse return error.InvalidHandle).native
    else
        null;
    self.vtable.setSubmixOutput(self.impl, entry.native, output_native);
}

pub fn setVolume(self: *Device, voice: types.Voice, volume: f32) Error!void {
    const entry = self.voices.get(voice) orelse return error.InvalidHandle;
    self.vtable.setVoiceVolume(self.impl, entry.native, volume);
}

pub fn setPan(self: *Device, voice: types.Voice, pan: f32) Error!void {
    const entry = self.voices.get(voice) orelse return error.InvalidHandle;
    self.vtable.setVoicePan(self.impl, entry.native, pan);
}

pub fn setPitch(self: *Device, voice: types.Voice, pitch: f32) Error!void {
    const entry = self.voices.get(voice) orelse return error.InvalidHandle;
    self.vtable.setVoicePitch(self.impl, entry.native, pitch);
}

pub fn isPlaying(self: *Device, voice: types.Voice) bool {
    const entry = self.voices.get(voice) orelse return false;
    return self.vtable.isVoicePlaying(self.impl, entry.native);
}

/// Mixes `out.len / channels` frames into `out`, planar by channel: `out[0
/// .. frames]` is channel 0, `out[frames .. 2*frames]` is channel 1, and so
/// on. What a backend's output thread pulls, and what a test pulls directly.
pub fn mix(self: *Device, channels: u32, sample_rate: u32, out: []f32) void {
    self.vtable.mix(self.impl, channels, sample_rate, out);
}

// -------------------------------------------------------------------------
// Tests - on the backend that needs no sound device
// -------------------------------------------------------------------------

const testing = std.testing;

test "open and close on the none backend" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();
    try testing.expectEqual(types.Backend.none, device.backendTag());
}

test "every backend this build brings has an opener with its own name" {
    for (available()) |tag| {
        const how = opener(tag) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(@tagName(tag), how.name);
        try testing.expectEqual(tag, how.tag);
    }
    // `other` is whatever a caller makes
    try testing.expect(opener(.other) == null);
    try testing.expectError(error.Unsupported, Device.init(testing.allocator, .{ .backend = .other }));
}

test "a built-in opener opens the same device as init does" {
    var by_init = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer by_init.deinit();
    var by_opener = try Device.initWith(testing.allocator, .{}, opener(.mixer).?);
    defer by_opener.deinit();

    try testing.expectEqual(by_init.backendTag(), by_opener.backendTag());
    try testing.expectEqual(types.Backend.mixer, by_opener.backendTag());
    try testing.expectEqualStrings("mixer", by_opener.info().name);
    try testing.expectEqualStrings(by_init.info().device_name, by_opener.info().device_name);
}

test "initWith opens a backend the caller supplies, under its own name" {
    const mine: backend.Opener = .{ .name = "mine", .open = none_backend.open };

    var device = try Device.initWith(testing.allocator, .{}, mine);
    defer device.deinit();

    try testing.expectEqual(types.Backend.other, device.backendTag());
    try testing.expectEqualStrings("mine", device.info().name);
    try testing.expectEqual(types.Backend.other, device.info().backend);

    // it is a working device, not a label
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = &.{} });
    const voice = try device.play(clip, .{});
    device.stop(voice);
    device.unloadClip(clip);
    try testing.expectError(error.InvalidHandle, device.setVolume(voice, 0.5));
}

fn refuses(gpa: Allocator, desc: types.DeviceDesc) Error!backend.Opened {
    _ = .{ gpa, desc };
    return error.NoDevice;
}

test "an opener that refuses leaves nothing behind" {
    const how: backend.Opener = .{ .name = "absent", .open = refuses };
    try testing.expectError(error.NoDevice, Device.initWith(testing.allocator, .{}, how));
}

test "a clip and a voice are real, distinct handles" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();

    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = &.{} });
    const voice = try device.play(clip, .{});
    try testing.expect(!device.isPlaying(voice));

    device.stop(voice);
    device.unloadClip(clip);
}

test "a stopped voice is refused, not followed" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();

    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = &.{} });
    const voice = try device.play(clip, .{});
    device.stop(voice);

    try testing.expectError(error.InvalidHandle, device.setVolume(voice, 0.5));
    try testing.expect(!device.isPlaying(voice));
}

test "deinit cleans up whatever was left playing or loaded" {
    var device = try Device.init(testing.allocator, .{});
    const clip = try device.loadClip(.{ .format = .vorbis, .bytes = &.{} });
    _ = try device.play(clip, .{});
    // Neither the clip nor the voice was released by hand - deinit has to
    // walk both tables itself, or this leaks under the testing allocator.
    device.deinit();
}

test "a submix is a real, distinct handle a voice can play through" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();

    const music = try device.createSubmix(.{ .volume = 0.7 });
    defer device.destroySubmix(music);

    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = &.{} });
    const voice = try device.play(clip, .{ .output = music });
    defer device.stop(voice);

    try device.setSubmixVolume(music, 0.5);
}

test "submixes can chain into each other, and a stale one is refused" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();

    const master_group = try device.createSubmix(.{});
    const music = try device.createSubmix(.{ .output = master_group });
    try device.setSubmixOutput(music, master_group);

    device.destroySubmix(master_group);
    try testing.expectError(error.InvalidHandle, device.setSubmixVolume(master_group, 1.0));
    // The submix that was routed into it is unaffected - only its output
    // pointer goes stale on the native side, same as a bus losing its
    // output bus.
    try device.setSubmixVolume(music, 1.0);
}

test "deinit cleans up submixes too" {
    var device = try Device.init(testing.allocator, .{});
    _ = try device.createSubmix(.{});
    device.deinit();
}
