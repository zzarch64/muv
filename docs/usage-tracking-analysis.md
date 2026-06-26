# muv 使用统计与缓存清理方案分析（完整版）

## 问题背景

在 muv 的多用户共享环境中需要追踪：

| 层级 | 追踪内容 | 用途 |
|------|---------|------|
| **用户** | 哪些用户使用 muv？最后活跃时间 | 清理不活跃用户的数据 |
| **Python** | 哪些 Python 版本被使用？ | 安全删除旧版本 |
| **Venv** | 每个用户有哪些 venv？位置、Python版本 | 管理用户环境 |
| **包** | 每个包被哪些 venv 引用？ | 安全清理缓存 |

## 当前困难

### 场景 1: 删除共享 Python 版本

```bash
# 管理员删除 Python 3.11
muv python rm 3.11

# 问题：可能有用户的 venv 基于 3.11
# 这些 venv 会失效但管理员不知道
```

### 场景 2: 清理缓存

```bash
# 用户删除自己的 venv
rm -rf ~/project/.venv

# 缓存中的包文件仍然存在
# 其他用户可能还在用，也可能没人用了
```

### 场景 3: 查询使用情况

```bash
# 管理员想知道：
# - 哪些用户在使用 muv？
# - 每个用户有哪些 venv？
# - 哪些包可以安全删除？
# 目前没有工具
```

## 完整解决方案

### 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    muv 使用追踪系统                            │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  注册中心: $UV_ROOT/.muv-registry/                    │   │
│  │  ├── users/              用户活跃记录                  │   │
│  │  ├── venvs/              Venv 注册信息                  │   │
│  │  ├── packages/           包引用计数                    │   │
│  │  └── python/             Python 版本使用               │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  收集方式:                                              │   │
│  │  1. Shell 钩子 (自动) - 在创建/删除 venv 时注册       │   │
│  │  2. 定期扫描 (手动) - 扫描文件系统同步状态            │   │
│  │  3. 用户命令 - 用户主动注册/注销                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### 方案 A: Shell 钩子自动注册

**原理**: 包装 venv 命令，自动记录到注册中心

**实现**:

```bash
# 1. 创建包装器
# $UV_ROOT/bin/uv-venv
#!/usr/bin/env bash
UV_ROOT="${UV_ROOT:-/opt/uv}"
MUV_REGISTRY="$UV_ROOT/.muv-registry"

# 原始 uv 命令
exec uv venv "$@"

# venv 创建成功后注册
if [ $? -eq 0 ]; then
    local venv_path="$1"
    local python_version=$(uv python find)
    local user=$(whoami)
    local timestamp=$(date +%s)
    
    # 注册 venv
    mkdir -p "$MUV_REGISTRY/venvs"
    cat > "$MUV_REGISTRY/venvs/$venv_path:$timestamp" <<EOF
user=$user
path=$venv_path
python=$python_version
created=$timestamp
EOF
    
    # 记录用户活跃
    mkdir -p "$MUV_REGISTRY/users"
    echo "$timestamp" > "$MUV_REGISTRY/users/$user"
fi
```

**问题**: 需要用户使用包装器，容易绕过

### 方案 B: 定期文件系统扫描

**原理**: 定期扫描所有用户目录，发现并记录 venv

**实现**:

```bash
#!/usr/bin/env bash
# muv scan - 扫描并记录所有 venv 和包的使用情况

UV_ROOT="${UV_ROOT:-/opt/uv}"
MUV_REGISTRY="$UV_ROOT/.muv-registry"
CACHE_DIR="$UV_ROOT/cache"

scan_users() {
    echo "扫描用户活跃状态..."
    
    # 扫描所有使用 muv 的用户（通过检查 env.sh 的 source）
    # 实际上检查哪些用户最近执行过 muv 命令
    mkdir -p "$MUV_REGISTRY/users"
    
    for user_home in /home/*; do
        local user=$(basename "$user_home")
        local last_active=""
        
        # 检查用户是否 source 了 env.sh
        if grep -q "source $UV_ROOT/env.sh" "$user_home/.bashrc" "$user_home/.zshrc" 2>/dev/null; then
            # 检查最后活跃时间
            local last_venv=$(find "$user_home" -name "pyvenv.cfg" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1)
            if [ -n "$last_venv" ]; then
                last_active=$(echo "$last_venv" | cut -d' ' -f1)
            fi
            
            # 记录用户
            if [ -n "$last_active" ]; then
                echo "$last_active" > "$MUV_REGISTRY/users/$user"
            fi
        fi
    done
}

scan_venvs() {
    echo "扫描所有 venv..."
    
    mkdir -p "$MUV_REGISTRY/venvs"
    
    # 查找所有 venv (通过 pyvenv.cfg 标识)
    find /home -name "pyvenv.cfg" 2>/dev/null | while read -r cfg_file; do
        local venv_dir=$(dirname "$cfg_file")
        local user=$(stat -c '%U' "$venv_dir")
        local python_version=$(grep "version = " "$cfg_file" | cut -d= -f2 | xargs)
        local created=$(stat -c '%Y' "$cfg_file")
        
        # 检查是否使用 muv 的 Python
        local python_path="$venv_dir/bin/python"
        if [ -L "$python_path" ]; then
            local target=$(readlink "$python_path")
            if [[ "$target" == "$UV_ROOT/python"* ]]; then
                # 这是使用 muv Python 的 venv
                cat > "$MUV_REGISTRY/venvs/${user}:${venv_dir//\//_}" <<EOF
user=$user
path=$venv_dir
python=$python_version
created=$created
EOF
            fi
        fi
    done
}

scan_packages() {
    echo "扫描包引用..."
    
    mkdir -p "$MUV_REGISTRY/packages"
    
    # 构建缓存 inode 映射
    declare -A cache_inodes
    find "$CACHE_DIR" -type f -print0 | while IFS= read -r -d '' file; do
        local inode=$(stat -c '%i' "$file")
        cache_inodes[$inode]="$file"
    done
    
    # 扫描所有 venv 的 site-packages
    while IFS=: read -r key; do
        source "$MUV_REGISTRY/venvs/$key"
        local venv_path=$(grep "^path=" "$MUV_REGISTRY/venvs/$key" | cut -d= -f2)
        
        find "$venv_path/lib" -type f -path "*/site-packages/*" 2>/dev/null | while read -r pkg_file; do
            local inode=$(stat -c '%i' "$pkg_file")
            local venv_key=$(basename "$key")
            
            # 记录引用
            echo "$venv_path" >> "$MUV_REGISTRY/packages/$inode"
        done
    done < <(ls "$MUV_REGISTRY/venvs")
}

scan_python_usage() {
    echo "扫描 Python 版本使用..."
    
    mkdir -p "$MUV_REGISTRY/python"
    
    # 统计每个 Python 版本被多少 venv 使用
    for key in "$MUV_REGISTRY/venvs"/*; do
        [ -f "$key" ] || continue
        local version=$(grep "^python=" "$key" | cut -d= -f2)
        [ -n "$version" ] || continue
        
        local count_file="$MUV_REGISTRY/python/$version"
        echo 1 >> "$count_file"
    done
}

# 主流程
scan_users
scan_venvs
scan_packages
scan_python_usage

echo "扫描完成"
```

### 方案 C: 混合方案（推荐）

**结合钩子和扫描**：
1. 用户可以选择启用自动注册
2. 定期扫描补充遗漏的 venv
3. 提供手动注册/注销命令

## 新增 muv 子命令

### 1. `muv status` - 系统状态概览

```bash
$ muv status

muv 系统状态
============

用户活跃:
  alice: 最后活跃 2 小时前
  bob:   最后活跃 1 天前
  carol: 最后活跃 30 天前

共享 Python:
  3.11: 5 个 venv 使用
  3.12: 12 个 venv 使用

缓存统计:
  总大小: 2.3 GB
  可清理: 450 MB (30 天未使用)

Venv 总数: 17
```

### 2. `muv list users` - 列出使用 muv 的用户

```bash
$ muv list users

用户              最后活跃          Venv 数量
alice             2 小时前          3
bob               1 天前            5
carol             30 天前           1
```

### 3. `muv list venvs [--user <user>]` - 列出 venv

```bash
$ muv list venvs --user alice

Venv 路径                          Python 版本    创建时间
/home/alice/project1/.venv         3.12          2024-01-15
/home/alice/project2/.venv         3.11          2024-02-20
/home/alice/.local/venvs/test      3.12          2024-03-01
```

### 4. `muv list packages [--venv <path>]` - 列出包

```bash
$ muv list packages --venv /home/alice/project1/.venv

包名                 版本      大小     引用数
requests            2.31.0   256 KB   3
numpy               1.26.0   5.2 MB   2
pandas              2.0.0    12 MB    1
```

### 5. `muv list python` - 列出共享 Python

```bash
$ muv list python

版本      路径                          使用数   状态
3.11      /opt/uv/python/cpython-3.11   5        活跃
3.12      /opt/uv/python/cpython-3.12   12       活跃
```

### 6. `muv cache prune [--dry-run]` - 清理缓存

```bash
# 预览将要删除的内容
$ muv cache prune --dry-run

将清理 450 MB，包含以下包:
  - package-1.0.0 (30 天未使用)
  - old-lib-2.3.1 (45 天未使用)

# 执行清理
$ muv cache prune

清理完成: 释放 450 MB 空间
```

### 7. `muv python rm --check <version>` - 安全删除 Python

```bash
# 检查删除影响
$ muv python rm --check 3.11

以下 venv 将受到影响:
  - /home/alice/project2/.venv (Python 3.11)
  - /home/bob/legacy/.venv (Python 3.11)

确认删除? 这些 venv 将失效 [y/N]:
```

### 8. `muv register venv <path>` - 手动注册 venv

```bash
$ muv register venv ~/project/.venv

已注册 venv: ~/project/.venv (Python 3.12)
```

### 9. `muv unregister venv <path>` - 注销 venv

```bash
$ muv unregister venv ~/project/.venv

已注销 venv: ~/project/.venv
注意: 这只是从注册中心删除，不会删除实际的 venv
```

## 实现优先级

| 优先级 | 功能 | 复杂度 | 价值 |
|--------|------|--------|------|
| P1 | `muv scan` - 扫描命令 | 中 | 高 |
| P1 | `muv status` - 状态概览 | 低 | 高 |
| P1 | `muv list venvs` - 列出 venv | 中 | 高 |
| P1 | `muv python rm --check` | 低 | 高 |
| P2 | `muv cache prune` | 高 | 中 |
| P2 | `muv list packages` | 高 | 中 |
| P3 | 自动注册钩子 | 高 | 低 |
| P3 | `muv register/unregister` | 低 | 低 |

## 技术细节

### 注册中心格式

```
$UV_ROOT/.muv-registry/
├── users/
│   ├── alice          # 文件内容: 最后活跃时间戳
│   ├── bob
│   └── carol
├── venvs/
│   ├── alice:_home_alice_project1_.venv
│   ├── alice:_home_alice_project2_.venv
│   └── bob:_home_bob_legacy_.venv
├── packages/
│   ├── 1234567        # inode，内容: 引用的 venv 列表
│   └── 7654321
└── python/
    ├── 3.11           # 内容: 使用次数
    └── 3.12
```

### 权限设置

```bash
# 注册中心目录权限
chown root:uvadm "$UV_ROOT/.muv-registry"
chmod 775 "$UV_ROOT/.muv-registry"

# 用户可以写自己的记录
chmod 1777 "$UV_ROOT/.muv-registry/users"
chmod 1777 "$UV_ROOT/.muv-registry/venvs"
```

## 总结

完整的 muv 使用追踪系统需要：

1. **注册中心** - 存储用户、venv、包、Python 的使用关系
2. **扫描工具** - 定期扫描文件系统同步状态
3. **查询命令** - 提供系统使用情况的视图
4. **安全清理** - 基于引用关系的安全删除

**核心价值**：
- 管理员可以看到完整的系统使用情况
- 删除 Python/缓存前知道会影响哪些用户
- 用户可以看到自己使用了哪些资源

**实现建议**：
- 从 `muv scan` 和 `muv status` 开始
- 逐步添加 `list` 和 `prune` 命令
- 自动注册可以作为可选功能
