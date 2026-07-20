const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wpcap_lib_path = b.option(
        []const u8,
        "wpcap_lib_dir",
        "Specify the dir to the wpcap static library artifact.",
    ) orelse if (target.result.cpu.arch == .x86_64)
        "vendor/wpcap/Lib/x64"
    else
        "vendor/wpcap/Lib";
    switch (target.result.os.tag) {
        .windows, .linux => {},
        else => return error.UnsupportedOs,
    }
    const translate_c = b.dependency("translate_c", .{
        .target = b.graph.host,
        .optimize = optimize,
    });

    const soem = b.dependency("soem", .{
        .target = target,
        .optimize = optimize,
        .EC_TIMEOUTRET = 1000,
    });

    const trans_soem: Translator = .init(translate_c, .{
        .c_source_file = b.addWriteFiles().add("c.h",
            \\#include <soem/soem.h>
        ),
        .target = target,
        .optimize = optimize,
    });

    trans_soem.linkLibrary(soem.artifact("soem"));

    const mod = b.addModule("board-IF", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    mod.addImport("soem", trans_soem.mod);
    // Workaround for the wrong alignment caused by #pragma pack.
    // TODO: Remove this one once the zig 0.17.0 is used. This problem might be
    // fixed with https://codeberg.org/ziglang/translate-c/commit/174a76a5b20c0fde03032d9c1cc9d4a78a6318af
    mod.addCSourceFile(.{ .file = b.path("src/soem_shim.c") });
    mod.linkLibrary(soem.artifact("soem"));

    // Building this library requires the wpcap bundled by SOEM
    if (target.result.os.tag == .windows) {
        const wpcap_lib: std.Build.LazyPath = .{ .cwd_relative = wpcap_lib_path };
        mod.addLibraryPath(wpcap_lib);
        mod.linkSystemLibrary("Packet", .{
            .preferred_link_mode = .static,
            .needed = true,
        });
        mod.linkSystemLibrary("wpcap", .{
            .preferred_link_mode = .static,
            .needed = true,
        });
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
