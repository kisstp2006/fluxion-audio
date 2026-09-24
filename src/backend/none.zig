// SPDX-License-Identifier: CC0-1.0

//! The backend that plays nothing.
//!
//! Every call succeeds, every clip and voice is a real handle, and no voice
//! is ever reported as playing - there is nothing behind it to finish. What
//! it is for:
//!
//!   * a test of audio-triggering code on a machine with no sound device,
//!     which is every build server;
//!   * a headless server that shares code with a client;
//!   * checking that a real backend's absence is an ordinary condition and
//!     not a crash.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");

const None = struct {
    gpa: Allocator,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    _ = desc;
    const self = try gpa.create(None);
    self.* = .{ .gpa = gpa };
    return .{ self, &vtable };
}

const vtable: backend.Vtable = .{
    .deinit = deinit,
    .info = info,
    .loadClip = loadClip,
    .loadOscillator = loadOscillator,
    .unloadClip = unloadClip,
    .play = play,
    .stopVoice = stopVoice,
    .setVoiceVolume = setVoiceVolume,
    .setVoicePan = setVoicePan,
    .setVoicePitch = setVoicePitch,
    .setVoiceSpeed = setVoiceSpeed,
    .setVoiceLooping = setVoiceLooping,
    .setVoicePaused = setVoicePaused,
    .seekVoice = seekVoice,
    .voiceStatus = voiceStatus,
    .createSubmix = createSubmix,
    .destroySubmix = destroySubmix,
    .setSubmixVolume = setSubmixVolume,
    .setSubmixOutput = setSubmixOutput,
    .mix = mix,
};

fn cast(impl: backend.Impl) *None {
    return @ptrCast(@alignCast(impl));
}

fn deinit(impl: backend.Impl) void {
    const self = cast(impl);
    self.gpa.destroy(self);
}

fn info(impl: backend.Impl) types.Info {
    _ = impl;
    return .{ .backend = .none, .device_name = "nothing at all" };
}

// A clip and a voice both need to be a real, distinct pointer - not merely
// present - so a use-after-destroy would at least be a use of freed memory
// rather than of a handle that was never backed by anything.
const Placeholder = struct {};

/// Nothing is decoded: what a raw clip is is known from its desc, and an
/// encoded one says nothing.
fn loadClip(impl: backend.Impl, desc: types.ClipDesc) backend.Error!backend.Loaded {
    const native: backend.Native = @ptrCast(try cast(impl).gpa.create(Placeholder));
    const frames: u64 = switch (desc.format) {
        .pcm_s16 => if (desc.channels == 0) 0 else desc.bytes.len / 2 / desc.channels,
        .pcm_f32 => if (desc.channels == 0) 0 else desc.samples.len / desc.channels,
        .wav, .vorbis, .mp3 => return .{ .native = native },
    };
    return .{ .native = native, .info = .{ .channels = desc.channels, .sample_rate = desc.sample_rate, .frames = frames } };
}

fn loadOscillator(impl: backend.Impl, desc: types.OscillatorDesc) backend.Error!backend.Loaded {
    const native: backend.Native = @ptrCast(try cast(impl).gpa.create(Placeholder));
    return .{ .native = native, .info = .{ .channels = 1, .sample_rate = desc.sample_rate, .frames = types.oscillatorFrames(desc) } };
}

fn unloadClip(impl: backend.Impl, native: backend.Native) void {
    cast(impl).gpa.destroy(@as(*Placeholder, @ptrCast(@alignCast(native))));
}

fn play(impl: backend.Impl, clip: backend.Native, output: ?backend.Native, desc: types.PlayDesc, start: u64) backend.Error!backend.Native {
    _ = .{ clip, output, desc, start };
    return @ptrCast(try cast(impl).gpa.create(Placeholder));
}

fn stopVoice(impl: backend.Impl, native: backend.Native) void {
    cast(impl).gpa.destroy(@as(*Placeholder, @ptrCast(@alignCast(native))));
}

fn setVoiceVolume(impl: backend.Impl, native: backend.Native, volume: f32) void {
    _ = impl;
    _ = native;
    _ = volume;
}

fn setVoicePan(impl: backend.Impl, native: backend.Native, pan: f32) void {
    _ = impl;
    _ = native;
    _ = pan;
}

fn setVoicePitch(impl: backend.Impl, native: backend.Native, pitch: f32) void {
    _ = impl;
    _ = native;
    _ = pitch;
}

fn setVoiceSpeed(impl: backend.Impl, native: backend.Native, speed: f32) void {
    _ = .{ impl, native, speed };
}

fn setVoiceLooping(impl: backend.Impl, native: backend.Native, looping: bool) void {
    _ = .{ impl, native, looping };
}

fn setVoicePaused(impl: backend.Impl, native: backend.Native, paused: bool) void {
    _ = .{ impl, native, paused };
}

fn seekVoice(impl: backend.Impl, native: backend.Native, frame: u64) void {
    _ = .{ impl, native, frame };
}

/// Never playing: there is nothing behind a voice to play.
fn voiceStatus(impl: backend.Impl, native: backend.Native) backend.Status {
    _ = .{ impl, native };
    return .{};
}

fn createSubmix(impl: backend.Impl, output: ?backend.Native, volume: f32) backend.Error!backend.Native {
    _ = output;
    _ = volume;
    return @ptrCast(try cast(impl).gpa.create(Placeholder));
}

fn destroySubmix(impl: backend.Impl, native: backend.Native) void {
    cast(impl).gpa.destroy(@as(*Placeholder, @ptrCast(@alignCast(native))));
}

fn setSubmixVolume(impl: backend.Impl, native: backend.Native, volume: f32) void {
    _ = impl;
    _ = native;
    _ = volume;
}

fn setSubmixOutput(impl: backend.Impl, native: backend.Native, output: ?backend.Native) void {
    _ = impl;
    _ = native;
    _ = output;
}

fn mix(impl: backend.Impl, channels: u32, sample_rate: u32, out: []f32) void {
    _ = impl;
    _ = channels;
    _ = sample_rate;
    @memset(out, 0);
}
