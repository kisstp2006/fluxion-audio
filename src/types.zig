// SPDX-License-Identifier: CC0-1.0

//! Plain values a program hands to a `Device`, free of any backend.

const resources = @import("resources.zig");

pub const Clip = resources.Clip;
pub const Voice = resources.Voice;
pub const Submix = resources.Submix;

pub const Backend = enum {
    none,
    /// The vendored mixer graph, mixing into a buffer a caller pulls by
    /// hand - what every real output backend will sit behind, and what a
    /// test that wants to check actual mixed samples opens directly.
    mixer,
    /// WASAPI in shared mode, on its own thread. Windows only.
    wasapi,
    /// ALSA's default playback device, on its own thread. Linux only,
    /// Android excepted.
    alsa,
    /// An OpenSL ES output mix, re-enqueued from its own callback. Android
    /// only.
    opensl,
};

pub const Error = error{
    /// This build or this machine has no such backend.
    Unsupported,
    /// The backend is there and refused to make a device: no driver, no
    /// output device attached.
    NoDevice,
    /// The driver stopped answering. Every voice on the device is gone.
    DeviceLost,
    /// The bytes handed to `loadClip` do not decode as the format asked for.
    DecodeFailed,
    /// A handle that was destroyed, or never made by this device.
    InvalidHandle,
    /// The driver said no and this library has no better name for why.
    Failed,
    OutOfMemory,
};

pub const DeviceDesc = struct {
    backend: Backend = .none,
    /// What a real output backend opens the sound device at. Ignored by
    /// `.none` and `.mixer`, which have no device to open.
    sample_rate: u32 = 44100,
    channels: u32 = 2,
};

pub const Info = struct {
    backend: Backend,
    device_name: []const u8,
};

/// How to read the bytes handed to `Device.loadClip`.
pub const ClipFormat = enum { pcm_s16, vorbis };

pub const ClipDesc = struct {
    format: ClipFormat,
    /// For `.pcm_s16`: interleaved samples. For `.vorbis`: an Ogg Vorbis
    /// file, exactly as read from disk - channels and sample rate come from
    /// its own header, and `channels`/`sample_rate` below are ignored.
    bytes: []const u8,
    channels: u32 = 2,
    sample_rate: u32 = 44100,
};

pub const PlayDesc = struct {
    volume: f32 = 1,
    pan: f32 = 0,
    /// 1 is unchanged, 0.5 is an octave down, 2 is an octave up. Left at 1,
    /// the pitch-shift processor is a no-op that costs nothing.
    pitch: f32 = 1,
    /// Which submix this voice feeds into. `null` goes straight to the
    /// master bus, same as before submixes existed.
    output: ?Submix = null,
};

/// A named group of voices - a "music" bus, a "sfx" bus - with its own
/// volume, feeding the master bus or another submix in turn.
pub const SubmixDesc = struct {
    volume: f32 = 1,
    output: ?Submix = null,
};

pub const OscillatorType = enum { sine, square, sawtooth, triangle };

/// A clip with no bytes behind it: a waveform generated one frame at a time
/// as it plays, for a tone with nothing to decode.
pub const OscillatorDesc = struct {
    type: OscillatorType = .sine,
    frequency: f32,
    amplitude: f32 = 0.5,
    /// Seconds before the clip finishes on its own; 0 plays forever.
    length: f32 = 0,
    sample_rate: u32 = 44100,
};
