// SPDX-License-Identifier: CC0-1.0

//! What a backend has to answer to.
//!
//! A backend is a vtable and an opaque pointer, chosen when the device is
//! made and never looked at again by anything outside `Device`. Adding one -
//! WASAPI, ALSA, OpenSL ES - is a new file that fills this table and an `Opener`
//! that says how to open it. `Device.initWith` takes any opener, so a backend
//! does not have to live in this library and nothing has to be added to
//! `Device`: the built-in ones are listed by `Device.opener`, and a program, or
//! a registry it keeps, can hold openers of its own. Nothing a program calls
//! changes.
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

    /// Never `.wav`: `Device` reads a WAVE file itself and hands over its
    /// samples as `.pcm_f32`.
    loadClip: *const fn (Impl, types.ClipDesc) Error!Loaded,
    loadOscillator: *const fn (Impl, types.OscillatorDesc) Error!Loaded,
    unloadClip: *const fn (Impl, Native) void,

    /// `output`, already resolved from `desc.output` - `null` for the
    /// master bus, otherwise another submix's own `Native` - and `start`,
    /// `desc.start` in the clip's frames.
    play: *const fn (Impl, clip: Native, output: ?Native, types.PlayDesc, start: u64) Error!Native,
    stopVoice: *const fn (Impl, Native) void,
    setVoiceVolume: *const fn (Impl, Native, f32) void,
    setVoicePan: *const fn (Impl, Native, f32) void,
    setVoicePitch: *const fn (Impl, Native, f32) void,
    setVoiceSpeed: *const fn (Impl, Native, f32) void,
    setVoiceLooping: *const fn (Impl, Native, bool) void,
    setVoicePaused: *const fn (Impl, Native, bool) void,
    /// To `frame` of the clip.
    seekVoice: *const fn (Impl, Native, frame: u64) void,
    /// Into another submix - `null` for the master bus - as it plays.
    setVoiceOutput: *const fn (Impl, Native, output: ?Native) void,
    voiceStatus: *const fn (Impl, Native) Status,

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

/// A clip a backend has made, and what it is.
pub const Loaded = struct {
    native: Native,
    info: types.ClipInfo = .{},
};

/// How a voice is doing, in its clip's frames.
pub const Status = struct {
    playing: bool = false,
    frame: u64 = 0,
    ends: u32 = 0,
};

/// What opening a backend gives back: its state, and its table.
pub const Opened = struct { Impl, *const Vtable };

/// A backend's constructor: what `Device.init` and `Device.initWith` call.
pub const Open = *const fn (gpa: Allocator, desc: types.DeviceDesc) Error!Opened;

/// A way to open a device on one backend.
///
/// It is plain data, so a program can keep them in a list, or a registry can
/// hold one per name. `Device.opener` has the ones this build brings; a backend
/// written elsewhere makes its own.
pub const Opener = struct {
    /// What it is called: "mixer", "wasapi", "coreaudio". Borrowed by every
    /// device it opens, so it has to live as long as they do.
    name: []const u8,
    /// Which of the built-in backends this is, or `.other`.
    tag: types.Backend = .other,
    open: Open,
};
