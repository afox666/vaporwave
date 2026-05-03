const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_tag = .macos,
            .cpu_arch = .aarch64,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vaporwave-sidecar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureDuckDb(b, exe);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the sidecar");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureDuckDb(b, exe_tests);
    const run_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_tests.step);
}

fn configureDuckDb(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.link_libc = true;
    compile.root_module.linkSystemLibrary("duckdb", .{});
    const lib_dirs = [_][]const u8{
        "/opt/homebrew/opt/duckdb/lib",
        "/usr/local/opt/duckdb/lib",
    };
    for (lib_dirs) |dir| {
        const dylib_path = std.fmt.allocPrint(b.allocator, "{s}/libduckdb.dylib", .{dir}) catch @panic("OOM");
        defer b.allocator.free(dylib_path);
        std.fs.accessAbsolute(dylib_path, .{}) catch continue;
        compile.root_module.addLibraryPath(.{ .cwd_relative = dir });
        compile.root_module.addRPath(.{ .cwd_relative = dir });
    }
}
