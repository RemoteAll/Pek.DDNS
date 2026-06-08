const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 动态生成 Windows 清单：请求管理员权限 ──
    // 修改 hosts 文件需要 SYSTEM 目录写入权限，必须提权
    const manifest_content =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        \\  <assemblyIdentity version="1.0.0.0" name="Zig_FixHosts"/>
        \\  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
        \\    <security>
        \\      <requestedPrivileges>
        \\        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
        \\      </requestedPrivileges>
        \\    </security>
        \\  </trustInfo>
        \\</assembly>
    ;
    const wf = b.addWriteFiles();
    const manifest_path = wf.add("require_admin.manifest", manifest_content);

    const exe = b.addExecutable(.{
        .name = "Zig_FixHosts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = manifest_path,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "运行 Zig_FixHosts");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_step = b.step("test", "运行单元测试");
    const test_artifact = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_test = b.addRunArtifact(test_artifact);
    test_step.dependOn(&run_test.step);
}
