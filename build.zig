const std = @import("std");

const pkgs = struct {
    const hutaback = std.build.Pkg{
        .name = "hutaback",
        .source = .{ .path = "./src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            @"tigerbeetle-io",
            datetime,
            uri,
        },
    };

    const @"tigerbeetle-io" = std.build.Pkg{
        .name = "tigerbeetle-io",
        .source = .{ .path = "./lib/tigerbeetle-io/src/main.zig" },
    };

    const datetime = std.build.Pkg{
        .name = "datetime",
        .source = .{ .path = "./lib/zig-datetime/src/main.zig" },
    };

    const uri = std.build.Pkg{
        .name = "uri",
        .source = .{ .path = "./lib/zig-uri/uri.zig" },
    };
};

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary("hutaback", "src/main.zig");
    lib.addPackage(pkgs.@"tigerbeetle-io");
    lib.addPackage(pkgs.datetime);
    lib.setBuildMode(mode);
    lib.install();

    // test filter
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;

    // unit tests
    var unit_tests = b.addTest("src/main.zig");
    unit_tests.addPackage(pkgs.@"tigerbeetle-io");
    unit_tests.addPackage(pkgs.datetime);
    unit_tests.addPackage(pkgs.uri);
    unit_tests.setBuildMode(mode);
    unit_tests.filter = test_filter;
    if (coverage) {
        unit_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--include-path=./src",
            "kcov-output-unit", // output dir for kcov
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    // tests with mock IO
    var mock_tests = b.addTest("tests/mock/main.zig");
    mock_tests.addPackage(std.build.Pkg{
        .name = "tigerbeetle-io",
        .source = .{ .path = "tests/mock/mock-io.zig" },
    });
    mock_tests.addPackage(pkgs.datetime);
    mock_tests.setBuildMode(mode);
    mock_tests.filter = test_filter;
    if (coverage) {
        mock_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--include-path=./src",
            "kcov-output-mock", // output dir for kcov
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    // tests with real IO
    var real_tests = b.addTest("tests/real/main.zig");
    real_tests.addPackage(pkgs.hutaback);
    real_tests.addPackage(pkgs.@"tigerbeetle-io");
    real_tests.addPackage(pkgs.datetime);
    real_tests.setBuildMode(mode);
    real_tests.filter = test_filter;
    if (coverage) {
        real_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--include-path=./src",
            "kcov-output-real", // output dir for kcov
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    // test step
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&unit_tests.step);
    test_step.dependOn(&mock_tests.step);
    test_step.dependOn(&real_tests.step);
    if (coverage) {
        const merge_step = b.addSystemCommand(&[_][]const u8{
            "kcov",
            "--merge",
            "kcov-output",
            "kcov-output-unit",
            "kcov-output-mock",
            "kcov-output-real",
        });
        test_step.dependOn(&merge_step.step);
    }

    const examples_step = b.step("examples", "Build examples");
    inline for (.{
        "async_http_client",
        "async_http_server",
        "http_client",
        "http_proxy",
        "http_server",
    }) |example_name| {
        const example_exe = b.addExecutable(example_name, "examples/" ++ example_name ++ ".zig");
        example_exe.addPackage(pkgs.hutaback);
        example_exe.addPackage(pkgs.@"tigerbeetle-io");
        example_exe.addPackage(pkgs.datetime);
        example_exe.setBuildMode(mode);
        example_exe.setTarget(target);
        example_exe.install();
        const install_exe = b.addInstallArtifact(example_exe);
        examples_step.dependOn(&install_exe.step);
    }
}
