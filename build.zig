const std = @import("std");

pub fn build(b: *std.Build) void {
    const dizzy = b.addModule("dizzy", .{
        .root_source_file = b.path("dizzy.zig"),
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("test.zig"),
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    });
    tests.root_module.addImport("dizzy", dizzy);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
