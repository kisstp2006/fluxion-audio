// SPDX-License-Identifier: CC0-1.0

//! The Windows output backend: WASAPI in shared mode, on its own thread.
//!
//! It is the `mixer` backend with this attached as its `Output` - every
//! clip/voice call is the mixer's. This file's only job is turning what the
//! graph mixes into what the sound card actually wants, on a thread of its
//! own so a game thread calling `Device.play` is never the one keeping the
//! speakers fed.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const backend = @import("../backend.zig");
const mixer_backend = @import("mixer.zig");

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const Guid,
    outer: ?*anyopaque,
    cls_context: u32,
    riid: *const Guid,
    out: *?*anyopaque,
) callconv(.winapi) i32;

const cls_ctx_inproc_server: u32 = 1;
const audclnt_sharemode_shared: i32 = 0;

const Guid = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };

const clsid_mm_device_enumerator: Guid = .{ .d1 = 0xBCDE0395, .d2 = 0xE52F, .d3 = 0x467C, .d4 = .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E } };
const iid_mm_device_enumerator: Guid = .{ .d1 = 0xA95664D2, .d2 = 0x9614, .d3 = 0x4F35, .d4 = .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 } };
const iid_audio_client: Guid = .{ .d1 = 0x1CB9AD4C, .d2 = 0xDBFA, .d3 = 0x4c32, .d4 = .{ 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2 } };
const iid_audio_render_client: Guid = .{ .d1 = 0xF294ACFC, .d2 = 0x3146, .d3 = 0x4483, .d4 = .{ 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2 } };

const WaveFormatEx = extern struct {
    format_tag: u16,
    channels: u16,
    samples_per_sec: u32,
    avg_bytes_per_sec: u32,
    block_align: u16,
    bits_per_sample: u16,
    cb_size: u16 = 0,
};

// Only the vtable slots this file actually calls are given a real type;
// everything before them just has to be the right number of pointers wide
// to keep the slots that follow at their true offset.
const IMMDeviceEnumerator = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        unused_query_interface: *const anyopaque,
        unused_add_ref: *const anyopaque,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        unused_enum_audio_endpoints: *const anyopaque,
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, data_flow: u32, role: u32, out: *?*IMMDevice) callconv(.winapi) i32,
    };
};

const IMMDevice = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        unused_query_interface: *const anyopaque,
        unused_add_ref: *const anyopaque,
        Release: *const fn (*IMMDevice) callconv(.winapi) u32,
        Activate: *const fn (*IMMDevice, iid: *const Guid, cls_context: u32, activation_params: ?*anyopaque, out: *?*anyopaque) callconv(.winapi) i32,
    };
};

const IAudioClient = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        unused_query_interface: *const anyopaque,
        unused_add_ref: *const anyopaque,
        Release: *const fn (*IAudioClient) callconv(.winapi) u32,
        Initialize: *const fn (*IAudioClient, share_mode: i32, stream_flags: u32, buffer_duration: i64, periodicity: i64, format: *const WaveFormatEx, session_guid: ?*const Guid) callconv(.winapi) i32,
        GetBufferSize: *const fn (*IAudioClient, *u32) callconv(.winapi) i32,
        unused_get_stream_latency: *const anyopaque,
        GetCurrentPadding: *const fn (*IAudioClient, *u32) callconv(.winapi) i32,
        unused_is_format_supported: *const anyopaque,
        GetMixFormat: *const fn (*IAudioClient, *?*WaveFormatEx) callconv(.winapi) i32,
        unused_get_device_period: *const anyopaque,
        Start: *const fn (*IAudioClient) callconv(.winapi) i32,
        Stop: *const fn (*IAudioClient) callconv(.winapi) i32,
        unused_reset: *const anyopaque,
        unused_set_event_handle: *const anyopaque,
        GetService: *const fn (*IAudioClient, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) i32,
    };
};

const IAudioRenderClient = extern struct {
    vtable: *const Vtbl,
    const Vtbl = extern struct {
        unused_query_interface: *const anyopaque,
        unused_add_ref: *const anyopaque,
        Release: *const fn (*IAudioRenderClient) callconv(.winapi) u32,
        GetBuffer: *const fn (*IAudioRenderClient, num_frames: u32, out: *?[*]u8) callconv(.winapi) i32,
        ReleaseBuffer: *const fn (*IAudioRenderClient, num_frames: u32, flags: u32) callconv(.winapi) i32,
    };
};

/// A 200ms shared-mode buffer, in the 100ns units WASAPI wants.
const buffer_duration: i64 = 200 * 10_000;
const poll_interval_ms: u32 = 20;

const Session = struct {
    enumerator: *IMMDeviceEnumerator,
    device: *IMMDevice,
    client: *IAudioClient,
    render: *IAudioRenderClient,
    mix_format: *WaveFormatEx,
    buffer_frames: u32,

    fn open() !Session {
        if (CoInitializeEx(null, 0) < 0) return error.Failed;
        errdefer CoUninitialize();

        var enumerator_opt: ?*anyopaque = null;
        if (CoCreateInstance(&clsid_mm_device_enumerator, null, cls_ctx_inproc_server, &iid_mm_device_enumerator, &enumerator_opt) < 0)
            return error.NoDevice;
        const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enumerator_opt.?));
        errdefer _ = enumerator.vtable.Release(enumerator);

        var device_opt: ?*IMMDevice = null;
        if (enumerator.vtable.GetDefaultAudioEndpoint(enumerator, 0, 0, &device_opt) < 0)
            return error.NoDevice;
        const device = device_opt orelse return error.NoDevice;
        errdefer _ = device.vtable.Release(device);

        var client_opt: ?*anyopaque = null;
        if (device.vtable.Activate(device, &iid_audio_client, cls_ctx_inproc_server, null, &client_opt) < 0)
            return error.NoDevice;
        const client: *IAudioClient = @ptrCast(@alignCast(client_opt.?));
        errdefer _ = client.vtable.Release(client);

        var mix_format_opt: ?*WaveFormatEx = null;
        if (client.vtable.GetMixFormat(client, &mix_format_opt) < 0) return error.NoDevice;
        const mix_format = mix_format_opt orelse return error.NoDevice;
        errdefer CoTaskMemFree(mix_format);

        // Only float32 or int16 output is understood below - both are what
        // a real Windows install actually reports here, but a codec this
        // library has never seen is refused rather than written blind.
        if (mix_format.bits_per_sample != 32 and mix_format.bits_per_sample != 16)
            return error.Unsupported;

        if (client.vtable.Initialize(client, audclnt_sharemode_shared, 0, buffer_duration, 0, mix_format, null) < 0)
            return error.NoDevice;

        var buffer_frames: u32 = 0;
        if (client.vtable.GetBufferSize(client, &buffer_frames) < 0) return error.NoDevice;

        var render_opt: ?*anyopaque = null;
        if (client.vtable.GetService(client, &iid_audio_render_client, &render_opt) < 0) return error.NoDevice;
        const render: *IAudioRenderClient = @ptrCast(@alignCast(render_opt.?));
        errdefer _ = render.vtable.Release(render);

        if (client.vtable.Start(client) < 0) return error.NoDevice;

        return .{
            .enumerator = enumerator,
            .device = device,
            .client = client,
            .render = render,
            .mix_format = mix_format,
            .buffer_frames = buffer_frames,
        };
    }

    fn close(self: Session) void {
        _ = self.client.vtable.Stop(self.client);
        _ = self.render.vtable.Release(self.render);
        CoTaskMemFree(self.mix_format);
        _ = self.client.vtable.Release(self.client);
        _ = self.device.vtable.Release(self.device);
        _ = self.enumerator.vtable.Release(self.enumerator);
        CoUninitialize();
    }

    fn pump(self: Session, wasapi: *Wasapi, scratch: []f32) !void {
        var padding: u32 = 0;
        if (self.client.vtable.GetCurrentPadding(self.client, &padding) < 0) return error.DeviceLost;
        const available = self.buffer_frames - padding;
        if (available == 0) return;

        var data: ?[*]u8 = null;
        if (self.render.vtable.GetBuffer(self.render, available, &data) < 0) return error.DeviceLost;

        const channels = self.mix_format.channels;
        const planar = scratch[0 .. @as(usize, available) * channels];
        mixer_backend.pull(wasapi.mixer, channels, self.mix_format.samples_per_sec, planar);

        if (self.mix_format.bits_per_sample == 32) {
            const out: [*]f32 = @ptrCast(@alignCast(data.?));
            for (0..available) |frame|
                for (0..channels) |ch| {
                    out[frame * channels + ch] = planar[@as(usize, ch) * available + frame];
                };
        } else {
            const out: [*]i16 = @ptrCast(@alignCast(data.?));
            for (0..available) |frame|
                for (0..channels) |ch| {
                    const s = std.math.clamp(planar[@as(usize, ch) * available + frame], -1.0, 1.0);
                    out[frame * channels + ch] = @intFromFloat(s * 32767.0);
                };
        }

        _ = self.render.vtable.ReleaseBuffer(self.render, available, 0);
    }
};

const State = enum(u8) { starting, ready, failed };

const Wasapi = struct {
    gpa: Allocator,
    /// The graph this feeds from: the `mixer` backend's own state.
    mixer: backend.Impl,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    state: std.atomic.Value(State),
};

pub fn open(gpa: Allocator, desc: types.DeviceDesc) backend.Error!backend.Opened {
    const opened = try mixer_backend.open(gpa, desc);
    errdefer opened[1].deinit(opened[0]);

    const self = try gpa.create(Wasapi);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .mixer = opened[0],
        .thread = undefined,
        .stop_flag = std.atomic.Value(bool).init(false),
        .state = std.atomic.Value(State).init(.starting),
    };

    self.thread = std.Thread.spawn(.{}, renderThread, .{self}) catch return error.Failed;
    while (self.state.load(.acquire) == .starting) Sleep(1);
    if (self.state.load(.acquire) == .failed) {
        self.thread.join();
        return error.NoDevice;
    }

    mixer_backend.attach(opened[0], .{
        .context = self,
        .close = close,
        .info = .{ .backend = .wasapi, .device_name = "WASAPI default render endpoint" },
    });
    return opened;
}

fn renderThread(self: *Wasapi) void {
    const session = Session.open() catch {
        self.state.store(.failed, .release);
        return;
    };
    defer session.close();

    const scratch = self.gpa.alloc(f32, @as(usize, session.buffer_frames) * session.mix_format.channels) catch {
        self.state.store(.failed, .release);
        return;
    };
    defer self.gpa.free(scratch);

    self.state.store(.ready, .release);

    while (!self.stop_flag.load(.acquire)) {
        Sleep(poll_interval_ms);
        session.pump(self, scratch) catch break;
    }
}

fn close(context: *anyopaque) void {
    const self: *Wasapi = @ptrCast(@alignCast(context));
    self.stop_flag.store(true, .release);
    self.thread.join();
    self.gpa.destroy(self);
}
