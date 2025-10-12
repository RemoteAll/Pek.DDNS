
# Pek.DDNS

这是 Pek.DDNS 仓库的顶层 README，包含仓库概览、子项目说明和快速进入点。仓库内可能包含多个子项目（例如 `Zig.DDNS`），每个子项目可有各自独立的 README。


## 仓库概览

Pek.DDNS 是一个存放多种实现（或实验）版本的 DDNS 工具的仓库。当前包含：

- `Zig.DDNS/`：使用 Zig 语言实现的 DDNS 客户端（详细说明见 `Zig.DDNS/README.md`）。

后续可添加其他语言或平台的实现，如 `go/`、`python/`、`rust/` 等。


## 快速开始

进入子项目目录并查看子项目 README：

```powershell
cd Zig.DDNS
code README.md   # 在 VS Code 中打开文档（可选）
```

如需构建并运行 Zig 实现：

```powershell
cd Zig.DDNS
zig build run
```


## 子项目规范（建议）

- 每个子目录为独立子项目，均应包含自己的 `README.md`、LICENSE（如适用）和构建/运行说明。
- 须说明依赖、支持的运行平台和最小 Zig/Go/Python 版本等。


## 贡献

如果要为仓库添加新实现，请：

1. 在根目录下创建一个以语言或实现为名的子目录（例如 `go/`、`python/`）。
2. 在子目录内添加 `README.md` 说明构建与运行步骤。
3. 提交 PR 并在 PR 描述中包含简单的使用示例。


## 联系方式

作者：PeiKeSmart

---

(本文件为仓库顶层说明，不替代各子项目自己的文档。）
