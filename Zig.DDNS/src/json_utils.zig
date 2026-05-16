//! JSON 工具库 - 轻量级 JSON 查询和解析工具
//!
//! 本库专注于常见的 JSON 查询场景，提供简单高效的 API。
//! 设计目标：
//! 1. 轻量级：围绕常见查询场景提供薄包装
//! 2. 高性能：复用 zzig.json tokenizer，避免重复实现 JSON 扫描逻辑
//! 3. 类型安全：利用 Zig 编译期检查
//! 4. 易用性：提供链式查询和多种便捷方法
//!
//! 未来可独立成库供其他项目使用。

const std = @import("std");
const zzig = @import("zzig");
const Allocator = std.mem.Allocator;
const Parser = zzig.json.createDesktopParser();

/// JSON 查询错误类型
pub const Error = error{
    /// 找不到指定的键
    KeyNotFound,
    /// 找不到指定的数组元素
    ElementNotFound,
    /// JSON 格式无效
    InvalidFormat,
    /// 值类型不匹配
    TypeMismatch,
    /// 内存分配失败
    OutOfMemory,
};

/// JSON 值查询器 - 支持链式查询
pub const JsonQuery = struct {
    allocator: Allocator,
    json: []const u8,

    /// 创建新的 JSON 查询器
    pub fn init(allocator: Allocator, json: []const u8) JsonQuery {
        return .{
            .allocator = allocator,
            .json = json,
        };
    }

    /// 查找字符串值
    /// 示例: query.getString("name") -> "value"
    /// 返回值由调用方负责释放
    pub fn getString(self: JsonQuery, key: []const u8) Error![]u8 {
        const parsed = try parseJson(self.allocator, self.json);
        defer parsed.deinit();

        const value_index = findObjectValueAt(parsed.tokens, parsed.count, self.json, 0, key) orelse return Error.KeyNotFound;
        return dupStringToken(self.allocator, parsed.tokens[value_index], self.json);
    }

    /// 查找数字值
    /// 示例: query.getInt("age") -> 25
    pub fn getInt(self: JsonQuery, comptime T: type, key: []const u8) Error!T {
        const parsed = try parseJson(self.allocator, self.json);
        defer parsed.deinit();

        const value_index = findObjectValueAt(parsed.tokens, parsed.count, self.json, 0, key) orelse return Error.KeyNotFound;
        const token = parsed.tokens[value_index];
        if (token.typ != .Primitive) return Error.TypeMismatch;

        const value = Parser.parseInteger(token, self.json) catch return Error.TypeMismatch;
        return std.math.cast(T, value) orelse Error.TypeMismatch;
    }

    /// 查找布尔值
    /// 示例: query.getBool("active") -> true
    pub fn getBool(self: JsonQuery, key: []const u8) Error!bool {
        const parsed = try parseJson(self.allocator, self.json);
        defer parsed.deinit();

        const value_index = findObjectValueAt(parsed.tokens, parsed.count, self.json, 0, key) orelse return Error.KeyNotFound;
        const token = parsed.tokens[value_index];
        if (token.typ != .Primitive) return Error.TypeMismatch;

        const raw = Parser.tokenText(token, self.json);
        if (std.mem.eql(u8, raw, "true")) return true;
        if (std.mem.eql(u8, raw, "false")) return false;
        return Error.TypeMismatch;
    }

    /// 查找对象（返回子查询器）
    /// 示例: query.getObject("user").getString("name")
    pub fn getObject(self: JsonQuery, key: []const u8) Error!JsonQuery {
        const parsed = try parseJson(self.allocator, self.json);
        defer parsed.deinit();

        const value_index = findObjectValueAt(parsed.tokens, parsed.count, self.json, 0, key) orelse return Error.KeyNotFound;
        const token = parsed.tokens[value_index];
        if (token.typ != .Object) return Error.TypeMismatch;

        return JsonQuery.init(self.allocator, self.json[token.start..token.end]);
    }

    /// 查找数组中符合条件的第一个元素
    /// 示例: query.findInArray("items", "Type", "IPv4").getString("Ip")
    /// 不依赖属性顺序，自动处理空白符
    pub fn findInArray(
        self: JsonQuery,
        array_key: []const u8,
        match_key: []const u8,
        match_value: []const u8,
    ) Error!JsonQuery {
        const parsed = try parseJson(self.allocator, self.json);
        defer parsed.deinit();

        const array_index = if (array_key.len == 0)
            0
        else
            findObjectValueAt(parsed.tokens, parsed.count, self.json, 0, array_key) orelse return Error.KeyNotFound;

        const array_token = parsed.tokens[array_index];
        if (array_token.typ != .Array) return Error.TypeMismatch;

        var item_index = array_index + 1;
        var remaining: usize = @intCast(array_token.size);
        while (remaining > 0 and item_index < parsed.count) {
            const item_token = parsed.tokens[item_index];
            if (item_token.typ == .Object) {
                const match_index = findObjectValueAt(parsed.tokens, parsed.count, self.json, item_index, match_key);
                if (match_index) |value_index| {
                    if (stringTokenEquals(parsed.tokens[value_index], self.json, match_value)) {
                        return JsonQuery.init(self.allocator, self.json[item_token.start..item_token.end]);
                    }
                }
            }

            item_index = Parser.skipToken(parsed.tokens, item_index);
            remaining -= 1;
        }

        return Error.ElementNotFound;
    }

    /// 直接从 JSON 数组中查找并提取字符串值
    /// 这是一个便捷方法，组合了 findInArray 和 getString
    /// 返回值由调用方负责释放
    pub fn getStringFromArray(
        self: JsonQuery,
        array_key: []const u8,
        match_key: []const u8,
        match_value: []const u8,
        target_key: []const u8,
    ) Error![]u8 {
        const obj = try self.findInArray(array_key, match_key, match_value);
        return obj.getString(target_key);
    }
};

/// 便捷函数：从 JSON 字符串中快速提取字符串值
/// 使用场景：一次性查询，无需创建 JsonQuery 对象
/// 返回值由调用方负责释放
pub fn quickGetString(allocator: Allocator, json: []const u8, key: []const u8) Error![]u8 {
    const query = JsonQuery.init(allocator, json);
    return query.getString(key);
}

/// 便捷函数：从 JSON 数组中查找符合条件的元素并提取字符串值
/// 使用场景：处理类似 IP 查询接口的响应
/// 返回值由调用方负责释放
///
/// 特性：
/// - 基于 zzig.json tokenizer 的稳定查询
/// - 自动处理各种 JSON 格式（空格、换行、缩进等）
/// - 不依赖属性顺序
/// - 支持根数组和命名数组
///
/// 示例：
/// ```zig
/// const ip = try quickGetStringFromArray(
///     allocator,
///     json_response,
///     .{ .match_key = "Type", .match_value = "IPv4", .target_key = "Ip" }
/// );
/// defer allocator.free(ip);
/// ```
pub fn quickGetStringFromArray(
    allocator: Allocator,
    json: []const u8,
    options: struct {
        array_key: []const u8 = "", // 空字符串表示根数组
        match_key: []const u8,
        match_value: []const u8,
        target_key: []const u8,
    },
) Error![]u8 {
    const query = JsonQuery.init(allocator, json);
    return query.getStringFromArray(
        options.array_key,
        options.match_key,
        options.match_value,
        options.target_key,
    );
}

const ParsedJson = struct {
    allocator: ?Allocator,
    tokens: []Parser.Token,
    parents: []Parser.IndexT,
    count: usize,

    fn deinit(self: ParsedJson) void {
        if (self.allocator) |allocator| {
            allocator.free(self.tokens);
            allocator.free(self.parents);
        }
    }
};

fn parseJson(allocator: Allocator, json: []const u8) Error!ParsedJson {
    const token_count = Parser.estimateTokenCount(json);
    const tokens = allocator.alloc(Parser.Token, token_count) catch return Error.OutOfMemory;
    errdefer allocator.free(tokens);
    const parents = allocator.alloc(Parser.IndexT, token_count) catch return Error.OutOfMemory;
    errdefer allocator.free(parents);

    const count = Parser.parseTokens(tokens, parents, json) catch return Error.InvalidFormat;
    return .{
        .allocator = allocator,
        .tokens = tokens,
        .parents = parents,
        .count = count,
    };
}

fn findObjectValueAt(tokens: []const Parser.Token, count: usize, input: []const u8, object_index: usize, key: []const u8) ?usize {
    if (object_index >= count) return null;

    const object_token = tokens[object_index];
    if (object_token.typ != .Object) return null;

    var child = object_index + 1;
    var remaining: usize = @intCast(object_token.size);
    while (remaining > 0 and child < count) {
        const key_token = tokens[child];
        if (key_token.typ != .String) return null;

        remaining -= 1;
        const value_index = child + 1;
        if (value_index >= count or remaining == 0) return null;

        if (std.mem.eql(u8, Parser.tokenText(key_token, input), key)) {
            return value_index;
        }

        child = Parser.skipToken(tokens, value_index);
        remaining -= 1;
    }

    return null;
}

fn dupStringToken(allocator: Allocator, token: Parser.Token, input: []const u8) Error![]u8 {
    if (token.typ != .String) return Error.TypeMismatch;
    const raw = Parser.tokenText(token, input);
    return zzig.json.unescapeJsonStringAlloc(allocator, raw) catch Error.InvalidFormat;
}

fn stringTokenEquals(token: Parser.Token, input: []const u8, expected: []const u8) bool {
    if (token.typ != .String) return false;
    return std.mem.eql(u8, Parser.tokenText(token, input), expected);
}

// ============================================================================
// 测试用例
// ============================================================================

test "JsonQuery: getString" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"test\",\"age\":25}";

    const query = JsonQuery.init(allocator, json);
    const name = try query.getString("name");
    defer allocator.free(name);

    try std.testing.expectEqualStrings("test", name);
}

test "JsonQuery: getInt" {
    const allocator = std.testing.allocator;
    const json = "{\"name\":\"test\",\"age\":25}";

    const query = JsonQuery.init(allocator, json);
    const age = try query.getInt(u32, "age");

    try std.testing.expectEqual(@as(u32, 25), age);
}

test "JsonQuery: getBool" {
    const allocator = std.testing.allocator;
    const json = "{\"active\":true,\"disabled\":false}";

    const query = JsonQuery.init(allocator, json);
    try std.testing.expect(try query.getBool("active"));
    try std.testing.expect(!(try query.getBool("disabled")));
}

test "JsonQuery: findInArray with match" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"Type":"IPv6","Ip":"::1"},
        \\  {"Type":"IPv4","Ip":"192.168.1.1"}
        \\]
    ;

    // 根数组需要特殊处理，这里演示命名数组
    const wrapped_json = "{\"items\":" ++ json ++ "}";
    const wrapped_query = JsonQuery.init(allocator, wrapped_json);

    const result = try wrapped_query.getStringFromArray("items", "Type", "IPv4", "Ip");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("192.168.1.1", result);
}

test "quickGetStringFromArray: root array" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"Type":"IPv6","Ip":"::1"},
        \\  {"Type":"IPv4","Ip":"192.168.1.1"}
        \\]
    ;

    const ip = try quickGetStringFromArray(allocator, json, .{
        .match_key = "Type",
        .match_value = "IPv4",
        .target_key = "Ip",
    });
    defer allocator.free(ip);

    try std.testing.expectEqualStrings("192.168.1.1", ip);
}

test "quickGetString: simple query" {
    const allocator = std.testing.allocator;
    const json = "{\"status\":\"ok\",\"message\":\"success\"}";

    const status = try quickGetString(allocator, json, "status");
    defer allocator.free(status);

    try std.testing.expectEqualStrings("ok", status);
}
