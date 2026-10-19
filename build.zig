const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm_include_dir = b.option([]const u8, "llvm-include-dir", "LLVM C API include directory.") orelse "/usr/lib/llvm-20/include";
    const llvm_lib_dir = b.option([]const u8, "llvm-lib-dir", "LLVM library directory.") orelse "/usr/lib/llvm-20/lib";
    const llvm_lib_name = b.option([]const u8, "llvm-lib-name", "LLVM system library name.") orelse "LLVM-20";
    // NOTE(Zig 0.17): sci-style `-Dllvm` bootstrap switch. When false, link the
    // local stub instead of LLVM (same C ABI, runtime "backend disabled" error).
    const enable_llvm = b.option(bool, "llvm", "Link the LLVM-C backend (needs LLVM dev headers/lib). Use -Dllvm=false for bootstrap.") orelse true;
    validateLlvmConfig(b, enable_llvm, llvm_include_dir, llvm_lib_dir, llvm_lib_name);
    const sa_repo_root_opt = b.option([]const u8, "sa-repo-root", "SA repository root used to resolve sa_std imports.") orelse "../sci";
    const sa_repo_root = if (std.fs.path.isAbsolute(sa_repo_root_opt)) sa_repo_root_opt else blk: {
        const root_path = b.root.root_dir.path orelse ".";
        break :blk std.fs.path.resolve(b.allocator, &.{ root_path, sa_repo_root_opt }) catch @panic("OOM");
    };
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "repo_root", sa_repo_root);
    const build_options_module = build_options.createModule();

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sax_vite_api = b.createModule(.{
        .root_source_file = b.path("../sa_plugin_sax/src/vite_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sla_handler_bridge = b.createModule(.{
        .root_source_file = b.path("../sa_plugin_sla/src/handler_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sio_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ "../sci", "src", "sa_io.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    sax_vite_api.addImport("build_options", build_options_module);
    sax_vite_api.addImport("sla_handler_bridge", sla_handler_bridge);
    sax_vite_api.addImport("sio", sio_module);
    sla_handler_bridge.addImport("sio", sio_module);
    const react_vite_api = b.createModule(.{
        .root_source_file = b.path("../sa_plugin_react/src/vite_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    react_vite_api.addImport("build_options", build_options_module);
    react_vite_api.addImport("sla_handler_bridge", sla_handler_bridge);
    react_vite_api.addImport("sio", sio_module);
    const http_vite_api = b.createModule(.{
        .root_source_file = b.path("../sa_plugin_http_server/src/vite_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    http_vite_api.addImport("sio", sio_module);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addImport("sax_vite_api", sax_vite_api);
    root_module.addImport("react_vite_api", react_vite_api);
    root_module.addImport("http_vite_api", http_vite_api);
    root_module.addImport("sio", sio_module);
    root_module.addImport("build_options", build_options_module);
    addLlvmcSupportToModule(b, root_module, enable_llvm, llvm_include_dir, llvm_lib_dir, llvm_lib_name);

    const lib = b.addLibrary(.{
        .name = "vite",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(b.getInstallStep());
}

fn addLlvmcSupportToModule(
    b: *std.Build,
    module: *std.Build.Module,
    enable_llvm: bool,
    include_dir: []const u8,
    lib_dir: []const u8,
    lib_name: []const u8,
) void {
    if (enable_llvm) {
        module.addCSourceFile(.{ .file = b.path("../sa_plugin_sax/src/emit_llvm_llvmc_shim.c"), .flags = &.{} });
        linkLLVMToModule(module, include_dir, lib_dir, lib_name);
    } else {
        module.addCSourceFile(.{ .file = b.path("src/emit_llvm_llvmc_stub.c"), .flags = &.{"-fno-sanitize=all"} });
    }
}

fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

fn validateLlvmConfig(b: *std.Build, enable_llvm: bool, include_dir: []const u8, lib_dir: []const u8, lib_name: []const u8) void {
    if (!enable_llvm) return;
    const io = b.graph.io;
    const core_header = std.fs.path.join(b.allocator, &.{ include_dir, "llvm-c", "Core.h" }) catch
        failLlvmConfig("failed to construct LLVM include path", .{});
    defer b.allocator.free(core_header);
    if (!pathExists(io, core_header)) {
        failLlvmConfig("LLVM-C header not found: {s}\n  pass -Dllvm-include-dir=<path> or use -Dllvm=false for bootstrap", .{core_header});
    }
    if (!pathExists(io, lib_dir)) {
        failLlvmConfig("LLVM library directory not found: {s}\n  pass -Dllvm-lib-dir=<path> or use -Dllvm=false for bootstrap", .{lib_dir});
    }
    const candidates = [_][]const u8{
        lib_name,
        b.fmt("lib{s}.so", .{lib_name}),
        b.fmt("lib{s}.a", .{lib_name}),
    };
    for (candidates) |candidate| {
        const p = std.fs.path.join(b.allocator, &.{ lib_dir, candidate }) catch continue;
        defer b.allocator.free(p);
        if (pathExists(io, p)) return;
    }
    failLlvmConfig("LLVM library not found in {s} for -Dllvm-lib-name={s}\n  pass explicit LLVM paths or use -Dllvm=false for bootstrap", .{ lib_dir, lib_name });
}

fn failLlvmConfig(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: LLVM-C backend configuration failed\n  " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn addLlvmcShimToModule(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("../sa_plugin_sax/src/emit_llvm_llvmc_shim.c"), .flags = &.{} });
}

fn linkLLVMToModule(module: *std.Build.Module, include_dir: []const u8, lib_dir: []const u8, lib_name: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = include_dir });
    module.addLibraryPath(.{ .cwd_relative = lib_dir });
    module.linkSystemLibrary(lib_name, .{});
}
