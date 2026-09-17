// SPDX-License-Identifier: CC0-1.0

//! What a backend has to answer to.
//!
//! A backend is a vtable and an opaque pointer, chosen when the device is
//! made and never looked at again by anything outside `Device`. Adding one -
//! WASAPI, ALSA, OpenSL ES - is a new file under `backend/` that fills this
//! table, and one more arm in `Device.init`. Nothing a program calls changes.
//!
//! `native` is whatever the backend allocated for a clip or a voice; `Device`
//! stores it behind a handle and hands it back on every call.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

pub const Impl = *anyopaque;
pub const Native = *anyopaque;
pub const Error = types.Error;

pub const Vtable = struct {
    deinit: *const fn (Impl) void,
    info: *const fn (Impl) types.Info,

    loadClip: *const fn (Impl, types.ClipDesc) Error!Native,
    loadOscillator: *const fn (Impl, types.OscillatorDesc) Error!Native,
    unloadClip: *const fn (Impl, Native) void,

    /// `output`, already resolved from `desc.output` - `null` for the
    /// master bus, otherwise another submix's own `Native`.
    play: *const fn (Impl, clip: Native, output: ?Native, types.PlayDesc) Error!Native,
    stopVoice: *const fn (Impl, Native) void,
    setVoiceVolume: *const fn (Impl, Native, f32) void,
    setVoicePan: *const fn (Impl, Native, f32) void,
    setVoicePitch: *const fn (Impl, Native, f32) void,
    isVoicePlaying: *const fn (Impl, Native) bool,

    /// A bus of its own, feeding `output` (`null` for the master bus) -
    /// what a voice or another submix can be routed into instead of
    /// straight to the master.
    createSubmix: *const fn (Impl, output: ?Native, volume: f32) Error!Native,
    destroySubmix: *const fn (Impl, Native) void,
    setSubmixVolume: *const fn (Impl, Native, f32) void,
    setSubmixOutput: *const fn (Impl, Native, output: ?Native) void,

    /// Mixes `out.len / channels` frames into `out`, planar by channel. What
    /// a real backend calls on its own output thread; what a test calls
    /// directly to check the graph without any sound device at all.
    mix: *const fn (Impl, channels: u32, sample_rate: u32, out: []f32) void,
};

/// A backend's constructor: what `Device.init` calls.
pub const Open = *const fn (gpa: Allocator, desc: types.DeviceDesc) Error!struct { Impl, *const Vtable };
