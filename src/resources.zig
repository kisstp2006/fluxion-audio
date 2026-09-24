// SPDX-License-Identifier: CC0-1.0

//! What a device keeps about each clip and voice, and the handles a program
//! holds instead.
//!
//! A handle is eight bytes from `fluxion-id`: an index and a generation. A
//! stale one - destroyed, or never made by this device - answers
//! `error.InvalidHandle` rather than the wrong sound. The backend's own
//! object sits behind `native`, and nothing outside the backend knows what
//! it is.

const ids = @import("fluxion_id");
const types = @import("types.zig");

pub const ClipEntry = struct {
    native: *anyopaque,
    info: types.ClipInfo,
};

pub const VoiceEntry = struct {
    native: *anyopaque,
    /// What it plays, and so the rate its frames are counted at.
    clip: Clip,
    sample_rate: u32,
};

pub const SubmixEntry = struct {
    native: *anyopaque,
};

pub const Clip = ids.handle.Handle(ClipEntry);
pub const Voice = ids.handle.Handle(VoiceEntry);
pub const Submix = ids.handle.Handle(SubmixEntry);

pub const ClipTable = ids.handle.Table(ClipEntry);
pub const VoiceTable = ids.handle.Table(VoiceEntry);
pub const SubmixTable = ids.handle.Table(SubmixEntry);
