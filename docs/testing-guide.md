# muv 测试指南

## Docker 测试环境

muv 使用 Docker 容器进行多用户集成测试，确保隔离和可重复性。

### 运行测试

```bash
# 在项目根目录执行
docker run --rm -v /home/lzz/code/muv:/muv ubuntu:24.04 bash -c "
apt-get update -qq && apt-get install -y acl sudo bash coreutils 2>/dev/null
cd /muv && bash tests/test_multi.sh
"
```

### 测试覆盖

| 测试文件 | 覆盖内容 |
|---------|---------|
| `tests/test_muv.sh` | 单元测试、函数测试 |
| `tests/test_multi.sh` | 多用户集成测试（需要 Docker） |

### 测试场景

#### 已实现场景 (A-K)

| 场景 | 描述 | 状态 |
|------|------|------|
| A | root 安装 | ✅ |
| B | root 授权管理 | ✅ |
| C | uvadm 成员操作 | ✅ |
| D | 普通用户操作 | ✅ |
| E | index 锁定测试 | ✅ |
| F | mirror 命令测试 | ✅ |
| G | 多 uvadm 协作 | ✅ |
| H | uv pip 攻击测试 | ✅ |
| I | 硬链接攻击测试 | ✅ |
| J | 符号链接攻击测试 | ✅ |
| K | 环境变量注入测试 | ✅ |

#### 新功能场景 (L-N)

| 场景 | 描述 | 状态 |
|------|------|------|
| L | scan 命令测试 | ✅ |
| M | cache prune 命令测试 | ✅ |
| N | python rm --check 测试 | ✅ |

### 本地测试

如果有本地 Docker 环境：

```bash
# 快速测试
docker run --rm -v $(pwd):/muv ubuntu:24.04 bash -c "
apt-get update -qq && apt-get install -y acl sudo
cd /muv && bash tests/test_multi.sh
"

# 查看特定场景输出
docker run --rm -v $(pwd):/muv ubuntu:24.04 bash -c "
apt-get update -qq && apt-get install -y acl sudo
cd /muv && bash tests/test_multi.sh 2>&1 | grep '场景 L'
"
```

### CI 集成

可以在 CI/CD 流程中自动运行：

```yaml
# .github/workflows/test.yml 示例
- name: Run multi-user tests
  run: |
    docker run --rm -v ${{ github.workspace }}:/muv ubuntu:24.04 bash -c "
      apt-get update -qq && apt-get install -y acl sudo
      cd /muv && bash tests/test_multi.sh
    "
```

### 测试用户

测试使用以下用户：

| 用户 | 组 | 角色 |
|------|-----|------|
| admin1 | uvadm | UV 管理员 |
| admin2 | uvadm | UV 管理员 |
| normal | - | 普通用户 |

### 测试前后清理

```bash
# 设置测试环境
bash tests/test_multi.sh setup

# 清理测试用户
bash tests/test_multi.sh cleanup

# 运行完整测试
bash tests/test_multi.sh run
```
