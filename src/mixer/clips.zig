// SPDX-License-Identifier: CC0-1.0

//! What a clip is - `Data`: channels, a sample rate, a length, and the
//! samples or the bytes behind them - and a place being read in one, a
//! `Reader`, which is what a `Stream` playing it keeps. Four kinds: samples
//! in memory, a waveform made as it plays, and Ogg Vorbis and MP3 decoded as
//! they play from the file's bytes, so a long piece of music is never all
//! samples at once.
//!
//! A reader hands over up to `count` frames from where it is, channel `c`'s
//! frame `i` at `out[c * stride + offset + i]` - fewer only at the end - and
//! goes back to any frame. Coming to the end, going round again and saying
//! so are the stream's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const decoders = @import("decoders.zig");
const c = decoders.c;
const types = @import("../types.zig");

pub const Data = struct {
    channels: u32,
    sample_rate: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        /// One channel's samples in full, then the next: the shape the mixer
        /// works in.
        pcm: []f32,
        oscillator: Oscillator,
        vorbis: Vorbis,
        mp3: Mp3,
    };

    pub const Oscillator = struct {
        type: types.OscillatorType,
        frequency: f32,
        amplitude: f32,
        /// 0 for one that plays for ever.
        frames: u64,
    };

    pub const Vorbis = struct {
        encoded: []u8,
        frames: u64,
    };

    pub const Mp3 = struct {
        encoded: []u8,
        index: []Mp3Frame,
        /// Frames of sound before the music: the encoder's delay.
        skip: u64,
        /// Frames of the music itself.
        music: u64,
    };

    /// `planar`, copied.
    pub fn initPcm(gpa: Allocator, channels: u32, sample_rate: u32, planar: []const f32) Allocator.Error!*Data {
        const samples = try gpa.dupe(f32, planar);
        errdefer gpa.free(samples);
        const self = try gpa.create(Data);
        self.* = .{ .channels = channels, .sample_rate = sample_rate, .kind = .{ .pcm = samples } };
        return self;
    }

    pub fn initOscillator(gpa: Allocator, desc: types.OscillatorDesc) Allocator.Error!*Data {
        const self = try gpa.create(Data);
        self.* = .{ .channels = 1, .sample_rate = desc.sample_rate, .kind = .{ .oscillator = .{
            .type = desc.type,
            .frequency = desc.frequency,
            .amplitude = desc.amplitude,
            .frames = types.oscillatorFrames(desc),
        } } };
        return self;
    }

    /// The file's bytes, copied, and what they say of the clip.
    pub fn initVorbis(gpa: Allocator, bytes: []const u8) types.Error!*Data {
        if (bytes.len > std.math.maxInt(c_int)) return error.DecodeFailed;
        const encoded = try gpa.dupe(u8, bytes);
        errdefer gpa.free(encoded);
        const vorbis = c.stb_vorbis_open_memory(encoded.ptr, @intCast(encoded.len), null, null) orelse return error.DecodeFailed;
        defer c.stb_vorbis_close(vorbis);
        const info = c.stb_vorbis_get_info(vorbis);
        if (info.channels <= 0) return error.DecodeFailed;
        const self = try gpa.create(Data);
        self.* = .{ .channels = @intCast(info.channels), .sample_rate = info.sample_rate, .kind = .{ .vorbis = .{
            .encoded = encoded,
            .frames = c.stb_vorbis_stream_length_in_samples(vorbis),
        } } };
        return self;
    }

    /// The file's bytes, copied, and an index of its MPEG frames: which of
    /// the clip's frames of sound each holds, for a seek to start decoding
    /// near the place asked for. The encoder's delay and padding, as a LAME
    /// tag says them, are left out, so a clip that loops goes round without a
    /// gap.
    pub fn initMp3(gpa: Allocator, bytes: []const u8) types.Error!*Data {
        const encoded = try gpa.dupe(u8, bytes);
        errdefer gpa.free(encoded);
        var index: std.ArrayList(Mp3Frame) = .empty;
        errdefer index.deinit(gpa);

        var decoder: c.mp3dec_t = undefined;
        c.mp3dec_init(&decoder);
        var at: usize = 0;
        var total: u64 = 0;
        var gaps: Gaps = .{};
        var first = true;
        var channels: u32 = 0;
        var sample_rate: u32 = 0;
        while (at < encoded.len) {
            var info: c.mp3dec_frame_info_t = std.mem.zeroes(c.mp3dec_frame_info_t);
            const remaining: c_int = @intCast(@min(encoded.len - at, std.math.maxInt(c_int)));
            const count = c.mp3dec_decode_frame(&decoder, encoded.ptr + at, remaining, null, &info);
            if (info.frame_bytes == 0) break;
            if (count > 0) {
                const start = at + @as(usize, @intCast(info.frame_offset));
                const length: usize = @intCast(info.frame_bytes - info.frame_offset);
                // A first frame that only says how the file was encoded is
                // no sound.
                const tag = first and tagOf(encoded[start..][0..@min(length, encoded.len - start)], &gaps);
                first = false;
                if (tag) {
                    channels = @intCast(info.channels);
                    sample_rate = @intCast(info.hz);
                    at += @intCast(info.frame_bytes);
                    continue;
                }
                if (index.items.len == 0 and channels == 0) {
                    channels = @intCast(info.channels);
                    sample_rate = @intCast(info.hz);
                }
                try index.append(gpa, .{ .offset = start, .first = total, .count = @intCast(count) });
                total += @intCast(count);
            }
            at += @intCast(info.frame_bytes);
        }
        if (index.items.len == 0 or channels == 0) return error.DecodeFailed;

        const skip = @min(@as(u64, gaps.delay), total);
        const end = total - @min(@as(u64, gaps.padding), total - skip);
        const owned = try index.toOwnedSlice(gpa);
        errdefer gpa.free(owned);
        const self = try gpa.create(Data);
        self.* = .{ .channels = channels, .sample_rate = sample_rate, .kind = .{ .mp3 = .{
            .encoded = encoded,
            .index = owned,
            .skip = skip,
            .music = end - skip,
        } } };
        return self;
    }

    pub fn destroy(self: *Data, gpa: Allocator) void {
        switch (self.kind) {
            .pcm => |samples| gpa.free(samples),
            .oscillator => {},
            .vorbis => |vorbis| gpa.free(vorbis.encoded),
            .mp3 => |mp3| {
                gpa.free(mp3.encoded);
                gpa.free(mp3.index);
            },
        }
        gpa.destroy(self);
    }

    /// How many frames it has: 0 for one with no end.
    pub fn frames(self: *const Data) u64 {
        return switch (self.kind) {
            .pcm => |samples| if (self.channels == 0) 0 else samples.len / self.channels,
            .oscillator => |oscillator| oscillator.frames,
            .vorbis => |vorbis| vorbis.frames,
            .mp3 => |mp3| mp3.music,
        };
    }

    /// A reader at its start.
    pub fn reader(self: *Data, gpa: Allocator) Allocator.Error!Reader {
        return switch (self.kind) {
            .pcm => .{ .pcm = 0 },
            .oscillator => .{ .oscillator = 0 },
            .vorbis => |vorbis| .{ .vorbis = try VorbisReader.init(gpa, self.channels, vorbis) },
            .mp3 => blk: {
                const mp3 = try gpa.create(Mp3Reader);
                mp3.* = .{};
                mp3.rewind(self, 0);
                break :blk .{ .mp3 = mp3 };
            },
        };
    }
};

/// One MPEG frame of an MP3 file: where it is, and which of the clip's
/// frames of sound it holds.
pub const Mp3Frame = struct {
    offset: usize,
    first: u64,
    count: u32,
};

/// The frames of sound an encoder put before the music and after it.
const Gaps = struct {
    delay: u32 = 0,
    padding: u32 = 0,
};

/// Whether `frame` is a first frame that only says how the file was
/// encoded - a Xing or Info header - and what its LAME tag says of the gaps.
fn tagOf(frame: []const u8, gaps: *Gaps) bool {
    if (frame.len < 4) return false;
    const mpeg1 = frame[1] & 0x08 != 0;
    const mono = frame[3] & 0xC0 == 0xC0;
    const crc = frame[1] & 0x01 == 0;
    var at: usize = 4 + @as(usize, if (crc) 2 else 0) + @as(usize, if (mpeg1) (if (mono) 17 else 32) else (if (mono) 9 else 17));
    if (at + 8 > frame.len) return false;
    if (!std.mem.eql(u8, frame[at..][0..4], "Xing") and !std.mem.eql(u8, frame[at..][0..4], "Info")) return false;
    const flags = std.mem.readInt(u32, frame[at + 4 ..][0..4], .big);
    at += 8;
    if (flags & 1 != 0) at += 4;
    if (flags & 2 != 0) at += 4;
    if (flags & 4 != 0) at += 100;
    if (flags & 8 != 0) at += 4;
    gaps.* = .{};
    // The encoder's tag - LAME's, or one laid out as it is - after the
    // table: the delay and the padding, twelve bits each.
    if (at + 24 <= frame.len and frame[at] != 0) {
        const tag = frame[at + 21 ..];
        const delay = ((@as(i32, tag[0]) << 4) | (tag[1] >> 4)) + 529;
        const padding = ((@as(i32, tag[1] & 0x0F) << 8) | tag[2]) - 529;
        gaps.delay = @intCast(@max(delay, 0));
        gaps.padding = @intCast(@max(padding, 0));
    }
    return true;
}

/// A place in a clip, as a stream playing it keeps it.
pub const Reader = union(enum) {
    pcm: u64,
    oscillator: u64,
    vorbis: VorbisReader,
    mp3: *Mp3Reader,

    pub fn deinit(self: *Reader, gpa: Allocator) void {
        switch (self.*) {
            .pcm, .oscillator => {},
            .vorbis => |*vorbis| vorbis.deinit(gpa),
            .mp3 => |mp3| gpa.destroy(mp3),
        }
    }

    /// Up to `count` frames from where it is, channel `c`'s frame `i` at
    /// `out[c * stride + offset + i]`. Fewer only at the end.
    pub fn read(self: *Reader, data: *const Data, out: []f32, stride: u32, offset: u32, count: u32) u32 {
        switch (self.*) {
            .pcm => |*cursor| {
                const source = data.kind.pcm;
                const total = data.frames();
                if (cursor.* >= total) return 0;
                const taken: u32 = @intCast(@min(@as(u64, count), total - cursor.*));
                for (0..data.channels) |channel| {
                    const from: usize = @intCast(channel * total + cursor.*);
                    const to = channel * stride + offset;
                    @memcpy(out[to..][0..taken], source[from..][0..taken]);
                }
                cursor.* += taken;
                return taken;
            },
            .oscillator => |*cursor| {
                const oscillator = data.kind.oscillator;
                const rate: f32 = @floatFromInt(data.sample_rate);
                var written: u32 = 0;
                while (written < count and (oscillator.frames == 0 or cursor.* < oscillator.frames)) {
                    const cycles = @as(f32, @floatFromInt(cursor.*)) * oscillator.frequency / rate;
                    const phase = cycles - @floor(cycles);
                    out[offset + written] = waveAt(oscillator.type, phase) * oscillator.amplitude;
                    cursor.* += 1;
                    written += 1;
                }
                return written;
            },
            .vorbis => |*vorbis| return vorbis.read(data.channels, out, stride, offset, count),
            .mp3 => |mp3| return mp3.read(data, out, stride, offset, count),
        }
    }

    /// Read from `frame` on.
    pub fn rewind(self: *Reader, data: *const Data, frame: u64) void {
        switch (self.*) {
            .pcm, .oscillator => |*cursor| cursor.* = frame,
            .vorbis => |*vorbis| vorbis.rewind(frame),
            .mp3 => |mp3| mp3.rewind(data, frame),
        }
    }
};

const tau: f32 = 6.28318530717958647692;

/// One sample of the waveform, `phase` the fraction of one cycle done,
/// wrapped to `[0, 1)`.
fn waveAt(kind: types.OscillatorType, phase: f32) f32 {
    return switch (kind) {
        .sine => @sin(phase * tau),
        .square => if (phase < 0.5) 1 else -1,
        .sawtooth => phase * 2 - 1,
        .triangle => 1 - 4 * @abs(phase - 0.5),
    };
}

/// Decoded as it plays, from the file's bytes in memory.
pub const VorbisReader = struct {
    vorbis: ?*c.stb_vorbis,
    /// Where each channel's samples go, for one read.
    channels: []?[*]f32,

    fn init(gpa: Allocator, channels: u32, data: Data.Vorbis) Allocator.Error!VorbisReader {
        const pointers = try gpa.alloc(?[*]f32, channels);
        return .{
            .vorbis = c.stb_vorbis_open_memory(data.encoded.ptr, @intCast(data.encoded.len), null, null),
            .channels = pointers,
        };
    }

    fn deinit(self: *VorbisReader, gpa: Allocator) void {
        if (self.vorbis) |vorbis| c.stb_vorbis_close(vorbis);
        gpa.free(self.channels);
    }

    fn read(self: *VorbisReader, channels: u32, out: []f32, stride: u32, offset: u32, count: u32) u32 {
        const vorbis = self.vorbis orelse return 0;
        var got: u32 = 0;
        // stb_vorbis hands out what one packet decodes to at a time.
        while (got < count) {
            for (self.channels, 0..) |*pointer, channel| pointer.* = out[channel * stride + offset + got ..].ptr;
            const read_now = c.stb_vorbis_get_samples_float(vorbis, @intCast(channels), @ptrCast(self.channels.ptr), @intCast(count - got));
            if (read_now <= 0) break;
            got += @intCast(read_now);
        }
        return got;
    }

    fn rewind(self: *VorbisReader, frame: u64) void {
        const vorbis = self.vorbis orelse return;
        if (frame == 0) {
            _ = c.stb_vorbis_seek_start(vorbis);
        } else _ = c.stb_vorbis_seek(vorbis, @intCast(@min(frame, std.math.maxInt(c_uint))));
    }
};

/// Decoded a frame at a time as it plays.
pub const Mp3Reader = struct {
    decoder: c.mp3dec_t = undefined,
    pcm: [decoders.mp3_max_samples]f32 = undefined,
    /// The next frame of the index to decode.
    cursor: usize = 0,
    frame_channels: u32 = 1,
    /// Frames of sound decoded from the last one, and how many are used.
    decoded: u32 = 0,
    at: u32 = 0,
    /// Frames of sound still to let go of before the place asked for.
    pending: u64 = 0,
    /// Frames of sound before the end of the music.
    left: u64 = 0,

    fn read(self: *Mp3Reader, data: *const Data, out: []f32, stride: u32, offset: u32, count: u32) u32 {
        const channels = data.channels;
        var got: u32 = 0;
        while (got < count and self.left > 0) {
            if (self.at == self.decoded) {
                if (!self.decodeNext(data)) break;
                continue;
            }
            const taken: u32 = @intCast(@min(@as(u64, @min(count - got, self.decoded - self.at)), self.left));
            for (0..taken) |frame| {
                const from = self.pcm[(self.at + frame) * self.frame_channels ..];
                for (0..channels) |channel| {
                    const sample = if (self.frame_channels == channels)
                        from[channel]
                    else if (self.frame_channels == 1)
                        from[0]
                    else
                        (from[0] + from[1]) * 0.5;
                    out[channel * stride + offset + got + frame] = sample;
                }
            }
            self.at += taken;
            got += taken;
            self.left -= taken;
        }
        return got;
    }

    /// From the frame holding `frame`, with the few before it decoded and let
    /// go: a frame's sound may start in the bytes of the ones before it.
    fn rewind(self: *Mp3Reader, data: *const Data, frame: u64) void {
        const mp3 = data.kind.mp3;
        const target = frame + mp3.skip;
        // The last frame of the index starting at or before the target.
        var after: usize = 0;
        while (after < mp3.index.len and mp3.index[after].first <= target) after += 1;
        const holding = if (after == 0) 0 else after - 1;

        c.mp3dec_init(&self.decoder);
        self.pending = 0;
        self.cursor = if (holding >= 3) holding - 3 else 0;
        while (self.cursor < holding) _ = self.decodeNext(data);
        self.decoded = 0;
        self.at = 0;
        self.pending = if (holding < mp3.index.len and target > mp3.index[holding].first) target - mp3.index[holding].first else 0;
        const length = data.frames();
        self.left = if (frame < length) length - frame else 0;
    }

    fn decodeNext(self: *Mp3Reader, data: *const Data) bool {
        const mp3 = data.kind.mp3;
        if (self.cursor >= mp3.index.len) return false;
        const from = mp3.index[self.cursor].offset;
        self.cursor += 1;
        var info: c.mp3dec_frame_info_t = std.mem.zeroes(c.mp3dec_frame_info_t);
        const remaining: c_int = @intCast(@min(mp3.encoded.len - from, std.math.maxInt(c_int)));
        const count = c.mp3dec_decode_frame(&self.decoder, mp3.encoded.ptr + from, remaining, &self.pcm, &info);
        self.frame_channels = if (info.channels > 0) @intCast(info.channels) else 1;
        self.decoded = if (count > 0) @intCast(count) else 0;
        const skipped: u32 = @intCast(@min(self.pending, @as(u64, self.decoded)));
        self.at = skipped;
        self.pending -= skipped;
        return true;
    }
};
