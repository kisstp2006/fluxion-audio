// SPDX-License-Identifier: CC0-1.0

//! The vendored mixer graph, wired up so a clip is a `Data`, a voice is a
//! `Stream` feeding its own bus (with a gain, a pan and a pitch-shift
//! processor on it) into the master bus. `Device.mix` pulls the result.
//!
//! On its own it writes to no sound device. The output backends - `wasapi`,
//! `alsa`, `opensl` - are this graph with an `Output` attached: the thread
//! of their own that pulls from it and feeds the sound card, closed before
//! the graph goes. Every other call is this file's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const native = @import("../native.zig");
const c = native.c;

/// A sound device fed from the graph on a thread of its own.
pub const Output = struct {
    context: *anyopaque,
    /// Stops the thread and lets the device go.
    close: *const fn (context: *anyopaque) void,
    info: types.Info,
};

const Mixer = struct {
    gpa: Allocator,
    handle: *c.fx_audio_mixer,
    master_bus_id: usize,
    output: ?Output = null,
};

/// The five graph objects behind one playing voice: a stream reading the
/// clip, a private bus so the voice has somewhere to hang its own gain, pan
/// and pitch-shift, and those three processors - and what the stream says
/// of itself as it plays.
const Voice = struct {
    stream_id: usize,
    bus_id: usize,
    gain_id: usize,
    pan_id: usize,
    pitch_id: usize,
    state: *c.fx_audio_voice_state,
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

/// Hand the graph `impl` - one `open` returned - to a sound device's thread:
/// from here `Device.mix` leaves its buffer alone, and the device is closed
/// with the graph.
pub fn attach(impl: backend.Impl, output: Output) void {
    cast(impl).output = output;
}

/// Mix into `out` for a sound device: what an `Output`'s thread calls.
pub fn pull(impl: backend.Impl, channels: u32, sample_rate: u32, out: []f32) void {
    const self = cast(impl);
    const frames: u32 = @intCast(out.len / channels);
    c.fx_audio_mixer_get_samples(self.handle, frames, channels, sample_rate, out.ptr);
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
    .setVoiceSpeed = setVoiceSpeed,
    .setVoiceLooping = setVoiceLooping,
    .setVoicePaused = setVoicePaused,
    .seekVoice = seekVoice,
    .voiceStatus = voiceStatus,
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
    // The device's thread reads the graph: it stops first.
    if (self.output) |output| output.close(output.context);
    c.fx_audio_mixer_destroy(self.handle);
    self.gpa.destroy(self);
}

fn info(impl: backend.Impl) types.Info {
    const self = cast(impl);
    if (self.output) |output| return output.info;
    return .{ .backend = .mixer, .device_name = "mixer graph, no sound device" };
}

fn loadClip(impl: backend.Impl, desc: types.ClipDesc) backend.Error!backend.Loaded {
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

            c.fx_audio_mixer_init_data_pcm_f32(self.handle, data_id, @intCast(channels), desc.sample_rate, planar.ptr, frame_count);
            return .{ .native = @ptrFromInt(data_id), .info = .{ .channels = channels, .sample_rate = desc.sample_rate, .frames = frame_count } };
        },
        .pcm_f32 => {
            const frame_count = desc.samples.len / desc.channels;
            c.fx_audio_mixer_init_data_pcm_f32(self.handle, data_id, @intCast(desc.channels), desc.sample_rate, desc.samples.ptr, frame_count);
            return .{ .native = @ptrFromInt(data_id), .info = .{ .channels = desc.channels, .sample_rate = desc.sample_rate, .frames = frame_count } };
        },
        .vorbis, .mp3 => {
            var said: c.fx_audio_clip_info = undefined;
            const failed = if (desc.format == .vorbis)
                c.fx_audio_mixer_init_data_vorbis(self.handle, data_id, desc.bytes.ptr, desc.bytes.len, &said)
            else
                c.fx_audio_mixer_init_data_mp3(self.handle, data_id, desc.bytes.ptr, desc.bytes.len, &said);
            if (failed != 0) return error.DecodeFailed;
            return .{ .native = @ptrFromInt(data_id), .info = .{ .channels = said.channels, .sample_rate = said.sample_rate, .frames = said.frames } };
        },
        .wav => unreachable,
    }
}

fn loadOscillator(impl: backend.Impl, desc: types.OscillatorDesc) backend.Error!backend.Loaded {
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

    return .{ .native = @ptrFromInt(data_id), .info = .{ .channels = 1, .sample_rate = desc.sample_rate, .frames = types.oscillatorFrames(desc) } };
}

fn unloadClip(impl: backend.Impl, native_clip: backend.Native) void {
    const self = cast(impl);
    c.fx_audio_mixer_delete_object(self.handle, @intFromPtr(native_clip));
}

fn play(impl: backend.Impl, clip: backend.Native, output: ?backend.Native, desc: types.PlayDesc, start: u64) backend.Error!backend.Native {
    const self = cast(impl);
    const data_id = @intFromPtr(clip);
    const output_bus_id: usize = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;

    const voice = try self.gpa.create(Voice);
    errdefer self.gpa.destroy(voice);

    voice.stream_id = c.fx_audio_mixer_next_id(self.handle);
    voice.state = c.fx_audio_mixer_init_stream(self.handle, voice.stream_id, data_id) orelse return error.OutOfMemory;

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

    if (desc.loop) c.fx_audio_mixer_set_stream_looping(self.handle, voice.stream_id, 1);
    if (desc.speed != 1) c.fx_audio_mixer_set_stream_speed(self.handle, voice.stream_id, @max(desc.speed, 0.01));
    if (start > 0) c.fx_audio_mixer_seek_stream(self.handle, voice.stream_id, start);
    if (!desc.paused) c.fx_audio_mixer_play_stream(self.handle, voice.stream_id);
    c.fx_audio_voice_state_expect(voice.state, @intFromBool(!desc.paused), start);

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
    c.fx_audio_voice_state_release(voice.state);
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

fn setVoiceSpeed(impl: backend.Impl, native_voice: backend.Native, speed: f32) void {
    const self = cast(impl);
    c.fx_audio_mixer_set_stream_speed(self.handle, asVoice(native_voice).stream_id, speed);
}

fn setVoiceLooping(impl: backend.Impl, native_voice: backend.Native, looping: bool) void {
    const self = cast(impl);
    c.fx_audio_mixer_set_stream_looping(self.handle, asVoice(native_voice).stream_id, @intFromBool(looping));
}

fn setVoicePaused(impl: backend.Impl, native_voice: backend.Native, paused: bool) void {
    const self = cast(impl);
    const voice = asVoice(native_voice);
    if (paused) {
        c.fx_audio_mixer_stop_stream(self.handle, voice.stream_id, 0);
    } else c.fx_audio_mixer_play_stream(self.handle, voice.stream_id);
    c.fx_audio_voice_state_expect(voice.state, @intFromBool(!paused), c.fx_audio_voice_state_frame(voice.state));
}

fn seekVoice(impl: backend.Impl, native_voice: backend.Native, frame: u64) void {
    const self = cast(impl);
    const voice = asVoice(native_voice);
    c.fx_audio_mixer_seek_stream(self.handle, voice.stream_id, frame);
    c.fx_audio_voice_state_expect(voice.state, c.fx_audio_voice_state_playing(voice.state), frame);
}

fn voiceStatus(impl: backend.Impl, native_voice: backend.Native) backend.Status {
    _ = impl;
    const state = asVoice(native_voice).state;
    return .{
        .playing = c.fx_audio_voice_state_playing(state) != 0,
        .frame = c.fx_audio_voice_state_frame(state),
        .ends = c.fx_audio_voice_state_ends(state),
    };
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

/// With a sound device attached, its thread is the one that pulls, and
/// `out` is left as it is rather than racing it.
fn mix(impl: backend.Impl, channels: u32, sample_rate: u32, out: []f32) void {
    if (cast(impl).output != null) return;
    pull(impl, channels, sample_rate, out);
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
    try testing.expectEqual(@as(u64, 1), device.clipInfo(clip).?.frames);
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    // Its one frame played, it has ended - with the mix that played it.
    var one: [1]f32 = undefined;
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.5), @abs(one[0]), 0.001);
    try testing.expect(!device.isPlaying(voice));
    try testing.expectEqual(@as(u32, 1), device.status(voice).ends);
}

/// A mono clip of `samples`, at 44100.
fn monoClip(device: *Device, samples: []const i16) !types.Clip {
    return device.loadClip(.{ .format = .pcm_s16, .bytes = std.mem.sliceAsBytes(samples), .channels = 1 });
}

test "a looping voice goes round without a gap, and never ends" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try monoClip(&device, &.{ 8192, 16384, 24576 });
    const voice = try device.play(clip, .{ .loop = true });
    defer device.stop(voice);

    var out: [7]f32 = undefined;
    device.mix(1, 44100, &out);
    const want = [_]f32{ 0.25, 0.5, 0.75, 0.25, 0.5, 0.75, 0.25 };
    for (want, out) |expected, got| try testing.expectApproxEqAbs(expected, got, 0.001);
    const status = device.status(voice);
    try testing.expect(status.playing);
    try testing.expectEqual(@as(u32, 0), status.ends);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 44100.0), status.position, 1e-9);
}

test "a voice that plays out says it ended, and where a voice is is read from any thread" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try monoClip(&device, &.{ 16384, 16384, 16384 });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);
    // Said at once, before a mix has run the play.
    try testing.expect(device.status(voice).playing);

    var out: [2]f32 = undefined;
    device.mix(1, 44100, &out);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 44100.0), device.status(voice).position, 1e-9);
    device.mix(1, 44100, &out);
    const status = device.status(voice);
    try testing.expect(!status.playing);
    try testing.expectEqual(@as(u32, 1), status.ends);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1], 0.001);
}

test "a paused voice holds its place, and goes on from it" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try monoClip(&device, &.{ 8192, 16384, 24576, 32767 });
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    var one: [1]f32 = undefined;
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.25), one[0], 0.001);
    try device.setPaused(voice, true);
    try testing.expect(!device.isPlaying(voice));
    device.mix(1, 44100, &one);
    try testing.expectEqual(@as(f32, 0), one[0]);
    try device.setPaused(voice, false);
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.5), one[0], 0.001);
}

test "a voice starts where it is asked to, or held there, and seeks" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try monoClip(&device, &.{ 8192, 16384, 24576, 32767 });
    const voice = try device.play(clip, .{ .start = 2.0 / 44100.0, .paused = true });
    defer device.stop(voice);
    try testing.expect(!device.isPlaying(voice));
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 44100.0), device.status(voice).position, 1e-9);

    try device.setPaused(voice, false);
    var one: [1]f32 = undefined;
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.75), one[0], 0.001);

    try device.seek(voice, 1.0 / 44100.0);
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.5), one[0], 0.001);
}

test "a voice at twice the speed plays its clip in half the time" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const clip = try monoClip(&device, &(.{8192} ** 64));
    const voice = try device.play(clip, .{ .speed = 2 });
    defer device.stop(voice);

    var out: [16]f32 = undefined;
    device.mix(1, 44100, &out);
    try testing.expectApproxEqAbs(@as(f64, 32.0 / 44100.0), device.status(voice).position, 1e-9);
    for (out) |sample| try testing.expectApproxEqAbs(@as(f32, 0.25), sample, 0.001);

    try device.setSpeed(voice, 0.5);
    device.mix(1, 44100, &out);
    try testing.expectApproxEqAbs(@as(f64, 40.0 / 44100.0), device.status(voice).position, 1e-9);
}

test "an MP3 is decoded as it plays, without the encoder's silence" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    // A quarter of a second of 440 Hz at 22050, mono.
    const clip = try device.loadClip(.{ .format = .mp3, .bytes = @embedFile("../testdata/tone.mp3") });
    const about = device.clipInfo(clip).?;
    try testing.expectEqual(@as(u32, 1), about.channels);
    try testing.expectEqual(@as(u32, 22050), about.sample_rate);
    try testing.expectApproxEqAbs(@as(f64, 0.25), about.seconds(), 0.01);

    const voice = try device.play(clip, .{});
    defer device.stop(voice);
    // The encoder's delay left out, the tone starts at once.
    var out: [64]f32 = undefined;
    device.mix(1, 22050, &out);
    var loudest: f32 = 0;
    for (out[32..]) |sample| loudest = @max(loudest, @abs(sample));
    try testing.expect(loudest > 0.05);

    // To the end, and it ends.
    var rest: [8192]f32 = undefined;
    device.mix(1, 22050, &rest);
    try testing.expectEqual(@as(u32, 1), device.status(voice).ends);

    // Seeking to the middle, and looping round.
    try device.setLooping(voice, true);
    try device.seek(voice, 0.2);
    try device.setPaused(voice, false);
    device.mix(1, 22050, &rest);
    try testing.expect(device.isPlaying(voice));
    try testing.expectEqual(@as(u32, 1), device.status(voice).ends);

    try testing.expectError(error.DecodeFailed, device.loadClip(.{ .format = .mp3, .bytes = "not an mp3 at all" }));
}
