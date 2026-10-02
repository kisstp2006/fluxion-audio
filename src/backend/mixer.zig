// SPDX-License-Identifier: CC0-1.0

//! The mixer graph (`mixer/Graph.zig`), wired up so a clip is a `Data`, a
//! voice is a `Stream` feeding its own bus (with a gain, a pan and a
//! pitch-shift processor on it) into the master bus. `Device.mix` pulls the
//! result.
//!
//! On its own it writes to no sound device. The output backends - `wasapi`,
//! `alsa`, `opensl`, `web` - are this graph with an `Output` attached: what
//! pulls from it and feeds the sound card, on a thread of its own or as the
//! browser asks, closed before the graph goes. Every other call is this
//! file's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const Graph = @import("../mixer/Graph.zig");

/// A sound device fed from the graph.
pub const Output = struct {
    context: *anyopaque,
    /// Stops what pulls, and lets the device go.
    close: *const fn (context: *anyopaque) void,
    info: types.Info,
};

const Mixer = struct {
    gpa: Allocator,
    graph: Graph,
    master_bus_id: Graph.Id,
    output: ?Output = null,
};

/// The five graph objects behind one playing voice: a stream reading the
/// clip, a private bus so the voice has somewhere to hang its own gain, pan
/// and pitch-shift, and those three processors - and what the stream says
/// of itself as it plays.
const Voice = struct {
    // Zero until made, so a voice half made can be let go of like a whole one.
    stream_id: Graph.Id = 0,
    bus_id: Graph.Id = 0,
    gain_id: Graph.Id = 0,
    pan_id: Graph.Id = 0,
    pitch_id: Graph.Id = 0,
    state: ?*Graph.VoiceState = null,

    /// Every object of it out of the graph, and its hold on its state let go.
    fn forget(self: *Voice, graph: *Graph) void {
        for ([_]Graph.Id{ self.pitch_id, self.pan_id, self.gain_id, self.bus_id, self.stream_id }) |id| {
            if (id != 0) graph.delete(id);
        }
        if (self.state) |state| state.release(graph.gpa);
    }
};

/// A submix: a bus of its own with a gain processor for its volume, feeding
/// the master bus or another submix.
const Submix = struct {
    bus_id: Graph.Id,
    gain_id: Graph.Id,
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    _ = desc;
    const self = try gpa.create(Mixer);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .graph = .init(gpa), .master_bus_id = 0 };
    errdefer self.graph.deinit();

    self.master_bus_id = self.graph.nextId();
    try self.graph.submit(.{ .init_bus = self.master_bus_id });
    try self.graph.submit(.{ .set_master_bus = self.master_bus_id });
    return .{ self, &vtable };
}

/// Hand the graph `impl` - one `open` returned - to a sound device: from here
/// `Device.mix` leaves its buffer alone, and the device is closed with the
/// graph.
pub fn attach(impl: backend.Impl, output: Output) void {
    cast(impl).output = output;
}

/// Mix into `out` for a sound device: what an `Output` calls.
pub fn pull(impl: backend.Impl, channels: u32, sample_rate: u32, out: []f32) void {
    const self = cast(impl);
    self.graph.getSamples(@intCast(out.len / channels), channels, sample_rate, out);
}

/// `pull`, for a device written in C: `impl` as the context, and `frames`
/// frames of `channels` into `out`, planar by channel.
pub fn pullFromC(impl: ?*anyopaque, frames: u32, channels: u32, sample_rate: u32, out: [*c]f32) callconv(.c) void {
    pull(impl.?, channels, sample_rate, out[0 .. @as(usize, frames) * channels]);
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
    .setVoiceOutput = setVoiceOutput,
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

fn deinit(impl: backend.Impl) void {
    const self = cast(impl);
    // The device reads the graph: it stops first.
    if (self.output) |output| output.close(output.context);
    self.graph.deinit();
    self.gpa.destroy(self);
}

fn info(impl: backend.Impl) types.Info {
    const self = cast(impl);
    if (self.output) |output| return output.info;
    return .{ .backend = .mixer, .device_name = "mixer graph, no sound device" };
}

fn loadClip(impl: backend.Impl, desc: types.ClipDesc) backend.Error!backend.Loaded {
    const self = cast(impl);
    const data: *Graph.Data = switch (desc.format) {
        .pcm_s16 => blk: {
            // Interleaved S16, byte-aligned and not necessarily i16-aligned,
            // deinterleaved into the mixer's own planar-float layout - int16
            // min/max is asymmetric, so this scales by 32768 both ways rather
            // than by the max positive value, which keeps -1.0 reachable.
            const channels = desc.channels;
            const frame_count = desc.bytes.len / 2 / channels;

            const planar = try self.gpa.alloc(f32, frame_count * channels);
            defer self.gpa.free(planar);

            for (0..frame_count) |frame| {
                for (0..channels) |channel| {
                    const offset = (frame * channels + channel) * 2;
                    const sample = std.mem.readInt(i16, desc.bytes[offset..][0..2], .little);
                    planar[channel * frame_count + frame] = @as(f32, @floatFromInt(sample)) / 32768.0;
                }
            }
            break :blk try Graph.Data.initPcm(self.gpa, channels, desc.sample_rate, planar);
        },
        .pcm_f32 => try Graph.Data.initPcm(self.gpa, desc.channels, desc.sample_rate, desc.samples),
        .vorbis => try Graph.Data.initVorbis(self.gpa, desc.bytes),
        .mp3 => try Graph.Data.initMp3(self.gpa, desc.bytes),
        .wav => unreachable,
    };
    const said: types.ClipInfo = .{ .channels = data.channels, .sample_rate = data.sample_rate, .frames = data.frames() };
    const data_id = self.graph.nextId();
    try self.graph.submit(.{ .init_data = .{ .id = data_id, .data = data } });
    return .{ .native = @ptrFromInt(data_id), .info = said };
}

fn loadOscillator(impl: backend.Impl, desc: types.OscillatorDesc) backend.Error!backend.Loaded {
    const self = cast(impl);
    const data = try Graph.Data.initOscillator(self.gpa, desc);
    const data_id = self.graph.nextId();
    try self.graph.submit(.{ .init_data = .{ .id = data_id, .data = data } });
    return .{ .native = @ptrFromInt(data_id), .info = .{ .channels = 1, .sample_rate = desc.sample_rate, .frames = types.oscillatorFrames(desc) } };
}

fn unloadClip(impl: backend.Impl, native_clip: backend.Native) void {
    cast(impl).graph.delete(@intFromPtr(native_clip));
}

fn play(impl: backend.Impl, clip: backend.Native, output: ?backend.Native, desc: types.PlayDesc, start: u64) backend.Error!backend.Native {
    const self = cast(impl);
    const graph = &self.graph;
    const data_id = @intFromPtr(clip);
    const output_bus_id = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;

    const voice = try self.gpa.create(Voice);
    errdefer self.gpa.destroy(voice);
    voice.* = .{};
    errdefer voice.forget(graph);

    voice.stream_id = graph.nextId();
    const state = try graph.initStream(voice.stream_id, data_id);
    voice.state = state;

    voice.bus_id = graph.nextId();
    try graph.submit(.{ .init_bus = voice.bus_id });
    graph.send(.{ .set_stream_output = .{ .id = voice.stream_id, .bus = voice.bus_id } });
    graph.send(.{ .set_bus_output = .{ .bus = voice.bus_id, .output = output_bus_id } });

    voice.gain_id = try processor(graph, voice.bus_id, .{ .gain = desc.volume });
    voice.pan_id = try processor(graph, voice.bus_id, .{ .pan = desc.pan });
    voice.pitch_id = try processor(graph, voice.bus_id, .{ .pitch = .{ .pitch = desc.pitch } });

    if (desc.loop) graph.send(.{ .set_stream_looping = .{ .id = voice.stream_id, .looping = true } });
    if (desc.speed != 1) graph.send(.{ .set_stream_speed = .{ .id = voice.stream_id, .speed = @max(desc.speed, 0.01) } });
    if (start > 0) graph.send(.{ .seek_stream = .{ .id = voice.stream_id, .frame = start } });
    if (!desc.paused) graph.send(.{ .play_stream = voice.stream_id });
    state.expect(!desc.paused, start);

    return voice;
}

/// A processor of `kind` made, and put on bus `bus_id`.
fn processor(graph: *Graph, bus_id: Graph.Id, kind: Graph.Processor.Kind) backend.Error!Graph.Id {
    const made = try Graph.Processor.create(graph.gpa, kind);
    const id = graph.nextId();
    errdefer graph.delete(id);
    try graph.submit(.{ .init_processor = .{ .id = id, .processor = made } });
    graph.send(.{ .add_processor = .{ .bus = bus_id, .processor = id } });
    return id;
}

fn asVoice(native_voice: backend.Native) *Voice {
    return @ptrCast(@alignCast(native_voice));
}

fn stopVoice(impl: backend.Impl, native_voice: backend.Native) void {
    const self = cast(impl);
    const voice = asVoice(native_voice);
    voice.forget(&self.graph);
    self.gpa.destroy(voice);
}

fn setVoiceVolume(impl: backend.Impl, native_voice: backend.Native, volume: f32) void {
    cast(impl).graph.send(.{ .set_gain = .{ .id = asVoice(native_voice).gain_id, .value = volume } });
}

fn setVoicePan(impl: backend.Impl, native_voice: backend.Native, pan: f32) void {
    cast(impl).graph.send(.{ .set_pan = .{ .id = asVoice(native_voice).pan_id, .value = pan } });
}

fn setVoicePitch(impl: backend.Impl, native_voice: backend.Native, pitch: f32) void {
    cast(impl).graph.send(.{ .set_pitch = .{ .id = asVoice(native_voice).pitch_id, .value = pitch } });
}

fn setVoiceSpeed(impl: backend.Impl, native_voice: backend.Native, speed: f32) void {
    cast(impl).graph.send(.{ .set_stream_speed = .{ .id = asVoice(native_voice).stream_id, .speed = speed } });
}

fn setVoiceLooping(impl: backend.Impl, native_voice: backend.Native, looping: bool) void {
    cast(impl).graph.send(.{ .set_stream_looping = .{ .id = asVoice(native_voice).stream_id, .looping = looping } });
}

fn setVoicePaused(impl: backend.Impl, native_voice: backend.Native, paused: bool) void {
    const self = cast(impl);
    const voice = asVoice(native_voice);
    if (paused) {
        self.graph.send(.{ .stop_stream = .{ .id = voice.stream_id, .reset = false } });
    } else self.graph.send(.{ .play_stream = voice.stream_id });
    const state = voice.state.?;
    state.expect(!paused, state.frame());
}

fn seekVoice(impl: backend.Impl, native_voice: backend.Native, frame: u64) void {
    const self = cast(impl);
    const voice = asVoice(native_voice);
    self.graph.send(.{ .seek_stream = .{ .id = voice.stream_id, .frame = frame } });
    const state = voice.state.?;
    state.expect(state.playing(), frame);
}

fn setVoiceOutput(impl: backend.Impl, native_voice: backend.Native, output: ?backend.Native) void {
    const self = cast(impl);
    const output_bus_id = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;
    self.graph.send(.{ .set_bus_output = .{ .bus = asVoice(native_voice).bus_id, .output = output_bus_id } });
}

fn voiceStatus(impl: backend.Impl, native_voice: backend.Native) backend.Status {
    _ = impl;
    const state = asVoice(native_voice).state.?;
    return .{ .playing = state.playing(), .frame = state.frame(), .ends = state.ends() };
}

fn asSubmix(native_submix: backend.Native) *Submix {
    return @ptrCast(@alignCast(native_submix));
}

fn createSubmix(impl: backend.Impl, output: ?backend.Native, volume: f32) backend.Error!backend.Native {
    const self = cast(impl);
    const output_bus_id = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;

    const submix = try self.gpa.create(Submix);
    errdefer self.gpa.destroy(submix);

    submix.bus_id = self.graph.nextId();
    errdefer self.graph.delete(submix.bus_id);
    try self.graph.submit(.{ .init_bus = submix.bus_id });
    self.graph.send(.{ .set_bus_output = .{ .bus = submix.bus_id, .output = output_bus_id } });
    submix.gain_id = try processor(&self.graph, submix.bus_id, .{ .gain = volume });
    return submix;
}

fn destroySubmix(impl: backend.Impl, native_submix: backend.Native) void {
    const self = cast(impl);
    const submix = asSubmix(native_submix);
    self.graph.delete(submix.gain_id);
    self.graph.delete(submix.bus_id);
    self.gpa.destroy(submix);
}

fn setSubmixVolume(impl: backend.Impl, native_submix: backend.Native, volume: f32) void {
    cast(impl).graph.send(.{ .set_gain = .{ .id = asSubmix(native_submix).gain_id, .value = volume } });
}

fn setSubmixOutput(impl: backend.Impl, native_submix: backend.Native, output: ?backend.Native) void {
    const self = cast(impl);
    const output_bus_id = if (output) |o| asSubmix(o).bus_id else self.master_bus_id;
    self.graph.send(.{ .set_bus_output = .{ .bus = asSubmix(native_submix).bus_id, .output = output_bus_id } });
}

/// With a sound device attached, it is the one that pulls, and `out` is
/// left as it is rather than racing it.
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

test "a playing voice is moved into a submix, and takes its volume from there" {
    var device = try Device.init(testing.allocator, .{ .backend = .mixer });
    defer device.deinit();

    const quiet = try device.createSubmix(.{ .volume = 0.5 });
    defer device.destroySubmix(quiet);
    const clip = try monoClip(&device, &(.{16384} ** 4));
    const voice = try device.play(clip, .{});
    defer device.stop(voice);

    var one: [1]f32 = undefined;
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.5), one[0], 0.001);
    try device.setOutput(voice, quiet);
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.25), one[0], 0.001);
    try device.setOutput(voice, null);
    device.mix(1, 44100, &one);
    try testing.expectApproxEqAbs(@as(f32, 0.5), one[0], 0.001);
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
