// PalStack — Build system for Zig 0.15+
//
// Build targets:
//   zig build test       — Run all unit tests
//   zig build showcase   — Build and run the showcase app

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── palstack-core ───────────────────────────────────────────────────

    const core_mod = b.addModule("palstack-core", .{
        .root_source_file = b.path("palstack-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── palstack-signals ────────────────────────────────────────────────

    const signals_mod = b.addModule("palstack-signals", .{
        .root_source_file = b.path("palstack-signals/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── palstack-server ─────────────────────────────────────────────────

    const server_mod = b.addModule("palstack-server", .{
        .root_source_file = b.path("palstack-server/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("palstack-core", core_mod);

    // ── palstack-db ─────────────────────────────────────────────────────

    const db_mod = b.addModule("palstack-db", .{
        .root_source_file = b.path("palstack-db/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_mod.addIncludePath(b.path("palstack-db/vendor"));
    db_mod.addImport("palstack-core", core_mod);

    // NOTE: PSX transpiler requires ziex/tree-sitter deps.
    // When those deps are declared in build.zig.zon, re-enable the transpiler block.
    // For now, the showcase app must use pre-generated routes.zig / assets.zig.
    const routes_zig_path: ?std.Build.LazyPath = null;
    const assets_zig_path: ?std.Build.LazyPath = null;



    // ── Tests ───────────────────────────────────────────────────────────

    const test_step = b.step("test", "Run all unit tests");

    // Core tests
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("palstack-core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{ .root_module = core_test_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // Signals tests
    const signals_test_mod = b.createModule(.{
        .root_source_file = b.path("palstack-signals/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const signals_tests = b.addTest(.{ .root_module = signals_test_mod });
    test_step.dependOn(&b.addRunArtifact(signals_tests).step);

    // Server tests
    const server_test_mod = b.createModule(.{
        .root_source_file = b.path("palstack-server/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_test_mod.addImport("palstack-core", core_mod);
    const server_tests = b.addTest(.{ .root_module = server_test_mod });
    test_step.dependOn(&b.addRunArtifact(server_tests).step);

    // ── Example application (only available when transpiler deps are present) ──

    if (routes_zig_path) |r_path| {
        const showcase_mod = b.createModule(.{
            .root_source_file = b.path("showcase/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        showcase_mod.addImport("palstack-core", core_mod);
        showcase_mod.addImport("palstack-signals", signals_mod);
        showcase_mod.addImport("palstack-server", server_mod);
        showcase_mod.addImport("palstack-db", db_mod);
        
        // Mount the automatically generated routes.zig file as a module
        const routes_mod = b.createModule(.{
            .root_source_file = r_path,
            .target = target,
            .optimize = optimize,
        });
        routes_mod.addImport("palstack-signals", signals_mod);
        
        const assets_mod = b.createModule(.{
            .root_source_file = assets_zig_path.?,
            .target = target,
            .optimize = optimize,
        });
        
        showcase_mod.addImport("routes", routes_mod);
        showcase_mod.addImport("assets", assets_mod);

        const showcase = b.addExecutable(.{
            .name = "palstack-showcase",
            .root_module = showcase_mod,
        });
        
        // Conditionally compile C dependencies based on target
        if (target.query.cpu_arch != .wasm32) {
            // Native Target: Link standard SQLite C amalgamation
            showcase_mod.addCSourceFile(.{
                .file = b.path("palstack-db/vendor/sqlite3.c"),
                .flags = &[_][]const u8{"-std=c99"},
            });
            showcase_mod.addIncludePath(b.path("palstack-db/vendor"));
            showcase_mod.link_libc = true;
        }
        
        b.installArtifact(showcase);

        const run_showcase = b.addRunArtifact(showcase);
        run_showcase.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_showcase.addArgs(args);
        }

        const showcase_step = b.step("showcase", "Build and run the showcase app");
        showcase_step.dependOn(&run_showcase.step);
    }
}
