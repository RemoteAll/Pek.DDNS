//! JSON 工具库 - 轻量级 JSON 查询和解析工具
//!
//! 本库专注于常见的 JSON 查询场景，提供简单高效的 API。
//! 设计目标：
//! 1. 轻量级：避免完整 JSON 解析的开销
//! 2. 高性能：直接字符串操作，适合简单查询
//! 3. 类型安全：利用 Zig 编译期检查
//! 4. 易用性：提供链式查询和多种便捷方法
//!
//! 未来可独立成库供其他项目使用。

const std = @import("std");
const Allocator = std.mem.Allocator;

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

    /// 检查 JSON 对象是否包含指定的键值对（忽略空白符）
    /// 这个方法会智能处理 JSON 中的空格、换行等格式差异
    fn containsKeyValue(json_obj: []const u8, key: []const u8, value: []const u8) bool {
        // 构建键的模式：查找 "key"
        var key_start: usize = 0;
        while (key_start < json_obj.len) {
            // 查找 "key" 的位置
            const quote_pos = std.mem.indexOfPos(u8, json_obj, key_start, "\"") orelse break;

            // 检查这是否是我们要找的键
            if (quote_pos + 1 + key.len < json_obj.len) {
                const potential_key = json_obj[quote_pos + 1 .. quote_pos + 1 + key.len];
                if (std.mem.eql(u8, potential_key, key)) {
                    // 确认后面是引号和冒号
                    var pos = quote_pos + 1 + key.len;
                    if (pos < json_obj.len and json_obj[pos] == '"') {
                        pos += 1;
                        // 跳过空白
                        while (pos < json_obj.len and std.ascii.isWhitespace(json_obj[pos])) : (pos += 1) {}
                        if (pos < json_obj.len and json_obj[pos] == ':') {
                            pos += 1;
                            // 跳过冒号后的空白
                            while (pos < json_obj.len and std.ascii.isWhitespace(json_obj[pos])) : (pos += 1) {}
                            // 检查值
                            if (pos < json_obj.len and json_obj[pos] == '"') {
                                pos += 1;
                                if (pos + value.len <= json_obj.len) {
                                    const potential_value = json_obj[pos .. pos + value.len];
                                    if (std.mem.eql(u8, potential_value, value)) {
                                        // 确认后面是引号
                                        if (pos + value.len < json_obj.len and json_obj[pos + value.len] == '"') {
                                            return true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            key_start = quote_pos + 1;
        }

        return false;
    }

    /// 查找字符串值（自动忽略空白符，支持各种格式）
    /// 示例: query.getString("name") -> "value"
    /// 返回值由调用方负责释放
    ///
    /// 性能优化：直接在原始 JSON 上操作，零额外内存分配（除结果外）
    pub fn getString(self: JsonQuery, key: []const u8) Error![]u8 {
        // 查找键的起始位置：查找 "key" （键必须是被引号包围的）
        var search_pos: usize = 0;
        while (search_pos < self.json.len) {
            // 查找下一个引号
            const quote_start = std.mem.indexOfPos(u8, self.json, search_pos, "\"") orelse return Error.KeyNotFound;

            // 检查引号后是否匹配键名
            const potential_key_start = quote_start + 1;
            if (potential_key_start + key.len > self.json.len) {
                return Error.KeyNotFound;
            }

            const potential_key = self.json[potential_key_start .. potential_key_start + key.len];
            if (std.mem.eql(u8, potential_key, key)) {
                var pos = potential_key_start + key.len;

                // 必须紧跟着引号结束键
                if (pos >= self.json.len or self.json[pos] != '"') {
                    search_pos = quote_start + 1;
                    continue;
                }
                pos += 1;

                // 跳过空白符
                while (pos < self.json.len and std.ascii.isWhitespace(self.json[pos])) : (pos += 1) {}

                // 必须是冒号
                if (pos >= self.json.len or self.json[pos] != ':') {
                    search_pos = quote_start + 1;
                    continue;
                }
                pos += 1;

                // 跳过冒号后的空白符
                while (pos < self.json.len and std.ascii.isWhitespace(self.json[pos])) : (pos += 1) {}

                // 值必须以引号开始（字符串值）
                if (pos >= self.json.len or self.json[pos] != '"') {
                    return Error.TypeMismatch;
                }
                pos += 1;

                // 找到值的结束引号（简化处理，不考虑转义）
                const value_start = pos;
                const value_end = std.mem.indexOfPos(u8, self.json, pos, "\"") orelse return Error.InvalidFormat;

                return self.allocator.dupe(u8, self.json[value_start..value_end]);
            }

            search_pos = quote_start + 1;
        }

        return Error.KeyNotFound;
    }

    /// 查找数字值
    /// 示例: query.getInt("age") -> 25
    pub fn getInt(self: JsonQuery, comptime T: type, key: []const u8) Error!T {
        const key_pattern = try std.fmt.allocPrint(
            self.allocator,
            "\"{s}\":",
            .{key},
        );
        defer self.allocator.free(key_pattern);

        const start_pos = std.mem.indexOf(u8, self.json, key_pattern) orelse return Error.KeyNotFound;
        const value_start = start_pos + key_pattern.len;
        var value_slice = self.json[value_start..];

        // 跳过空白
        while (value_slice.len > 0 and std.ascii.isWhitespace(value_slice[0])) {
            value_slice = value_slice[1..];
        }

        // 查找数字结束位置
        var end: usize = 0;
        while (end < value_slice.len) : (end += 1) {
            const c = value_slice[end];
            if (!std.ascii.isDigit(c) and c != '-' and c != '.') break;
        }

        if (end == 0) return Error.InvalidFormat;

        return std.fmt.parseInt(T, value_slice[0..end], 10) catch Error.TypeMismatch;
    }

    /// 查找布尔值
    /// 示例: query.getBool("active") -> true
    pub fn getBool(self: JsonQuery, key: []const u8) Error!bool {
        const key_pattern = try std.fmt.allocPrint(
            self.allocator,
            "\"{s}\":",
            .{key},
        );
        defer self.allocator.free(key_pattern);

        const start_pos = std.mem.indexOf(u8, self.json, key_pattern) orelse return Error.KeyNotFound;
        const value_start = start_pos + key_pattern.len;
        var value_slice = self.json[value_start..];

        // 跳过空白
        while (value_slice.len > 0 and std.ascii.isWhitespace(value_slice[0])) {
            value_slice = value_slice[1..];
        }

        if (std.mem.startsWith(u8, value_slice, "true")) return true;
        if (std.mem.startsWith(u8, value_slice, "false")) return false;

        return Error.TypeMismatch;
    }

    /// 查找对象（返回子查询器）
    /// 示例: query.getObject("user").getString("name")
    pub fn getObject(self: JsonQuery, key: []const u8) Error!JsonQuery {
        const key_pattern = try std.fmt.allocPrint(
            self.allocator,
            "\"{s}\":{{",
            .{key},
        );
        defer self.allocator.free(key_pattern);

        const start_pos = std.mem.indexOf(u8, self.json, key_pattern) orelse return Error.KeyNotFound;
        const obj_start = start_pos + key_pattern.len - 1; // 包含 {

        // 查找匹配的 }
        var depth: i32 = 0;
        var pos: usize = obj_start;
        while (pos < self.json.len) : (pos += 1) {
            switch (self.json[pos]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        return JsonQuery.init(self.allocator, self.json[obj_start .. pos + 1]);
                    }
                },
                else => {},
            }
        }

        return Error.InvalidFormat;
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
        // 查找数组起始位置（需要处理空白）
        var search_pos: usize = 0;
        const array_start_pos = while (search_pos < self.json.len) {
            const quote_pos = std.mem.indexOfPos(u8, self.json, search_pos, "\"") orelse return Error.KeyNotFound;
            const key_start = quote_pos + 1;

            if (key_start + array_key.len <= self.json.len) {
                const potential_key = self.json[key_start .. key_start + array_key.len];
                if (std.mem.eql(u8, potential_key, array_key)) {
                    var pos = key_start + array_key.len;
                    if (pos < self.json.len and self.json[pos] == '"') {
                        pos += 1;
                        while (pos < self.json.len and std.ascii.isWhitespace(self.json[pos])) : (pos += 1) {}
                        if (pos < self.json.len and self.json[pos] == ':') {
                            pos += 1;
                            while (pos < self.json.len and std.ascii.isWhitespace(self.json[pos])) : (pos += 1) {}
                            if (pos < self.json.len and self.json[pos] == '[') {
                                break pos + 1;
                            }
                        }
                    }
                }
            }
            search_pos = quote_pos + 1;
        } else return Error.KeyNotFound;

        var pos = array_start_pos;

        // 遍历数组元素
        while (pos < self.json.len) {
            // 跳过空白
            while (pos < self.json.len and std.ascii.isWhitespace(self.json[pos])) : (pos += 1) {}

            if (pos >= self.json.len) break;
            if (self.json[pos] == ']') break; // 数组结束

            if (self.json[pos] == '{') {
                const obj_start = pos;
                var depth: i32 = 0;
                var obj_end: usize = pos;

                // 查找对象结束位置
                while (obj_end < self.json.len) : (obj_end += 1) {
                    switch (self.json[obj_end]) {
                        '{' => depth += 1,
                        '}' => {
                            depth -= 1;
                            if (depth == 0) break;
                        },
                        else => {},
                    }
                }

                if (depth != 0) return Error.InvalidFormat;

                const obj_slice = self.json[obj_start .. obj_end + 1];

                // 使用 containsKeyValue 检查（自动处理空白）
                if (containsKeyValue(obj_slice, match_key, match_value)) {
                    return JsonQuery.init(self.allocator, obj_slice);
                }

                pos = obj_end + 1;
            } else {
                pos += 1;
            }
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
/// - 零内存分配（除了结果）
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
    // 如果是根数组（以 [ 开头），直接处理
    const is_root_array = blk: {
        var idx: usize = 0;
        while (idx < json.len and std.ascii.isWhitespace(json[idx])) : (idx += 1) {}
        break :blk idx < json.len and json[idx] == '[';
    };

    if (is_root_array and options.array_key.len == 0) {
        // 在根数组中查找（使用智能匹配）
        var pos: usize = 0;
        while (pos < json.len) {
            while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
            if (pos >= json.len) break;
            if (json[pos] == ']') break;

            if (json[pos] == '{') {
                const obj_start = pos;
                var depth: i32 = 0;
                var obj_end: usize = pos;

                while (obj_end < json.len) : (obj_end += 1) {
                    switch (json[obj_end]) {
                        '{' => depth += 1,
                        '}' => {
                            depth -= 1;
                            if (depth == 0) break;
                        },
                        else => {},
                    }
                }

                if (depth != 0) return Error.InvalidFormat;

                const obj_slice = json[obj_start .. obj_end + 1];

                // 使用智能匹配（自动处理空白符）
                if (JsonQuery.containsKeyValue(obj_slice, options.match_key, options.match_value)) {
                    const query = JsonQuery.init(allocator, obj_slice);
                    return query.getString(options.target_key);
                }

                pos = obj_end + 1;
            } else {
                pos += 1;
            }
        }

        return Error.ElementNotFound;
    }

    // 使用标准流程处理命名数组
    const query = JsonQuery.init(allocator, json);
    return query.getStringFromArray(
        options.array_key,
        options.match_key,
        options.match_value,
        options.target_key,
    );
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
