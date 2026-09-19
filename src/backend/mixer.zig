// SPDX-License-Identifier: CC0-1.0

//! The vendored mixer graph, wired up so a clip is a `Data`, a voice is a
//! `Stream` feeding its own bus (with a gain, a pan and a pitch-shift
//! processor on it) into the master bus. `Device.mix` pulls the result;
//! nothing here writes to a sound device - that is the next backend, on top
//! of this one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const native = @import("../native.zig");
const c = native.c;

const Mixer = struct {
    gpa: Allocator,
    handle: *c.fx_audio_mixer,
    master_bus_id: usize,
};

/// The five graph objects behind one playing voice: a stream reading the
/// clip, a private bus so the voice has somewhere to hang its own gain, pan
/// and pitch-shift, and those three processors.
const Voice = struct {
    stream_id: usize,
    bus_id: usize,
    gain_id: usize,
    pan_id: usize,
    pitch_id: usize,
};

/// A submix: a bus of its own with a gain processor for its volume, feeding
/// the master bus or another submix.
const Submix = struct {
    bus_id: usize,
    gain_id: usize,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    _ = desc;
    const handle = c.fx_audio_mixer_create() orelse return error.Failed;
    errdefer c.fx_audio_mixer_destroy(handle);

    const master_bus_id = c.fx_audio_mixer_next_id(handle);
    c.fx_audio_mixer_init_bus(handle, master_bus_id);
    c.fx_audio_mixer_set_master_bus(handle, master_bus_id);

    const self = try gpa.create(Mixer);
    self.* = .{ .gpa = gpa, .handle = handle, .master_bus_id = master_bus_id };
    return .{ self, &vtable };
}

const vtable: backend.Vtable = .{
    .deinit = deinit,
    .info = info,
    .loadClip = loadClip,
    .loadOscillator = loadOscillator,
    .unloadClip = unloadClip,
    .play = play,
    .stopVoice = stopVoice,
    .setVoiceVolume = setVoiceVolume,
    .setVoicePan = setVoicePan,
    .setVoicePitch = setVoicePitch,
    .isVoicePlaying = isVoicePlaying,
    .createSubmix = createSubmix,
    .destroySubmix = destroySubmix,
    .setSubmixVolume = setSubmixVolume,
    .setSubmixOutput = setSubmixOutput,
    .mix = mix,
};

fn cast(impl: backend.Impl) *Mixer {
    return @ptrCast(@alignCast(impl));
}

/// The raw handle underneath, for an output backend (`alsa`, `opensl`) that
/// pulls samples directly rather than through `Device.mix`. `impl` must be
/// one this file's `open` returned.
pub fn handleOf(impl: backend.Impl) *c.fx_audio_mixer {
    return cast(impl).handle;
}

fn deinit(impl: backend.Impl) void {
    const self = cast(impl);
    c.fx_audio_mixer_destroy(self.handle);
    self.gpa.destroy(self);
}

fn info(impl: backend.Impl) types.Info {
    _ = impl;
    return .{ .backend = .mixer, .device_name = "mixer graph, no sound device" };
}

fn loadClip(impl: backend.Impl, desc: types.ClipDesc) backend.Error!backend.Native {
    const self = cast(impl);
    const data_id = c.fx_audio_mixer_next_id(self.handle);

    switch (desc.format) {
        .pcm_s16 => {
            // Interleaved S16, byte-aligned and not necessarily i16-aligned,
            // deinterleaved into the mixer's own planar-float layout - int16
            // min/max is asymmetric, so this scales by 32768 both ways
            // rather than by the max positive value, which keeps -1.0
            // reachable.
            const channels = desc.channels;
            const frame_count = desc.bytes.len / 2 / channels;

            const planar = self.gpa.alloc(f32, frame_count * channels) catch return error.OutOfMemory;
            defer self.gpa.free(planar);

            for (0..frame_count) |frame| {
                for (0..channels) |channel| {
                    const offset = (frame * channels + channel) * 2;
                    const sample = std.mem.readInt(i16, desc.bytes[offset..][0..2], .little);
                    planar[channel * frame_count + frame] = @as(f32, @floatFromInt(sample)) / 32768.0;
                }
            }

            c.fx_audio_mixer_init_data_pcm_f32(
                self.handle,
                data_id,
                @intCast(channels),
                desc.sample_rate,
                planar.ptr,
                frame_count,
            );
        },
        .vorbis => {
            const failed = c.fx_audio_mixer_init_data_vorbis(self.handle, data_id, desc.bytes.ptr, desc.bytes.len);
            if (failed != 0) return error.DecodeFailed;
        },
    }

    return @ptrFromInt(data_id);
}

fn loadOscillator(impl: backend.Impl, desc: types.OscillatorDesc) backend.Error!backend.Native {
    const self = cast(impl);
    const data_id = c.fx_audio_mixer_next_id(self.handle);

    const native_type: c.fx_audio_oscillator_type = switch (desc.type) {
        .sine => c.FX_AUDIO_OSCILLATOR_SINE,
        .square => c.FX_AUDIO_OSCILLATOR_SQUARE,
        .sawtooth => c.FX_AUDIO_OSCILLATOR_SAWTOOTH,
        .triangle => c.FX_AUDIO_OSCILLATOR_TRIANGLE,
    };
    c.fx_audio_mixer_init_data_oscillator(
        self.handle,
        data_id,
        native_type,
        desc.frequency,
        desc.amplitude,
        desc.length,
        desc.sample_rate,
    );

    return @ptrFromInt(data_id);
}

fn unloadClip(impl: backend.Impl, native_clip: backend.Native) void {
    const self = cast(impl);
    c.fx_audio_mixer_delete_object(self.handle, @intFromPtr(native_clip));
}

fn play(impl: backend.Impl, clip: backend.Native, output: ?backend.Native, desc: types.PlayDesc) backend.Error!backend.Native {
    const self = cast(impl);
    const data_id = @intFromPtr(clip);
    const output_bus_id: usize = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;

    const voice = try self.gpa.create(Voice);
    errdefer self.gpa.destroy(voice);

    voice.stream_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_stream(self.handle, voice.stream_id, data_id);

    voice.bus_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_bus(self.handle, voice.bus_id);
    c.fx_audio_mixer_set_stream_output(self.handle, voice.stream_id, voice.bus_id);
    c.fx_audio_mixer_set_bus_output(self.handle, voice.bus_id, output_bus_id);

    voice.gain_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_gain(self.handle, voice.gain_id, desc.volume);
    c.fx_audio_mixer_add_processor(self.handle, voice.bus_id, voice.gain_id);

    voice.pan_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_pan(self.handle, voice.pan_id, desc.pan);
    c.fx_audio_mixer_add_processor(self.handle, voice.bus_id, voice.pan_id);

    voice.pitch_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_pitch_shift(self.handle, voice.pitch_id, desc.pitch);
    c.fx_audio_mixer_add_processor(self.handle, voice.bus_id, voice.pitch_id);

    c.fx_audio_mixer_play_stream(self.handle, voice.stream_id);

    return voice;
}

fn asVoice(native_voice: backend.Native) *Voice {
    return @ptrCast(@alignCast(native_voice));
}

fn stopVoice(impl: backend.Impl, native_voice: backend.Native) void {
    const self = cast(impl);
    const voice = asVoice(native_voice);
    c.fx_audio_mixer_delete_object(self.handle, voice.pitch_id);
    c.fx_audio_mixer_delete_object(self.handle, voice.pan_id);
    c.fx_audio_mixer_delete_object(self.handle, voice.gain_id);
    c.fx_audio_mixer_delete_object(self.handle, voice.bus_id);
    c.fx_audio_mixer_delete_object(self.handle, voice.stream_id);
    self.gpa.destroy(voice);
}

fn setVoiceVolume(impl: backend.Impl, native_voice: backend.Native, volume: f32) void {
    const self = cast(impl);
    c.fx_audio_mixer_set_gain(self.handle, asVoice(native_voice).gain_id, volume);
}

fn setVoicePan(impl: backend.Impl, native_voice: backend.Native, pan: f32) void {
    const self = cast(impl);
    c.fx_audio_mixer_set_pan(self.handle, asVoice(native_voice).pan_id, pan);
}

fn setVoicePitch(impl: backend.Impl, native_voice: backend.Native, pitch: f32) void {
    const self = cast(impl);
    c.fx_audio_mixer_set_pitch_shift(self.handle, asVoice(native_voice).pitch_id, pitch);
}

fn isVoicePlaying(impl: backend.Impl, native_voice: backend.Native) bool {
    const self = cast(impl);
    return c.fx_audio_mixer_is_stream_playing(self.handle, asVoice(native_voice).stream_id) != 0;
}

fn asSubmix(native_submix: backend.Native) *Submix {
    return @ptrCast(@alignCast(native_submix));
}

fn createSubmix(impl: backend.Impl, output: ?backend.Native, volume: f32) backend.Error!backend.Native {
    const self = cast(impl);
    const output_bus_id: usize = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;

    const submix = try self.gpa.create(Submix);
    errdefer self.gpa.destroy(submix);

    submix.bus_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_bus(self.handle, submix.bus_id);
    c.fx_audio_mixer_set_bus_output(self.handle, submix.bus_id, output_bus_id);

    submix.gain_id = c.fx_audio_mixer_next_id(self.handle);
    c.fx_audio_mixer_init_gain(self.handle, submix.gain_id, volume);
    c.fx_audio_mixer_add_processor(self.handle, submix.bus_id, submix.gain_id);

    return submix;
}

fn destroySubmix(impl: backend.Impl, native_submix: backend.Native) void {
    const self = cast(impl);
    const submix = asSubmix(native_submix);
    c.fx_audio_mixer_delete_object(self.handle, submix.gain_id);
    c.fx_audio_mixer_delete_object(self.handle, submix.bus_id);
    self.gpa.destroy(submix);
}

fn setSubmixVolume(impl: backend.Impl, native_submix: backend.Native, volume: f32) void {
    const self = cast(impl);
    c.fx_audio_mixer_set_gain(self.handle, asSubmix(native_submix).gain_id, volume);
}

fn setSubmixOutput(impl: backend.Impl, native_submix: backend.Native, output: ?backend.Native) void {
    const self = cast(impl);
    const output_bus_id: usize = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;
    c.fx_audio_mixer_set_bus_output(self.handle, asSubmix(native_submix).bus_id, output_bus_id);
}

fn mix(impl: backend.Impl, channels: u32, sample_rate: u32, out: []f32) void {
    const self = cast(impl);
    const frames: u32 = @intCast(out.len / channels);
    c.fx_audio_mixer_get_samples(self.handle, frames, channels, sample_rate, out.ptr);
}

// -------------------------------------------------------------------------
// Tests - proving the vendored graph actually mixes, not just that it links
// -------------------------------------------------------------------------

const testing = std.testing;
const Device = @import("../Device.zig");

test "a mono clip at unity gain passes straight through" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const tone = [_]i16{ 16384, -16384, 16384, -16384 };
    const clip = try device.loadClip(.{
        .format = .pcm_s16,
        .bytes = std.mem.sliceAsBytes(&tone),
        .channels = 1,
        .sample_rate = 44100,
    });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    var out: [4]f32 = undefined;
    device.mix(1, 44100, &out);

    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[3], 0.001);
}

test "gain scales what comes out, and stopping silences it" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const tone = [_]i16{16384};
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(&tone), .channels = 1 });
    const voice = try device.play(clip, .{ .volume = 0.5 });

    var out: [1]f32 = undefined;
    device.mix(1, 44100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 0.001);

    device.stop(voice);
    device.mix(1, 44100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 0.001);
}

test "a stream reports itself finished once it has played out" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const tone = [_]i16{ 100, 200 };
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(&tone), .channels = 1 });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    // `play` only queues a command - it takes a `mix` to drain the queue and
    // make the stream exist in the graph at all, same as a real backend
    // pulling audio would.
    var one: [1]f32 = undefined;
    device.mix(1, 44100, &one);
    try testing.expect(device.isPlaying(voice));

    device.mix(1, 44100, &one);
    try testing.expect(!device.isPlaying(voice));
}

test "vorbis bytes that are not vorbis are refused" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    try testing.expectError(error.DecodeFailed, device.loadClip(.{
        .format = .vorbis,
        .bytes = "not an ogg vorbis file",
    }));
}

test "pitch shift at unity is a passthrough, same as no processor at all" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const tone = [_]i16{ 16384, -16384, 16384, -16384 };
    const clip = try device.loadClip(.{
        .format = .pcm_s16,
        .bytes = std.mem.sliceAsBytes(&tone),
        .channels = 1,
        .sample_rate = 44100,
    });
    const voice = try device.play(clip, .{ .pitch = 1.0 });
    defer device.stop(voice);

    var out: [4]f32 = undefined;
    device.mix(1, 44100, &out);

    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[1], 0.001);
}

test "a shifted voice keeps producing finite samples past the FFT's own latency" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    // Loud enough, and long enough to run well past the pitch shifter's
    // internal FFT frame before this asserts anything about its output.
    var tone: [4096]i16 = undefined;
    var t: f32 = 0;
    for (&tone) |*sample| {
        sample.* = @intFromFloat(std.math.sin(t) * 16384.0);
        t += 2.0 * std.math.pi * 220.0 / 44100.0;
    }

    const clip = try device.loadClip(.{
        .format = .pcm_s16,
        .bytes = std.mem.sliceAsBytes(&tone),
        .channels = 1,
        .sample_rate = 44100,
    });
    const voice = try device.play(clip, .{ .pitch = 1.5 });
    defer device.stop(voice);

    var out: [4096]f32 = undefined;
    device.mix(1, 44100, &out);

    var found_nonzero = false;
    for (out) |sample| {
        try testing.expect(std.math.isFinite(sample));
        try testing.expect(sample >= -1.0 and sample <= 1.0);
        if (sample != 0.0) found_nonzero = true;
    }
    try testing.expect(found_nonzero);
}

test "setPitch reaches an already-playing voice" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const tone = [_]i16{16384} ** 64;
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(&tone), .channels = 1 });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    try device.setPitch(voice, 0.5);

    var out: [64]f32 = undefined;
    device.mix(1, 44100, &out);
    for (out) |sample| try testing.expect(std.math.isFinite(sample));
}

test "an oscillator clip needs no bytes and plays a real waveform" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try device.loadOscillator(.{ .type = .sine, .frequency = 440, .amplitude = 0.8 });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    var out: [256]f32 = undefined;
    device.mix(1, 44100, &out);

    var found_nonzero = false;
    for (out) |sample| {
        try testing.expect(sample >= -0.8001 and sample <= 0.8001);
        if (sample != 0.0) found_nonzero = true;
    }
    try testing.expect(found_nonzero);
    // Nothing stops an endless oscillator (`length == 0`) on its own.
    try testing.expect(device.isPlaying(voice));
}

test "a submix's volume reaches every voice routed through it" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const music = try device.createSubmix(.{ .volume = 0.5 });
    defer device.destroySubmix(music);

    // Two frames, so a full clip is not consumed by the first `mix` alone -
    // `setSubmixVolume` needs a second one still playing to reach.
    const tone = [_]i16{ 16384, 16384 };
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(&tone), .channels = 1 });
    const voice = try device.play(clip, .{ .output = music });
    defer device.stop(voice);

    var out: [1]f32 = undefined;
    device.mix(1, 44100, &out);
    // 16384 / 32768 (unity voice gain) * 0.5 (the submix) = 0.25.
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 0.001);

    try device.setSubmixVolume(music, 1.0);
    device.mix(1, 44100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
}

test "submixes chain into each other before reaching the master bus" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const group = try device.createSubmix(.{ .volume = 0.5 });
    defer device.destroySubmix(group);
    const music = try device.createSubmix(.{ .volume = 0.5, .output = group });
    defer device.destroySubmix(music);

    const tone = [_]i16{16384};
    const clip = try device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(&tone), .channels = 1 });
    const voice = try device.play(clip, .{ .output = music });
    defer device.stop(voice);

    var out: [1]f32 = undefined;
    device.mix(1, 44100, &out);
    // 0.5 (voice's clip, out of unity gain) * 0.5 (music) * 0.5 (group) = 0.125.
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[0], 0.001);
}

test "an oscillator with a length finishes on its own" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try device.loadOscillator(.{
        .type = .square,
        .frequency = 100,
        .length = 1.0 / 44100.0, // exactly one frame
    });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    var one: [1]f32 = undefined;
    device.mix(1, 44100, &one);
    try testing.expect(device.isPlaying(voice));

    device.mix(1, 44100, &one);
    try testing.expect(!device.isPlaying(voice));
}
