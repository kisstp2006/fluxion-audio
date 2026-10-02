// SPDX-License-Identifier: CC0-1.0

//! What a bus does to what it mixed: a `Processor` - a linear gain, a stereo
//! pan, or a pitch shift that keeps the length - each a voice's or a
//! submix's, on its bus.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");

pub const Processor = struct {
    /// The bus it is on, which it takes itself off as it goes.
    bus: ?*Bus = null,
    enabled: bool = true,
    kind: Kind,

    pub const Kind = union(enum) {
        /// A multiplier: `Device.setVolume`'s.
        gain: f32,
        /// -1 fully left, 0 the middle, 1 fully right. Nothing on anything but
        /// two channels, which is what a pan means at all.
        pan: f32,
        pitch: Pitch,
    };

    pub fn create(gpa: Allocator, kind: Kind) Allocator.Error!*Processor {
        const self = try gpa.create(Processor);
        self.* = .{ .kind = kind };
        return self;
    }

    pub fn destroy(self: *Processor, gpa: Allocator) void {
        if (self.bus) |bus| bus.removeProcessor(self);
        if (self.kind == .pitch) self.kind.pitch.deinit(gpa);
        gpa.destroy(self);
    }

    /// `samples` is `frames` of each of `channels`, planar.
    pub fn process(self: *Processor, gpa: Allocator, frames: u32, channels: u32, sample_rate: u32, samples: []f32) void {
        switch (self.kind) {
            .gain => |gain| for (samples) |*sample| {
                sample.* *= gain;
            },
            .pan => |pan| {
                if (channels != 2) return;
                const left: f32 = if (pan <= 0) 1 else 1 - pan;
                const right: f32 = if (pan >= 0) 1 else 1 + pan;
                for (samples[0..frames]) |*sample| sample.* *= left;
                for (samples[frames..][0..frames]) |*sample| sample.* *= right;
            },
            .pitch => |*pitch| pitch.process(gpa, frames, channels, sample_rate, samples),
        }
    }
};

/// A phase-vocoder pitch shift, an octave down to an octave up, and at 1 a
/// straight pass that skips the transform. One shifter per channel: each
/// keeps its own overlap-add history.
pub const Pitch = struct {
    pitch: f32 = 1,
    shifters: std.ArrayList(*Shifter) = .empty,
    scratch: std.ArrayList(f32) = .empty,

    pub fn deinit(self: *Pitch, gpa: Allocator) void {
        for (self.shifters.items) |shifter| gpa.destroy(shifter);
        self.shifters.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    fn process(self: *Pitch, gpa: Allocator, frames: u32, channels: u32, sample_rate: u32, samples: []f32) void {
        if (self.pitch == 1) return;
        while (self.shifters.items.len < channels) {
            self.shifters.ensureUnusedCapacity(gpa, 1) catch return;
            const shifter = gpa.create(Shifter) catch return;
            shifter.* = .init;
            self.shifters.appendAssumeCapacity(shifter);
        }
        self.scratch.resize(gpa, frames) catch return;
        for (0..channels) |channel| {
            const channel_samples = samples[channel * frames ..][0..frames];
            self.shifters.items[channel].process(self.pitch, frames, sample_rate, channel_samples, self.scratch.items);
            @memcpy(channel_samples, self.scratch.items);
        }
    }
};

const pi: f32 = 3.14159265358979323846;

const Complex = struct {
    re: f32 = 0,
    im: f32 = 0,

    fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }

    fn magnitude(a: Complex) f32 {
        return @sqrt(a.re * a.re + a.im * a.im);
    }
};

/// Stephan M. Bernsee's `smbPitchShift` 1.2, carried over to Zig, for one
/// channel: a short-time Fourier transform of 1024 samples with four-fold
/// overlap, its bins moved up or down by the factor, and put back together.
/// Its notice, as the licence asks of every copy of the source:
///
///     COPYRIGHT 1999-2015 Stephan M. Bernsee <s.bernsee [AT] zynaptiq [DOT] com>
///
///                         The Wide Open License (WOL)
///
///     Permission to use, copy, modify, distribute and sell this software and its
///     documentation for any purpose is hereby granted without fee, provided that
///     the above copyright notice and this license appear in all source copies.
///     THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT EXPRESS OR IMPLIED WARRANTY OF
///     ANY KIND. See http://www.dspguru.com/wol.htm for more information.
const Shifter = struct {
    const size = 1024;
    const oversampling = 4;
    const half = size / 2;
    const step = size / oversampling;
    const latency = size - step;
    const expected: f32 = 2 * pi * @as(f32, step) / @as(f32, size);

    window: [size]f32,
    in_fifo: [size]f32 = @splat(0),
    out_fifo: [size]f32 = @splat(0),
    work: [size]Complex = @splat(.{}),
    last_phase: [half + 1]f32 = @splat(0),
    sum_phase: [half + 1]f32 = @splat(0),
    output: [2 * size]f32 = @splat(0),
    analysis_frequency: [half + 1]f32 = @splat(0),
    analysis_magnitude: [half + 1]f32 = @splat(0),
    synthesis_frequency: [half + 1]f32 = @splat(0),
    synthesis_magnitude: [half + 1]f32 = @splat(0),
    rover: u32 = 0,

    const init: Shifter = .{ .window = blk: {
        @setEvalBranchQuota(20000);
        var window: [size]f32 = undefined;
        for (&window, 0..) |*w, k| w.* = 0.5 * (1 + @cos(2 * pi * @as(f32, @floatFromInt(k)) / @as(f32, size)));
        break :blk window;
    } };

    fn process(self: *Shifter, shift: f32, count: u32, sample_rate: u32, in: []const f32, out: []f32) void {
        const per_bin = @as(f32, @floatFromInt(sample_rate)) / @as(f32, size);
        if (self.rover == 0) self.rover = latency;
        for (0..count) |i| {
            self.in_fifo[self.rover] = in[i];
            out[i] = self.out_fifo[self.rover - latency];
            self.rover += 1;
            if (self.rover < size) continue;
            self.rover = latency;

            // Analysis.
            for (&self.work, self.in_fifo, self.window) |*bin, sample, w| bin.* = .{ .re = sample * w };
            fft(-1, &self.work);
            for (0..half + 1) |k| {
                const current = self.work[k];
                const magnitude = 2 * current.magnitude();
                const sign: f32 = if (current.im > 0) 1 else -1;
                const phase: f32 = if (current.im == 0) 0 else if (current.re == 0) sign * pi / 2 else std.math.atan2(current.im, current.re);
                var tmp = phase - self.last_phase[k];
                self.last_phase[k] = phase;
                tmp -= @as(f32, @floatFromInt(k)) * expected;
                var qpd: i32 = @intFromFloat(tmp / pi);
                if (qpd >= 0) qpd += qpd & 1 else qpd -= qpd & 1;
                tmp -= pi * @as(f32, @floatFromInt(qpd));
                tmp = oversampling * tmp / (2 * pi);
                tmp = @as(f32, @floatFromInt(k)) * per_bin + tmp * per_bin;
                self.analysis_magnitude[k] = magnitude;
                self.analysis_frequency[k] = tmp;
            }

            // The bins moved.
            @memset(&self.synthesis_magnitude, 0);
            for (0..half + 1) |k| {
                const index: u32 = @intFromFloat(@as(f32, @floatFromInt(k)) * shift);
                if (index > half) break;
                self.synthesis_magnitude[index] += self.analysis_magnitude[k];
                self.synthesis_frequency[index] = self.analysis_frequency[k] * shift;
            }

            // Synthesis.
            for (0..half + 1) |k| {
                var tmp = self.synthesis_frequency[k];
                tmp -= @as(f32, @floatFromInt(k)) * per_bin;
                tmp /= per_bin;
                tmp = 2 * pi * tmp / oversampling;
                tmp += @as(f32, @floatFromInt(k)) * expected;
                self.sum_phase[k] += tmp;
                const phase = self.sum_phase[k];
                const magnitude = self.synthesis_magnitude[k];
                self.work[k] = .{ .re = magnitude * @cos(phase), .im = magnitude * @sin(phase) };
            }
            fft(1, &self.work);
            for (0..size) |k| self.output[k] += 2 * self.window[k] * self.work[k].re / (half * oversampling);
            @memcpy(self.out_fifo[0..step], self.output[0..step]);
            std.mem.copyForwards(f32, self.output[0 .. 2 * size - step], self.output[step .. 2 * size]);
            @memset(self.output[size..], 0);
            std.mem.copyForwards(f32, self.in_fifo[0..latency], self.in_fifo[step..size]);
        }
    }

    /// In place, `sign` -1 forward and 1 back.
    fn fft(comptime sign: f32, buffer: *[size]Complex) void {
        for (1..size - 1) |i| {
            var j: usize = 0;
            var bit: usize = 1;
            while (bit < size) : (bit <<= 1) {
                if (i & bit != 0) j += 1;
                j <<= 1;
            }
            j >>= 1;
            if (i < j) std.mem.swap(Complex, &buffer[i], &buffer[j]);
        }
        var stride: usize = 2;
        var i: usize = 1;
        while (i < size) : ({
            i <<= 1;
            stride <<= 1;
        }) {
            const stride2 = stride >> 1;
            const arg = pi / @as(f32, @floatFromInt(stride2));
            const w: Complex = .{ .re = @cos(arg), .im = @sin(arg) * sign };
            var u: Complex = .{ .re = 1 };
            for (0..stride2) |j| {
                var k = j;
                while (k < size) : (k += stride) {
                    const temp = buffer[k + stride2].mul(u);
                    buffer[k + stride2] = buffer[k].sub(temp);
                    buffer[k] = buffer[k].add(temp);
                }
                u = u.mul(w);
            }
        }
    }
};
