// SPDX-License-Identifier: CC0-1.0

//! Plain values a program hands to a `Device`, free of any backend.

const resources = @import("resources.zig");

pub const Clip = resources.Clip;
pub const Voice = resources.Voice;
pub const Submix = resources.Submix;

pub const Backend = enum {
    none,
    /// The mixer graph, mixing into a buffer a caller pulls by
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
    /// Web Audio, an AudioWorklet fed between the page's frames. The
    /// browser (`wasm32-wasi`) only.
    web,
    /// A backend the caller supplied to `Device.initWith`, none of the ones
    /// above. `Info.name` says which it is.
    other,
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
    /// What the backend is called: `mixer`, `wasapi` and so on, or the name a
    /// caller gave a backend of its own. `Device` fills it in, a backend need
    /// not.
    name: []const u8 = "",
};

/// How to read what is handed to `Device.loadClip`.
pub const ClipFormat = enum {
    /// `bytes`: interleaved signed 16-bit samples, of `channels` and at
    /// `sample_rate`.
    pcm_s16,
    /// `samples`: 32-bit floats, planar - one channel's in full, then the
    /// next - of `channels` and at `sample_rate`. What a program that makes
    /// its own sound hands over.
    pcm_f32,
    /// `bytes`: a RIFF WAVE file - 8, 16, 24 or 32-bit integers, or 32 or
    /// 64-bit floats - read in whole.
    wav,
    /// `bytes`: an Ogg Vorbis file, decoded as it plays.
    vorbis,
    /// `bytes`: an MP3 file, decoded as it plays. The silence an encoder puts
    /// before and after the music, when its LAME tag says how much, is left
    /// out, so a clip that loops goes round without a gap.
    mp3,
};

pub const ClipDesc = struct {
    format: ClipFormat,
    /// For every format but `.pcm_f32`: as read from disk. A file says its
    /// own channels and rate, and `channels`/`sample_rate` below are only
    /// for the raw formats.
    bytes: []const u8 = &.{},
    /// For `.pcm_f32`.
    samples: []const f32 = &.{},
    channels: u32 = 2,
    sample_rate: u32 = 44100,
};

/// What a clip is, once loaded.
pub const ClipInfo = struct {
    channels: u32 = 0,
    sample_rate: u32 = 0,
    /// How long it is, in frames: 0 for a clip with no end, and for one the
    /// backend does not decode.
    frames: u64 = 0,

    pub fn seconds(self: ClipInfo) f64 {
        if (self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

pub const PlayDesc = struct {
    volume: f32 = 1,
    pan: f32 = 0,
    /// 1 is unchanged, 0.5 is an octave down, 2 is an octave up, and the clip
    /// keeps its time. Left at 1, the pitch-shift processor is a no-op that
    /// costs nothing; away from it, a phase vocoder runs, which is not cheap.
    pitch: f32 = 1,
    /// 1 plays the clip as it was recorded; 2 twice as fast and an octave
    /// up; 0.5 half as fast and an octave down. The clip is resampled, which
    /// costs next to nothing: what a game wants for a sound that is a little
    /// different each time.
    speed: f32 = 1,
    /// From the start again at the end, rather than stopping.
    loop: bool = false,
    /// Seconds into the clip to start from.
    start: f64 = 0,
    /// Made, and held until `Device.setPaused(voice, false)`.
    paused: bool = false,
    /// Which submix this voice feeds into. `null` goes straight to the
    /// master bus, same as before submixes existed.
    output: ?Submix = null,
};

/// How a voice is doing, read on the thread that asks without waiting on
/// the one that mixes.
pub const VoiceStatus = struct {
    playing: bool = false,
    /// Seconds into its clip.
    position: f64 = 0,
    /// How many times it has come to its end and stopped: what a program
    /// compares with the count it last saw to hear that a voice has
    /// finished. A voice that loops never does.
    ends: u32 = 0,
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

/// How many frames an oscillator's `length` is, to the nearest: 0 for one
/// that plays for ever. The native side counts them the same way.
pub fn oscillatorFrames(desc: OscillatorDesc) u64 {
    if (!(desc.length > 0)) return 0;
    return @intFromFloat(@round(@as(f64, desc.length) * @as(f64, @floatFromInt(desc.sample_rate))));
}
