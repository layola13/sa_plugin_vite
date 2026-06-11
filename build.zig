const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm_include_dir = b.option([]const u8, "llvm-include-dir", "LLVM C API include directory.") orelse "/usr/lib/llvm-14/include";
    const llvm_lib_dir = b.option([]const u8, "llvm-lib-dir", "LLVM library directory.") orelse "/usr/lib/llvm-14/lib";
    const llvm_lib_name = b.option([]const u8, "llvm-lib-name", "LLVM system library name.") orelse "LLVM-14";
    const sa_repo_root = b.option([]const u8, "sa-repo-root", "SA repository root used to resolve sa_std imports.") orelse "/home/vscode/projects/sci";
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
    sax_vite_api.addImport("build_options", build_options_module);
    const react_vite_api = b.createModule(.{
        .root_source_file = b.path("../sa_plugin_react/src/vite_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    react_vite_api.addImport("build_options", build_options_module);
    const http_vite_api = b.createModule(.{
        .root_source_file = b.path("../sa_plugin_http_server/src/vite_api.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    addLlvmcShimToModule(b, root_module);
    linkLLVMToModule(root_module, llvm_include_dir, llvm_lib_dir, llvm_lib_name);

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

fn addLlvmcShimToModule(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("../sa_plugin_sax/src/emit_llvm_llvmc_shim.c"), .flags = &.{} });
}

fn linkLLVMToModule(module: *std.Build.Module, include_dir: []const u8, lib_dir: []const u8, lib_name: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = include_dir });
    module.addLibraryPath(.{ .cwd_relative = lib_dir });
    module.linkSystemLibrary(lib_name, .{});
}
