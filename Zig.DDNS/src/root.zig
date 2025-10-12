//! DDNS 库入口，导出配置与运行方法，并提供可扩展的 Provider 接口。
const std = @import("std");

pub const ddns = @import("ddns.zig");
pub const logger = @import("logger.zig");

/// 重新导出配置类型，方便主程序使用
pub const Config = ddns.Config;
pub const Provider = ddns.Provider;

/// 运行一次或循环运行 DDNS
pub fn run(config: Config) !void {
    try ddns.run(config);
}

// 简易单元测试：验证 Provider 枚举存在
test "ddns root exports" {
    _ = Provider.dnspod;
}
