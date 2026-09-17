// SPDX-License-Identifier: CC0-1.0

//! Fluxion Audio - clips, voices, and one mixer graph underneath, on
//! whichever sound API the machine has.
//!
//! A device opens a backend, decodes and mixes through it, and hands a
//! program nothing but handles: load a clip, play it, get a voice back, stop
//! the voice when it is done. A second backend, `none`, opens on every
//! machine and plays nothing, for the tests that need no sound device.
//!
//!   `Device`     one backend, the clips loaded on it, and the voices playing
//!   `types`      everything a program says to a device, backend-free
//!   `backend`    what a backend has to answer to - the seam a new one is written against
//!
//! ```zig
//! const audio = @import("fluxion_audio");
//!
//! var device = try audio.Device.init(gpa, .{});
//! defer device.deinit();
//!
//! const clip = try device.loadClip(.{ .format = .vorbis, .bytes = ogg_bytes });
//! const voice = try device.play(clip, .{ .volume = 0.8 });
//! defer device.stop(voice);
//! ```
//!
//! Nothing here allocates except through the allocator handed to
//! `Device.init`, and nothing here opens a file - `loadClip` takes bytes a
//! caller has already read.

pub const types = @import("types.zig");
pub const backend = @import("backend.zig");
pub const resources = @import("resources.zig");

pub const Device = @import("Device.zig");

pub const Backend = types.Backend;
pub const Error = types.Error;
pub const Info = types.Info;
pub const DeviceDesc = types.DeviceDesc;
pub const ClipFormat = types.ClipFormat;
pub const ClipDesc = types.ClipDesc;
pub const OscillatorType = types.OscillatorType;
pub const OscillatorDesc = types.OscillatorDesc;
pub const PlayDesc = types.PlayDesc;
pub const Clip = types.Clip;
pub const Voice = types.Voice;
pub const Submix = types.Submix;
pub const SubmixDesc = types.SubmixDesc;

/// Which backends this build could open. See `Device.available`.
pub const available = Device.available;

test {
    _ = types;
    _ = backend;
    _ = resources;
    _ = Device;
    _ = @import("backend/none.zig");
    _ = @import("backend/mixer.zig");
}
