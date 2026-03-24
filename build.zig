const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zwasm_dep = b.dependency("zwasm", .{
        .target = target,
        .optimize = optimize,
        .jit = false,
    });
    const spider_protocol_mod = b.addModule("spider-protocol", .{
        .root_source_file = b.path("deps/spider-protocol/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    spider_protocol_mod.addImport("zwasm", zwasm_dep.module("zwasm"));
    const spiderweb_fs_mod = b.addModule("spiderweb_fs", .{
        .root_source_file = b.path("deps/spider-protocol/src/spiderweb_fs/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    spiderweb_fs_mod.addImport("spider-protocol", spider_protocol_mod);
    const spiderweb_node_mod = b.addModule("spiderweb_node", .{
        .root_source_file = b.path("src/spiderweb_node/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    spiderweb_node_mod.addImport("spider-protocol", spider_protocol_mod);
    spiderweb_node_mod.addImport("spiderweb_fs", spiderweb_fs_mod);
    spiderweb_node_mod.addImport("zwasm", zwasm_dep.module("zwasm"));

    const node_main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    node_main_mod.addImport("spiderweb_node", spiderweb_node_mod);

    const spider_node = b.addExecutable(.{
        .name = "spiderweb-fs-node",
        .root_module = node_main_mod,
    });
    spider_node.linkLibC();
    b.installArtifact(spider_node);

    const echo_driver_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/echo_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    const echo_driver = b.addExecutable(.{
        .name = "spiderweb-echo-driver",
        .root_module = echo_driver_mod,
    });
    echo_driver.linkLibC();
    b.installArtifact(echo_driver);

    const web_search_driver_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/web_search_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    const web_search_driver = b.addExecutable(.{
        .name = "spiderweb-web-search-driver",
        .root_module = web_search_driver_mod,
    });
    web_search_driver.linkLibC();
    b.installArtifact(web_search_driver);

    const computer_driver_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/computer_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    computer_driver_mod.addImport("spiderweb_node", spiderweb_node_mod);
    const computer_driver = b.addExecutable(.{
        .name = "spiderweb-computer-driver",
        .root_module = computer_driver_mod,
    });
    computer_driver.linkLibC();
    if (target.result.os.tag == .macos) {
        computer_driver.linkFramework("ApplicationServices");
    }
    b.installArtifact(computer_driver);

    const browser_driver_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/browser_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_driver_mod.addImport("spiderweb_node", spiderweb_node_mod);
    const browser_driver = b.addExecutable(.{
        .name = "spiderweb-browser-driver",
        .root_module = browser_driver_mod,
    });
    browser_driver.linkLibC();
    if (target.result.os.tag == .macos) {
        browser_driver.linkFramework("ApplicationServices");
    }
    b.installArtifact(browser_driver);

    const echo_inproc_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/echo_inproc_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    const echo_inproc = b.addLibrary(.{
        .name = "spiderweb-echo-driver-inproc",
        .root_module = echo_inproc_mod,
        .linkage = .dynamic,
    });
    echo_inproc.linkLibC();
    b.installArtifact(echo_inproc);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const echo_wasm_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/echo_wasi_driver.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const echo_wasm = b.addExecutable(.{
        .name = "spiderweb-echo-driver-wasm",
        .root_module = echo_wasm_mod,
    });
    b.installArtifact(echo_wasm);

    const chat_wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const chat_wasm_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/chat_venom_driver.zig"),
        .target = chat_wasm_target,
        .optimize = optimize,
    });
    const chat_wasm = b.addExecutable(.{
        .name = "spiderweb-chat-driver-wasm",
        .root_module = chat_wasm_mod,
    });
    chat_wasm.entry = .disabled;
    chat_wasm.rdynamic = true;
    chat_wasm.export_memory = true;
    b.installArtifact(chat_wasm);

    const run_cmd = b.addRunArtifact(spider_node);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run spiderweb-fs-node");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("spiderweb_node", spiderweb_node_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const computer_driver_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/computer_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    computer_driver_test_mod.addImport("spiderweb_node", spiderweb_node_mod);
    const computer_driver_tests = b.addTest(.{ .root_module = computer_driver_test_mod });
    computer_driver_tests.linkLibC();
    if (target.result.os.tag == .macos) {
        computer_driver_tests.linkFramework("ApplicationServices");
    }
    const run_computer_driver_tests = b.addRunArtifact(computer_driver_tests);

    const browser_driver_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/drivers/browser_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_driver_test_mod.addImport("spiderweb_node", spiderweb_node_mod);
    const browser_driver_tests = b.addTest(.{ .root_module = browser_driver_test_mod });
    browser_driver_tests.linkLibC();
    if (target.result.os.tag == .macos) {
        browser_driver_tests.linkFramework("ApplicationServices");
    }
    const run_browser_driver_tests = b.addRunArtifact(browser_driver_tests);

    const test_step = b.step("test", "Run node wrapper tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_computer_driver_tests.step);
    test_step.dependOn(&run_browser_driver_tests.step);
}
