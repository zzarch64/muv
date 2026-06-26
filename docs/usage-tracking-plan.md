# muv 使用统计与缓存清理功能实现计划

## 功能概述

为 muv 添加使用统计和安全缓存清理功能，解决多用户共享环境下的管理问题：
- 管理员可以查看全局使用情况
- 删除 Python 前检查依赖关系
- 安全清理缓存（基于硬链接引用计数）

## 新增命令

| 命令 | 用途 | 权限 | 优先级 |
|------|------|------|--------|
| `muv scan` | 扫描系统，更新统计 | root | P1 |
| `muv status` | 显示全局统计信息 | root | P1 |
| `muv cache prune` | 清理未使用的缓存 | root | P2 |
| `muv python rm --check` | 删除 Python 前检查 | root | P1 |

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    $UV_ROOT/.muv-registry/                   │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  stats.json              # 全局统计（root 写，所有人读）     │
│  ├── scan_time           # 最后扫描时间                      │
│  ├── users               # 活跃用户列表                      │
│  ├── venvs_total         # venv 总数                         │
│  ├── python_usage        # Python 版本使用统计               │
│  └── cache_stats         # 缓存统计                          │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## 实现阶段

### 阶段 1: scan 命令（P1）

**目标**: 扫描系统，收集使用统计

**实现**:

```bash
cmd_scan() {
    require_root  # 必须是 root
    acquire_muv_lock
    
    local registry="$UV_ROOT/.muv-registry"
    mkdir -p "$registry"
    
    echo "扫描系统..."
    
    # 1. 扫描用户（检查哪些用户 source 了 env.sh）
    scan_users > "$registry/users.tmp"
    
    # 2. 扫描 venv（通过 pyvenv.cfg）
    scan_venvs > "$registry/venvs.tmp"
    
    # 3. 扫描 Python 使用
    scan_python_usage > "$registry/python.tmp"
    
    # 4. 扫描缓存统计
    scan_cache_stats > "$registry/cache.tmp"
    
    # 5. 合并结果
    merge_stats > "$registry/stats.json"
    
    # 6. 清理临时文件
    rm -f "$registry"/*.tmp
    
    local venv_count=$(jq '.venvs_total' "$registry/stats.json")
    local cache_size=$(jq '.cache_stats.size_mb' "$registry/stats.json")
    
    log "扫描完成: $venv_count 个 venv，缓存 ${cache_size} MB"
}

scan_users() {
    # 查找 source 了 env.sh 的用户
    local users=()
    for user_home in /home/*; do
        local user=$(basename "$user_home")
        if grep -q "source $UV_ROOT/env.sh" "$user_home/.bashrc" "$user_home/.zshrc" 2>/dev/null; then
            users+=("$user")
        fi
    done
    
    printf '%s\n' "${users[@]}"
}

scan_venvs() {
    # 查找所有 venv
    find /home -name "pyvenv.cfg" 2>/dev/null | while read -r cfg; do
        local venv_dir=$(dirname "$cfg")
        local user=$(stat -c '%U' "$venv_dir")
        local version=$(grep "^version = " "$cfg" | cut -d= -f2 | xargs)
        local created=$(stat -c '%Y' "$cfg")
        
        # 检查是否使用 muv 的 Python
        local python_link="$venv_dir/bin/python"
        if [ -L "$python_link" ]; then
            local target=$(readlink "$python_link")
            if [[ "$target" == "$UV_ROOT/python"* ]]; then
                printf '%s|%s|%s|%s\n' "$user" "$venv_dir" "$version" "$created"
            fi
        fi
    done
}

scan_python_usage() {
    # 统计各 Python 版本使用次数
    declare -A usage
    while IFS='|' read -r user path version created; do
        [ -n "$version" ] && ((usage[$version]++))
    done < "$registry/venvs.tmp"
    
    for version in "${!usage[@]}"; do
        printf '%s:%s\n' "$version" "${usage[$version]}"
    done
}

scan_cache_stats() {
    # 缓存统计
    local cache_dir="$UV_ROOT/cache"
    local size=$(du -sm "$cache_dir" 2>/dev/null | cut -f1)
    local files=$(find "$cache_dir" -type f | wc -l)
    
    printf '%s|%s\n' "$size" "$files"
}

merge_stats() {
    # 生成 JSON 格式的统计
    local now=$(date +%s)
    
    cat <<EOF
{
  "scan_time": $now,
  "scan_time_readable": "$(date -d @$now)",
  "users": [
$(scan_users | sed 's/.*/    "&",/' | sed '$s/,$//')
  ],
  "venvs_total": $(wc -l < "$registry/venvs.tmp"),
  "python_usage": {
$(while IFS=: read -r version count; do
    printf '    "%s": %s,\n' "$version" "$count"
done < "$registry/python.tmp" | sed '$s/,$//')
  },
  "cache_stats": {
    "size_mb": $(cut -d'|' -f1 "$registry/cache.tmp"),
    "files": $(cut -d'|' -f2 "$registry/cache.tmp")
  }
}
EOF
}
```

**文件修改**:
- `muv`: 添加 `cmd_scan`, `scan_users`, `scan_venvs` 等函数
- `muv`: 添加 `require_root` 函数

---

### 阶段 2: status 命令（P1）

**目标**: 显示全局统计信息

**实现**:

```bash
cmd_status() {
    require_root  # 必须是 root
    
    local registry="$UV_ROOT/.muv-registry/stats.json"
    
    if [ ! -f "$registry" ]; then
        warn "未找到统计数据，请先运行: sudo muv scan"
        return 1
    fi
    
    local scan_time=$(jq -r '.scan_time_readable' "$registry")
    local venvs_total=$(jq '.venvs_total' "$registry")
    local cache_size=$(jq '.cache_stats.size_mb' "$registry")
    
    echo "muv 系统状态"
    echo "============"
    echo ""
    echo "扫描时间: $scan_time"
    echo ""
    echo "用户活跃:"
    jq -r '.users[]' "$registry" | while read -r user; do
        echo "  - $user"
    done
    echo ""
    echo "Venv 总数: $venvs_total"
    echo ""
    echo "共享 Python 使用:"
    jq -r '.python_usage | to_entries[] | "  \(.key): \(.value) 个 venv"' "$registry"
    echo ""
    echo "缓存统计:"
    echo "  大小: ${cache_size} MB"
}
```

**文件修改**:
- `muv`: 添加 `cmd_status` 函数
- `muv`: 更新命令分发逻辑

---

### 阶段 3: python rm --check（P1）

**目标**: 删除 Python 前检查依赖关系

**实现**:

```bash
cmd_python() {
    local action="${1:-}"; shift || true
    # ... 现有代码 ...
    
    case "$action" in
        rm|remove|uninstall)
            require_admin
            acquire_muv_lock
            
            # 检查 --check 参数
            local check_mode=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --check) check_mode=1; shift ;;
                    --yes) assume_yes=1; shift ;;
                    -*) die "未知参数: $1" ;;
                    *) ver="$1"; shift ;;
                esac
            done
            
            [ -n "$ver" ] || die "用法: muv python rm [--check] [--yes] <ver>"
            
            if [ "$check_mode" -eq 1 ]; then
                check_python_dependencies "$ver"
                return $?
            fi
            
            # 原有的删除逻辑
            pbin="$(run_uv python find "$ver" 2>/dev/null || true)"
            # ...
            ;;
    esac
}

check_python_dependencies() {
    local version="$1"
    local python_path="$UV_ROOT/python/cpython-$version"
    
    if [ ! -d "$python_path" ]; then
        echo "Python $version 未安装"
        return 1
    fi
    
    echo "检查依赖关系..."
    echo ""
    
    local dependencies=()
    
    # 扫描所有 venv，查找使用此 Python 的
    find /home -name "pyvenv.cfg" 2>/dev/null | while read -r cfg; do
        local venv_dir=$(dirname "$cfg")
        local python_link="$venv_dir/bin/python"
        
        if [ -L "$python_link" ]; then
            local target=$(readlink "$python_link")
            if [[ "$target" == "$python_path"* ]]; then
                local user=$(stat -c '%U' "$venv_dir")
                dependencies+=("$user:$venv_dir")
            fi
        fi
    done
    
    if [ ${#dependencies[@]} -gt 0 ]; then
        echo "以下 venv 依赖 Python $version："
        for dep in "${dependencies[@]}"; do
            local user="${dep%%:*}"
            local path="${dep##*:}"
            echo "  - $path (用户: $user)"
        done
        echo ""
        echo "删除这些 venv 后再删除 Python，或使用 --force 强制删除"
        return 1
    else
        echo "✓ 没有发现依赖 Python $version 的 venv"
        echo "可以安全删除"
        return 0
    fi
}
```

**文件修改**:
- `muv`: 修改 `cmd_python` 函数，添加 `--check` 参数支持
- `muv`: 添加 `check_python_dependencies` 函数
- `README.md`: 更新命令参考

---

### 阶段 4: cache prune 命令（P2）

**目标**: 安全清理未使用的缓存

**实现**:

```bash
cmd_cache() {
    local action="${1:-}"; shift || true
    
    case "$action" in
        prune)
            require_root  # 必须是 root
            acquire_muv_lock
            cmd_cache_prune "$@"
            ;;
        *)
            die "用法: muv cache prune [--dry-run]"
            ;;
    esac
}

cmd_cache_prune() {
    local dry_run=0
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run|-n) dry_run=1; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done
    
    local cache_dir="$UV_ROOT/cache"
    local stale_dir="$UV_ROOT/.muv-registry/stale"
    
    mkdir -p "$stale_dir"
    
    echo "第 1 步: 扫描缓存文件..."
    local total=0
    local unused=0
    
    # 扫描缓存目录
    find "$cache_dir" -type f | while read -r file; do
        ((total++))
        local links=$(stat -c '%h' "$file")
        
        # links = 1 说明只有缓存中有这个文件
        if [ "$links" -eq 1 ]; then
            ((unused++))
            local inode=$(stat -c '%i' "$file")
            touch "$stale_dir/$inode"
            
            [ "$dry_run" -eq 1 ] && echo "  可删除: $file"
        fi
    done
    
    echo "第 2 步: 统计未使用文件..."
    local stale_count=$(find "$stale_dir" -type f | wc -l)
    local stale_size=0
    
    for marker in "$stale_dir"/*; do
        [ -f "$marker" ] || continue
        local inode=$(basename "$marker")
        local file=$(find "$cache_dir" -inum "$inode" -print -quit 2>/dev/null)
        if [ -n "$file" ]; then
            local size=$(stat -c '%s' "$file")
            ((stale_size += size))
        fi
    done
    
    local size_mb=$((stale_size / 1024 / 1024))
    
    echo ""
    echo "扫描结果："
    echo "  总缓存文件: $total"
    echo "  未使用文件: $stale_count"
    echo "  可释放空间: ${size_mb} MB"
    
    if [ "$dry_run" -eq 1 ]; then
        echo ""
        echo "预览模式，未执行删除"
        return 0
    fi
    
    echo ""
    printf "确认删除? [y/N] "
    read -r answer
    
    if [ "$answer" = "y" ]; then
        echo "删除中..."
        local deleted=0
        
        for marker in "$stale_dir"/*; do
            [ -f "$marker" ] || continue
            local inode=$(basename "$marker")
            local file=$(find "$cache_dir" -inum "$inode" -print -quit 2>/dev/null)
            
            if [ -n "$file" ]; then
                # 最后检查一次引用计数
                local links=$(stat -c '%h' "$file")
                if [ "$links" -eq 1 ]; then
                    rm -f "$file"
                    ((deleted++))
                fi
            fi
            rm -f "$marker"
        done
        
        log "清理完成: 删除 $deleted 个文件，释放 ${size_mb} MB"
    else
        echo "已取消"
    fi
}
```

**文件修改**:
- `muv`: 添加 `cmd_cache` 函数
- `muv`: 添加 `cmd_cache_prune` 函数
- `muv`: 更新命令分发逻辑
- `README.md`: 更新命令参考

---

## 权限函数

添加统一的权限检查函数：

```bash
require_root() {
    [ "$(id -u)" -eq 0 ] || die "此命令需要 root 权限"
}

# 现有的 require_admin 保持不变（用于 python add 等命令）
require_admin() {
    [ "$(id -u)" -eq 0 ] && return 0
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$UV_GROUP" && return 0
    die "需要是 root 或 $UV_GROUP 组成员"
}
```

---

## 测试计划

### 单元测试（tests/test_muv.sh）

```bash
# 测试 require_root
test_require_root()

# 测试 scan 命令的基本功能
test_scan_command()

# 测试 stats.json 生成
test_stats_generation()
```

### 集成测试（tests/test_multi.sh）

```bash
# 场景 L: scan 命令测试
test_scenario_scan()

# 场景 M: status 命令测试
test_scenario_status()

# 场景 N: python rm --check 测试
test_scenario_python_rm_check()

# 场景 O: cache prune 测试
test_scenario_cache_prune()
```

---

## 实现顺序

| 阶段 | 功能 | 预计工作量 |
|------|------|-----------|
| 1 | `require_root` 函数 | 0.5h |
| 2 | `muv scan` 命令 | 2h |
| 3 | `muv status` 命令 | 1h |
| 4 | `muv python rm --check` | 1.5h |
| 5 | `muv cache prune` 命令 | 2h |
| 6 | 测试 | 2h |
| 7 | 文档更新 | 0.5h |

**总计**: 约 9.5 小时

---

## 文件变更清单

| 文件 | 变更 |
|------|------|
| `muv` | 添加新函数和命令 |
| `README.md` | 更新命令参考 |
| `tests/test_muv.sh` | 添加单元测试 |
| `tests/test_multi.sh` | 添加集成测试 |

---

## 注意事项

1. **权限安全**: scan/status/prune 必须是 root，不能放宽
2. **引用计数**: cache prune 依赖硬链接引用计数，100% 可靠
3. **JSON 解析**: 需要系统有 `jq` 命令，或用纯 bash 实现
4. **性能考虑**: 扫描大量用户目录可能较慢，考虑添加进度提示
5. **错误处理**: 目录不存在、权限不足等情况需要优雅处理
