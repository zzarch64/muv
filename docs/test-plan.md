# muv 测试计划

## 已实现的测试场景

### 安全测试（tests/test_multi.sh）

| 场景 | 描述 | 状态 |
|------|------|------|
| A. root 安装 | 测试安装流程和目录结构 | ✅ |
| B. root 授权管理 | 测试 grant 命令 | ✅ |
| C. uvadm 成员操作 | 测试 uvadm 可执行的操作 | ✅ |
| D. 普通用户操作 | 测试普通用户可用功能 | ✅ |
| E. index 锁定测试 | 测试 sticky bit 保护 | ✅ |
| F. mirror 命令测试 | 测试换源功能 | ✅ |
| G. 多 uvadm 协作 | 测试同组成员协作 | ✅ |
| H. uv pip 攻击测试 | 测试普通用户换源攻击 | ✅ |
| I. 硬链接攻击测试 | 测试硬链接攻击防护 | ✅ |
| J. 符号链接攻击测试 | 测试 symlink 攻击防护 | ✅ |
| K. 环境变量注入测试 | 测试环境变量攻击防护 | ✅ |

---

## 需要新增的测试场景

### P1 - 核心功能测试（必须实现）

#### Python 管理命令

| 场景 | 描述 | 测试内容 |
|------|------|----------|
| L. python add | uvadm 成员安装新 Python | 安装成功，可被用户使用 |
| M. python rm | uvadm 成员删除 Python | 删除成功，无依赖时允许 |
| N. python rm --check | 删除前检查依赖 | 显示依赖的 venv 列表 |
| O. python rm 正在使用 | 尝试删除被 venv 使用的 Python | 应该阻止或警告 |
| P. revoke 命令 | 撤销用户 uvadm 成员资格 | 用户被移出组 |

#### 并发与竞态

| 场景 | 描述 | 测试内容 |
|------|------|----------|
| Q. flock 并发保护 | 验证 flock 锁机制 | 同时执行两个 muv 命令 |
| R. 并发 Python 安装 | 两个 uvadm 同时安装不同版本 | 不冲突，都能成功 |

#### 新功能测试

| 场景 | 描述 | 测试内容 |
|------|------|----------|
| S. scan 基本功能 | 验证扫描输出正确性 | 显示用户、venv、Python 统计 |
| T. scan 硬链接统计 | 验证缓存统计 | 显示被引用/未引用文件数 |
| U. scan 权限需求 | 验证需要 root 权限 | 普通用户和 uvadm 不能执行 |
| V. cache prune 基本功能 | 清理未使用缓存 | 只删除 links=1 的文件 |
| W. cache prune 权限 | 验证需要 root 权限 | 普通用户不能执行 |

#### 日常使用场景

| 场景 | 描述 | 测试内容 |
|------|------|----------|
| X. 日常 venv 创建 | 普通用户创建和使用 venv | 命中共享缓存 |
| Y. 包安装缓存共享 | 多用户安装同一包 | 验证硬链接共享 |

### P2 - 重要但非紧急

| 场景 | 描述 | 测试内容 |
|------|------|----------|
| update 命令 | 更新 uv/uvx 并重新锁定 | 更新成功，index 重新锁定 |
| mirror auto | 自动测速选镜像 | 选择最快镜像 |
| cache prune --dry-run | 预览删除内容 | 显示将删除的文件 |
| revoke 最后管理员 | 撤销最后一个 uvadm 成员 | 应该警告或阻止 |
| 用户组变更后访问 | 撤销后访问其创建的缓存 | 权限正确隔离 |
| 换源影响分析 | 换源后已安装包可访问性 | 不影响已安装的包 |

### P3 - 可后续完善

| 场景 | 描述 | 测试内容 |
|------|------|----------|
| 磁盘空间不足 | 安装时磁盘满 | 优雅处理错误 |
| 网络中断恢复 | 安装时网络中断 | 恢复机制 |
| 无效 Python 版本 | 安装不存在的版本 | 友好错误提示 |
| 损坏的缓存文件 | 缓存文件损坏 | 跳过或重新下载 |
| 不同分区安装 | /opt 与 /home 不同分区 | 硬链接退化警告 |

---

## 实现顺序

### 第 1 批：核心功能（P1）

1. **require_root 函数** (0.5h)
   - 添加权限检查函数

2. **muv scan 命令** (2h)
   - 扫描用户、venv、Python、缓存
   - 生成 stats.json
   - 显示统计信息
   - 测试：场景 S, T, U

3. **muv cache prune 命令** (2h)
   - 基于硬链接计数清理
   - 支持 --dry-run
   - 删除前确认
   - 测试：场景 V, W

4. **muv python rm --check** (1.5h)
   - 检查 venv 依赖
   - 显示依赖列表
   - 测试：场景 N, O

### 第 2 批：现有命令测试（P1）

5. **python add/rm 测试** (1h)
   - 测试场景 L, M

6. **revoke 命令测试** (0.5h)
   - 测试场景 P

7. **并发测试** (1h)
   - 测试场景 Q, R

8. **日常使用场景测试** (1h)
   - 测试场景 X, Y

**总计**: 约 9.5 小时

---

## 测试文件结构

```
tests/
├── test_muv.sh           # 单元测试
└── test_multi.sh         # 多用户集成测试
```

### test_multi.sh 新增场景

```bash
# 场景 L-Y 添加到 test_multi.sh
test_scenario_python_add() { ... }
test_scenario_python_rm() { ... }
test_scenario_python_rm_check() { ... }
test_scenario_revoke() { ... }
test_scenario_scan() { ... }
test_scenario_cache_prune() { ... }
test_scenario_daily_usage() { ... }
test_scenario_concurrent() { ... }
```

---

## 关键测试点

### 权限验证

| 命令 | 需要 | 测试点 |
|------|------|--------|
| `muv scan` | root | 普通用户执行应失败 |
| `muv cache prune` | root | uvadm 成员执行应失败 |
| `muv python rm --check` | root | 普通用户执行应失败 |
| `muv python add` | uvadm | 普通用户执行应失败 |

### 功能验证

| 功能 | 验证点 |
|------|--------|
| scan | 统计数字准确 |
| prune | 只删除 links=1 的文件 |
| --check | 列出所有依赖的 venv |
| revoke | 用户被移出组 |

### 边界情况

| 情况 | 预期行为 |
|------|----------|
| 无 venv 存在 | scan 显示 0 |
| 所有缓存被引用 | prune 显示无文件可删除 |
| Python 被 0 个 venv 使用 | --check 返回成功 |
| Python 被 5 个 venv 使用 | --check 列出 5 个 venv |
