const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    });
    mod.addImport("soem", trans_soem.mod);

    // Workaround for wpcap library bundled in soem
    if (target.result.os.tag == .windows) {
        mod.addLibraryPath(soem.namedLazyPath("wpcap_lib_dir"));
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
