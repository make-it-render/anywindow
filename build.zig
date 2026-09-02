const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x11_dep = b.dependency("z11", .{
        .target = target,
        .optimize = optimize,
    });
    const x11 = x11_dep.module("x11");

    const windows_dep = b.dependency("windowz", .{
        .target = target,
        .optimize = optimize,
    });
    const windows = windows_dep.module("windows");

    const wayland_dep = b.dependency("mir_wayland", .{
        .target = target,
        .optimize = optimize,
    });
    const wayland = wayland_dep.module("wayland");

    const any = b.addModule(
        "anywindow",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseSmall,
        },
    );
    any.addImport("x11", x11);
    any.addImport("windows", windows);
    any.addImport("wayland", wayland);

    {
        const demo_mod = b.addModule("demo", .{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseSmall,
        });
        demo_mod.addImport("anywindow", any);
        const demo = b.addExecutable(.{
            .name = "demo",
            .root_module = demo_mod,
        });

        b.installArtifact(demo);

        const run_cmd = b.addRunArtifact(demo);
        const run_step = b.step("run", "Run demo");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const verify_mod = b.addModule("verify", .{
            .root_source_file = b.path("src/verify.zig"),
            .target = target,
            .optimize = optimize,
        });
        verify_mod.addImport("anywindow", any);
        // The clipboard check plays a silent X11 selection owner from a bare connection.
        verify_mod.addImport("x11", x11);
        const verify = b.addExecutable(.{
            .name = "verify",
            .root_module = verify_mod,
        });

        const run_verify = b.addRunArtifact(verify);
        const verify_step = b.step("verify", "Verify backend features against the live display server");
        verify_step.dependOn(&run_verify.step);
    }

    {
        const tests_mod = b.addModule("tests", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/root.zig"),
        });
        const tests = b.addTest(.{
            .root_module = tests_mod,
        });
        tests.root_module.addImport("x11", x11);
        tests.root_module.addImport("windows", windows);
        tests.root_module.addImport("wayland", wayland);

        const run_tests = b.addRunArtifact(tests);
        const run_tests_step = b.step("test", "Run tests");
        run_tests_step.dependOn(&run_tests.step);
    }

    {
        const docs_mod = b.addModule("docs", .{
            .target = target,
            .optimize = .Debug,
            .root_source_file = b.path("src/root.zig"),
        });
        const docs = b.addObject(.{
            .name = "docs",
            .root_module = docs_mod,
        });
        docs.root_module.addImport("x11", x11);
        docs.root_module.addImport("windows", windows);
        docs.root_module.addImport("wayland", wayland);

        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Install documentation");
        docs_step.dependOn(&install_docs.step);
    }
}
