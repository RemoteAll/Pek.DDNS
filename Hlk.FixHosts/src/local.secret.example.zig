//! 本地密钥配置模板
//!
//! 使用方式：
//!   1. 复制本文件为 local.secret.zig（同目录下）
//!   2. 将下方的占位符替换为你在 DNSPod 申请的 API Token
//!   3. 运行 zig build 编译
//!
//! 注意：local.secret.zig 已被 .gitignore 排除，不会提交到 Git 仓库。
//!       每次重新编译时，新 Token 会被重新嵌入到 exe 中。

pub const DNSPOD_TOKEN_ID = "你的TokenId";
pub const DNSPOD_TOKEN = "你的Token值";
