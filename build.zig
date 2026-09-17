// SPDX-License-Identifier: CC0-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const id = b.dependency("fluxion_id", .{ .target = target, .optimize = optimize });

    // The importable module. Consumers do:
    //   const audio = @import("fluxion_audio");
    const mod = b.addModule("fluxion_audio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "fluxion_id", .module = id.module("fluxion_id") },
        },
    });

    // The vendored mixer graph and its C boundary (`native/bridge.h`,
    // brought into Zig with `@cImport` rather than hand-written `extern`
    // declarations). Everything else in the module only ever sees the safe
    // Zig API in `Device.zig` - none of this is exported from the module.
    mod.addIncludePath(b.path("src/native"));
    mod.addCSourceFiles(.{
        .files = &.{
            "src/native/mixer/Bus.cpp",
            "src/native/mixer/Mixer.cpp",
            "src/native/clips/PcmClip.cpp",
            "src/native/clips/VorbisClip.cpp",
            "src/native/clips/OscillatorClip.cpp",
            "src/native/bridge.cpp",
        },
        .flags = &.{"-std=c++17"},
    });

    // The `wasapi` backend's COM calls - a base OS component on every
    // Windows install, so this is a plain link rather than the dynamic
    // loading `fluxion-platform` uses for backends a machine might lack.
    const is_windows = target.result.os.tag == .windows;
    if (is_windows) mod.linkSystemLibrary("ole32", .{});

    // The `alsa` and `opensl` backends: one per target, never both, and
    // neither one built for a target that has no way to link it.
    const is_android = target.result.abi == .android;
    const is_linux_desktop = target.result.os.tag == .linux and !is_android;
    if (is_linux_desktop) {
        mod.addCSourceFiles(.{ .files = &.{"src/native/backends/alsa.cpp"}, .flags = &.{"-std=c++17"} });
        mod.linkSystemLibrary("asound", .{});
    }
    if (is_android) {
        mod.addCSourceFiles(.{ .files = &.{"src/native/backends/opensl.cpp"}, .flags = &.{"-std=c++17"} });
        mod.linkSystemLibrary("OpenSLES", .{});
    }

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-audio-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-audio",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // zig build example-tone - makes actual sound, so it is not part of
    // `zig build test`.
    if (is_windows) {
        const tone = b.addExecutable(.{
            .name = "fluxion-audio-tone",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/tone.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fluxion_audio", .module = mod }},
            }),
        });
        b.installArtifact(tone);
        const run_tone = b.addRunArtifact(tone);
        run_tone.step.dependOn(b.getInstallStep());
        b.step("example-tone", "Play a one-second tone through WASAPI").dependOn(&run_tone.step);
    }
}
