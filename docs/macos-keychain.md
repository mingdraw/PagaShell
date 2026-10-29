# macOS 凭据保险库

## 授权行为

旧版把每个服务、网关密码和身份凭证分别保存为传统 login keychain 中的一项。
钥匙串通过应用的签名要求识别访问者，ad hoc 临时签名与具体构建绑定，
更新可能使每一项再次要求授权。参见 Apple 的
[代码签名要求](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
与 [Keychain 访问控制](https://developer.apple.com/library/archive/technotes/tn2206/)。

当前 macOS 实现统一为：

- 钥匙串中只新增 `pagashell-vault-key-v1`，内容是随机 256 位主密钥。
- 凭据保存在应用支持目录的 `credentials.vault`，使用 AES-256-GCM 加密并校验完整性。
  密码、私钥、口令、引用和已删除标记都在密文内部；元数据仍在原 SQLite 数据库。
- 每次运行首次使用保险库时读一次主密钥，后续服务、网关及凭证复用内存中的密钥。
  不主动解锁或放宽钥匙串访问控制，不在文件、日志或数据库中保存明文主密钥。
- 新增、覆盖、删除和迁移均排队完成；文件锁协调多个应用实例，临时密文写入并刷新后原子替换。

临时签名构建更新后仍可能要求主密钥的一次授权。正式分发需使用稳定签名身份与 Bundle ID；
系统策略、用户锁定钥匙串及撤销授权仍由 macOS 决定。
若系统提供“始终允许”，该选项与“允许一次”的含义见
[Apple 支持](https://support.apple.com/en-gb/guide/mac-help/kychn002/26/mac/26)。

## 旧数据迁移

1. 优先读取保险库；该引用不存在时才读取旧版钥匙串条目。
2. 旧条目仍受各自的系统访问控制保护，首次迁移可能逐项弹出授权，应用无法将这些权限合并或绕过。
3. 只有加密副本持久化成功后才清理旧条目。写入失败保留旧条目及原保险库并报告错误。
4. 若旧条目清理失败，报告钥匙串错误；已经提交的原值副本仍可在重试时读取。
   覆盖或删除先保证原值已加密保存，再清理旧条目，最后提交替换值或删除标记；
   清理或最终提交失败时原值仍在。删除标记防止旧版本重新写入后回退读取旧值。

迁移不修改服务、网关或凭证的引用。迁移完成后，后续构建只读取主密钥，
不再读取已迁移服务的单独钥匙串记录。尚未使用的旧条目将在首次使用时迁移。
已迁移条目不再供旧版应用读取；降级到不支持保险库的版本不能访问这些凭据。

## 文件与密钥边界

保险库文件和钥匙串主密钥需要配套恢复；仅复制 SQLite 数据库无法恢复密码或私钥。
当前没有备份导出/导入界面。缺失主密钥、错误密钥、密文被修改或未知文件格式均明确失败，
不自动生成新密钥覆盖现存保险库，也不在校验失败时回退到旧条目。

Windows 与 Linux 继续使用原系统安全存储，不启用此文件保险库。

## 验证

```bash
flutter test test/infrastructure/encrypted_secret_store_test.dart test/infrastructure/secure_secret_store_test.dart
flutter test integration_test/secret_store_test.dart -d macos
```

单元测试使用临时目录和模拟钥匙串，验证多凭据只解锁一次、旧值迁移、并发访问、
随机 nonce、密文篡改、密钥缺失与提交失败保护。集成测试只使用独立的测试主密钥、引用和临时保险库。
测试通过不等同于真实更新的系统授权界面验收；发布验收需在不同构建间替换应用后连接多个已迁移服务。

检查构建签名（不会读取钥匙串秘密）：

```bash
codesign -dvvv -r- build/macos/Build/Products/Release/pagashell.app
```

`Signature=adhoc` 表示临时签名。仓库不预设开发者证书或团队，不自动创建证书、
修改用户钥匙串 ACL 或增加未经授权的 entitlement。
