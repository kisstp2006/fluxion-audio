// SPDX-License-Identifier: CC0-1.0

//! The two decoders the mixer reads compressed clips with, as C: stb_vorbis
//! for Ogg Vorbis and minimp3 for MP3, both vendored in `native/third_party`
//! and compiled from `native/vorbis.c` and `native/mp3.c`. Only their
//! declarations come in
//! here; neither is given a file, only bytes already in memory.

pub const c = @cImport({
    @cDefine("STB_VORBIS_HEADER_ONLY", "1");
    @cDefine("STB_VORBIS_NO_STDIO", "1");
    @cInclude("third_party/stb_vorbis.c");
    @cDefine("MINIMP3_FLOAT_OUTPUT", "1");
    @cInclude("third_party/minimp3.h");
});

/// The most samples one MPEG frame decodes to, every channel together.
pub const mp3_max_samples = 1152 * 2;
