# 安全策略 Security Policy

PagaShell 是一款 SSH 客户端，安全问题会被最高优先级处理。

## 报告漏洞

**请勿通过公开 Issue 报告安全漏洞。**

请使用 GitHub 的 [Private vulnerability reporting](../../security/advisories/new) 私下提交，我们会在 72 小时内响应。

## 范围

我们特别关注以下类别的问题：

- 凭据（密码 / 私钥 / passphrase）以明文形式落盘、进入日志或错误信息
- 主机密钥（known hosts）校验被绕过
- 加密实现缺陷（密钥派生、nonce 复用等）
- 依赖链中的已知漏洞

## 支持版本

正式发布（v1.0）前，仅最新版本接受安全修复。
