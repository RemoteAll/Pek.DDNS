# 贡献指南

感谢你对 Zig.DDNS 项目的关注！本指南将帮助你快速开始贡献代码。

## 开发环境

### 必需工具

- [Zig](https://ziglang.org/download/) 0.15.2 或更高版本
- Git
- 推荐：[VSCode](https://code.visualstudio.com/) + [Zig 插件](https://marketplace.visualstudio.com/items?itemName=ziglang.vscode-zig)

### 克隆仓库

```bash
git clone https://github.com/PeiKeSmart/Zig.DDNS.git
cd Zig.DDNS
```

### 构建项目

```bash
zig build
```

### 运行测试

```bash
zig build test
```

## 开发规范

### 代码风格

项目遵循 [PeiKeSmart Copilot 协作指令](.github/copilot-instructions.md)：

- **Zig 0.15.2+ 兼容性**：使用最新标准库 API，避免已废弃接口
- **可读性优先**：局部变量就近声明，成组排布相关成员
- **保留注释**：禁止删除已有代码注释，可修改或追加
- **保留空行**：不得仅为对齐批量移除逻辑分隔空行
- **错误处理**：明确错误类型，使用 `error union`，合理传播错误
- **内存管理**：使用 `defer` 确保资源释放，避免内存泄漏

### 提交规范

遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：

```text
<类型>(<范围>): <简短描述>

<详细说明>（可选）

影响范围:
- [ ] 公共 API 变更
- [ ] 性能影响
- [ ] 兼容性变更

测试情况:
- [ ] 单元测试已通过
- [ ] 编译测试通过
```

#### 类型说明

- `feat`: 新功能
- `fix`: 修复 bug
- `docs`: 文档更新
- `refactor`: 代码重构（不改变功能）
- `test`: 测试相关
- `chore`: 构建/工具相关
- `perf`: 性能优化

#### 示例

```text
feat(provider): 添加 Cloudflare DNS 支持

实现 Cloudflare API v4 接口集成，支持：
- Zone 列表查询
- DNS 记录增删改查
- 自动 TTL 同步

影响范围:
- [x] 公共 API 变更 (新增 CloudflareConfig)
- [ ] 性能影响
- [ ] 兼容性变更

测试情况:
- [x] 单元测试已通过
- [x] 编译测试通过
```

## 开发流程

### 1. 创建功能分支

```bash
git checkout -b feature/awesome-feature
```

### 2. 开发并提交

```bash
# 修改代码
# ...

# 添加变更
git add .

# 提交（遵循提交规范）
git commit -m "feat(provider): 添加 Cloudflare 支持"
```

### 3. 推送分支

```bash
git push origin feature/awesome-feature
```

### 4. 提交 Pull Request

1. 访问 [GitHub 仓库](https://github.com/PeiKeSmart/Zig.DDNS)
2. 点击 "New Pull Request"
3. 选择你的分支
4. 填写 PR 描述（说明改动内容、影响范围、测试情况）
5. 提交等待审核

## 添加新 DNS 服务商

### 步骤说明

参考 `src/ddns.zig` 中的 DNSPod 实现：

1. **定义 Provider 枚举**

```zig
pub const Provider = enum {
    dnspod,
    cloudflare,  // 新增
};
```

2. **定义配置结构**

```zig
pub const CloudflareConfig = struct {
    api_token: []const u8,
    zone_id: []const u8,
};
```

3. **实现更新逻辑**

```zig
fn cloudflare_update(allocator: std.mem.Allocator, config: Config, ip: []const u8) !void {
    // 1. 验证配置
    // 2. 查询现有记录
    // 3. 比对 IP 和 TTL
    // 4. 调用 API 更新
    // 5. 记录日志
}
```

4. **接入主流程**

在 `runOnce()` 中添加分支：

```zig
switch (config.provider) {
    .dnspod => try providers.dnspod_update(allocator, config, ip),
    .cloudflare => try providers.cloudflare_update(allocator, config, ip),
}
```

5. **更新配置解析**

在 `src/main.zig` 中添加 provider 映射。

6. **更新文档**

- 在 `README.md` 添加使用说明
- 在 `CHANGELOG.md` 记录变更
- 提供配置示例

## 测试指南

### 单元测试

在文件末尾添加测试块：

```zig
test "cloudflare provider" {
    const allocator = std.testing.allocator;
    // 测试逻辑
}
```

运行测试：

```bash
zig build test
```

### 集成测试

创建临时配置文件测试完整流程：

```bash
# 复制配置模板
cp config.example.json config.test.json

# 填写测试凭据
# 编辑 config.test.json

# 运行测试
zig build run
```

## 文档更新

### 需要更新的文档

- `README.md`：用户文档、功能说明
- `CHANGELOG.md`：变更记录
- `.github/copilot-instructions.md`：开发规范（如有必要）
- 代码注释：使用 `///` 或 `//!` 生成文档

### 文档规范

- 使用简体中文
- 提供代码示例
- 说明配置参数
- 列举常见问题

## 问题反馈

### 提交 Issue

访问 [Issues](https://github.com/PeiKeSmart/Zig.DDNS/issues) 页面：

- 使用清晰的标题
- 提供复现步骤
- 附上错误日志
- 说明运行环境（OS、Zig 版本）

### 模板示例

```markdown
**问题描述**
程序运行时出现 XXX 错误

**复现步骤**
1. 配置 config.json
2. 运行 zig build run
3. 观察到错误

**期望行为**
应该正常更新 DNS 记录

**实际行为**
程序崩溃并输出错误信息

**环境信息**
- OS: Windows 11
- Zig: 0.15.2
- Provider: DNSPod

**错误日志**

```text
[ERROR] ...
```

#### 附加信息

（可选）其他相关信息

## 行为准则

- 尊重所有贡献者
- 保持专业友好的交流
- 接受建设性反馈
- 遵循项目规范

## 许可证

贡献的代码将采用 [MIT 许可证](LICENSE)。

---

感谢你的贡献！🎉
