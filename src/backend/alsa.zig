// SPDX-License-Identifier: CC0-1.0

//! The Linux output backend: ALSA, on its own thread, owned entirely by the
//! vendored C++ in `native/backends/alsa.cpp` rather than by this file -
//! unlike `wasapi.zig`, there is no Zig-side loop here at all. Composes the
//! `mixer` backend for every clip/voice call, same as `wasapi.zig` does.
//!
//! Untested on this machine: there is no ALSA here to open. Building this
//! file only proves it compiles against the vendored headers, not that it
//! plays anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const mixer_backend = @import("mixer.zig");
const native = @import("../native.zig");
const c = native.c;

const Alsa = struct {
    gpa: Allocator,
    inner_impl: backend.Impl,
    inner_vtable: *const backend.Vtable,
    output: *c.fx_audio_output,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    const inner = try mixer_backend.open(gpa, desc);
    const mixer_handle = mixer_backend.handleOf(inner[0]);

    var channels: u32 = desc.channels;
    var sample_rate: u32 = desc.sample_rate;
    const output = c.fx_audio_alsa_open(mixer_handle, &channels, &sample_rate) orelse {
        inner[1].deinit(inner[0]);
        return error.NoDevice;
    };

    const self = try gpa.create(Alsa);
    self.* = .{ .gpa = gpa, .inner_impl = inner[0], .inner_vtable = inner[1], .output = output };
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
    .isVoicePlaying = isVoicePlaying,
    .createSubmix = createSubmix,
    .destroySubmix = destroySubmix,
    .setSubmixVolume = setSubmixVolume,
    .setSubmixOutput = setSubmixOutput,
    .mix = mixUnused,
};

fn cast(impl: backend.Impl) *Alsa {
    return @ptrCast(@alignCast(impl));
}

fn deinit(impl: backend.Impl) void {
    const self = cast(impl);
    c.fx_audio_alsa_close(self.output);
    self.inner_vtable.deinit(self.inner_impl);
    self.gpa.destroy(self);
}

fn info(impl: backend.Impl) types.Info {
    _ = impl;
    return .{ .backend = .alsa, .device_name = "ALSA default playback device" };
}

fn loadClip(impl: backend.Impl, desc: types.ClipDesc) backend.Error!backend.Native {
    const self = cast(impl);
    return self.inner_vtable.loadClip(self.inner_impl, desc);
}

fn loadOscillator(impl: backend.Impl, desc: types.OscillatorDesc) backend.Error!backend.Native {
    const self = cast(impl);
    return self.inner_vtable.loadOscillator(self.inner_impl, desc);
}

fn unloadClip(impl: backend.Impl, native_clip: backend.Native) void {
    const self = cast(impl);
    self.inner_vtable.unloadClip(self.inner_impl, native_clip);
}

fn play(impl: backend.Impl, clip: backend.Native, output: ?backend.Native, desc: types.PlayDesc) backend.Error!backend.Native {
    const self = cast(impl);
    return self.inner_vtable.play(self.inner_impl, clip, output, desc);
}

fn stopVoice(impl: backend.Impl, native_voice: backend.Native) void {
    const self = cast(impl);
    self.inner_vtable.stopVoice(self.inner_impl, native_voice);
}

fn setVoiceVolume(impl: backend.Impl, native_voice: backend.Native, volume: f32) void {
    const self = cast(impl);
    self.inner_vtable.setVoiceVolume(self.inner_impl, native_voice, volume);
}

fn setVoicePan(impl: backend.Impl, native_voice: backend.Native, pan: f32) void {
    const self = cast(impl);
    self.inner_vtable.setVoicePan(self.inner_impl, native_voice, pan);
}

fn setVoicePitch(impl: backend.Impl, native_voice: backend.Native, pitch: f32) void {
    const self = cast(impl);
    self.inner_vtable.setVoicePitch(self.inner_impl, native_voice, pitch);
}

fn isVoicePlaying(impl: backend.Impl, native_voice: backend.Native) bool {
    const self = cast(impl);
    return self.inner_vtable.isVoicePlaying(self.inner_impl, native_voice);
}

fn createSubmix(impl: backend.Impl, output: ?backend.Native, volume: f32) backend.Error!backend.Native {
    const self = cast(impl);
    return self.inner_vtable.createSubmix(self.inner_impl, output, volume);
}

fn destroySubmix(impl: backend.Impl, native_submix: backend.Native) void {
    const self = cast(impl);
    self.inner_vtable.destroySubmix(self.inner_impl, native_submix);
}

fn setSubmixVolume(impl: backend.Impl, native_submix: backend.Native, volume: f32) void {
    const self = cast(impl);
    self.inner_vtable.setSubmixVolume(self.inner_impl, native_submix, volume);
}

fn setSubmixOutput(impl: backend.Impl, native_submix: backend.Native, output: ?backend.Native) void {
    const self = cast(impl);
    self.inner_vtable.setSubmixOutput(self.inner_impl, native_submix, output);
}

/// See `wasapi.zig`'s `mixUnused` - the native output thread already owns
/// pulling from the wrapped `mixer` backend.
fn mixUnused(impl: backend.Impl, channels: u32, sample_rate: u32, out: []f32) void {
    _ = impl;
    _ = channels;
    _ = sample_rate;
    _ = out;
}
