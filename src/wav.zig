// SPDX-License-Identifier: CC0-1.0

//! RIFF WAVE files, read in whole into the planar floats the mixer works in:
//! 8-bit unsigned, 16, 24 and 32-bit signed integers, and 32 and 64-bit
//! floats, in plain `fmt ` chunks and in `WAVE_FORMAT_EXTENSIBLE` ones. What
//! `Device.loadClip` does with `.wav`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Error = error{
    /// Not a RIFF WAVE file, or one cut short.
    NotWav,
    /// A WAVE file of an encoding not read here: compressed, or of a sample
    /// size no one writes.
    Unsupported,
} || Allocator.Error;

/// A file's sound: `samples` is `frames` of channel 0, then of channel 1,
/// and so on. The caller's to free.
pub const Wave = struct {
    channels: u32,
    sample_rate: u32,
    frames: usize,
    samples: []f32,

    pub fn deinit(self: Wave, gpa: Allocator) void {
        gpa.free(self.samples);
    }
};

const Encoding = enum { integer, float };

const format_pcm = 1;
const format_float = 3;
const format_extensible = 0xFFFE;

pub fn read(gpa: Allocator, bytes: []const u8) Error!Wave {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotWav;

    var channels: u32 = 0;
    var sample_rate: u32 = 0;
    var bits: u32 = 0;
    var encoding: Encoding = .integer;
    var data: ?[]const u8 = null;

    var at: usize = 12;
    while (at + 8 <= bytes.len) {
        const id = bytes[at..][0..4];
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const start = at + 8;
        // A chunk that says it runs past the end of the file - a writer that
        // never came back to fill its size in - runs to the end.
        const end = @min(bytes.len, start + @as(usize, size));
        const body = bytes[start..end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.NotWav;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            channels = std.mem.readInt(u16, body[2..4], .little);
            sample_rate = std.mem.readInt(u32, body[4..8], .little);
            bits = std.mem.readInt(u16, body[14..16], .little);
            if (tag == format_extensible) {
                // The first two bytes of the subformat's GUID are the tag it
                // stands for.
                if (body.len < 26) return error.NotWav;
                tag = std.mem.readInt(u16, body[24..26], .little);
            }
            encoding = switch (tag) {
                format_pcm => .integer,
                format_float => .float,
                else => return error.Unsupported,
            };
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
        }
        // Chunks are padded to an even length.
        at = start + @as(usize, size) + (size & 1);
    }

    const sound = data orelse return error.NotWav;
    if (channels == 0 or sample_rate == 0) return error.NotWav;
    const width: usize = switch (encoding) {
        .integer => switch (bits) {
            8, 16, 24, 32 => bits / 8,
            else => return error.Unsupported,
        },
        .float => switch (bits) {
            32, 64 => bits / 8,
            else => return error.Unsupported,
        },
    };

    const frame_bytes = width * channels;
    const frames = sound.len / frame_bytes;
    const samples = try gpa.alloc(f32, frames * channels);
    for (0..frames) |frame| {
        for (0..channels) |channel| {
            const cell = sound[(frame * channels + channel) * width ..][0..width];
            samples[channel * frames + frame] = sampleOf(encoding, cell);
        }
    }
    return .{ .channels = channels, .sample_rate = sample_rate, .frames = frames, .samples = samples };
}

fn sampleOf(encoding: Encoding, cell: []const u8) f32 {
    return switch (encoding) {
        .integer => switch (cell.len) {
            1 => (@as(f32, @floatFromInt(cell[0])) - 128.0) / 128.0,
            2 => @as(f32, @floatFromInt(std.mem.readInt(i16, cell[0..2], .little))) / 32768.0,
            3 => @as(f32, @floatFromInt(std.mem.readInt(i24, cell[0..3], .little))) / 8388608.0,
            else => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, cell[0..4], .little))) / 2147483648.0),
        },
        .float => switch (cell.len) {
            4 => @bitCast(std.mem.readInt(u32, cell[0..4], .little)),
            else => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, cell[0..8], .little)))),
        },
    };
}

/// A WAVE file of `samples`, interleaved, as a test or a tool writes one.
pub fn write(gpa: Allocator, comptime T: type, channels: u16, sample_rate: u32, samples: []const T) Allocator.Error![]u8 {
    const is_float = @typeInfo(T) == .float;
    const width: u32 = @divExact(@bitSizeOf(T), 8);
    const tag: u16 = if (is_float) format_float else format_pcm;
    const data_size: u32 = @intCast(samples.len * width);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "RIFF");
    try appendInt(gpa, &out, u32, 36 + data_size);
    try out.appendSlice(gpa, "WAVEfmt ");
    try appendInt(gpa, &out, u32, 16);
    try appendInt(gpa, &out, u16, tag);
    try appendInt(gpa, &out, u16, channels);
    try appendInt(gpa, &out, u32, sample_rate);
    try appendInt(gpa, &out, u32, sample_rate * channels * width);
    try appendInt(gpa, &out, u16, @intCast(channels * width));
    try appendInt(gpa, &out, u16, @intCast(width * 8));
    try out.appendSlice(gpa, "data");
    try appendInt(gpa, &out, u32, data_size);
    for (samples) |sample| {
        if (is_float) {
            try appendInt(gpa, &out, std.meta.Int(.unsigned, width * 8), @bitCast(sample));
        } else if (T == u8) {
            try out.append(gpa, sample);
        } else try appendInt(gpa, &out, T, sample);
    }
    return out.toOwnedSlice(gpa);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) Allocator.Error!void {
    var cell: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &cell, value, .little);
    try out.appendSlice(gpa, &cell);
}

test "a stereo 16-bit file is read as planar floats" {
    const file = try write(testing.allocator, i16, 2, 22050, &.{ 16384, -16384, 8192, 0 });
    defer testing.allocator.free(file);
    const wave = try read(testing.allocator, file);
    defer wave.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), wave.channels);
    try testing.expectEqual(@as(u32, 22050), wave.sample_rate);
    try testing.expectEqual(@as(usize, 2), wave.frames);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25, -0.5, 0 }, wave.samples);
}

test "every sample size and a float file read to the same values" {
    const gpa = testing.allocator;
    inline for (.{ .{ u8, [_]u8{ 192, 64 } }, .{ i24, [_]i24{ 4194304, -4194304 } }, .{ i32, [_]i32{ 1073741824, -1073741824 } }, .{ f32, [_]f32{ 0.5, -0.5 } }, .{ f64, [_]f64{ 0.5, -0.5 } } }) |case| {
        const samples = case[1];
        const file = try write(gpa, case[0], 1, 44100, &samples);
        defer gpa.free(file);
        const wave = try read(gpa, file);
        defer wave.deinit(gpa);
        try testing.expectApproxEqAbs(@as(f32, 0.5), wave.samples[0], 0.001);
        try testing.expectApproxEqAbs(@as(f32, -0.5), wave.samples[1], 0.001);
    }
}

test "what is not a WAVE file, or not one read here, says so" {
    try testing.expectError(error.NotWav, read(testing.allocator, "OggS nothing like it"));
    var file = try write(testing.allocator, i16, 1, 8000, &.{0});
    defer testing.allocator.free(file);
    // A compressed encoding: IMA ADPCM.
    std.mem.writeInt(u16, file[20..22], 0x11, .little);
    try testing.expectError(error.Unsupported, read(testing.allocator, file));
}
