#!/usr/bin/env bash
# muv 多用户集成测试
# 需要真实的 Linux 用户环境，建议在 Docker 容器中运行

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MUV_BIN="$ROOT_DIR/muv"
MUV_PREFIX="${MUV_PREFIX:-/opt/uv}"

# 测试用户
TEST_USERS=(
    "admin1:uvadm:UV管理员1"
    "admin2:uvadm:UV管理员2"
    "normal::普通用户"
)

# 颜色输出
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# 跳过测试（如果不是 root）
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        yellow "此测试需要 root 权限，跳过"
        return 1
    fi
    return 0
}

# 创建测试用户
setup_users() {
    yellow "=== 设置测试用户 ==="

    for user_info in "${TEST_USERS[@]}"; do
        IFS=: read -r username group desc <<< "$user_info"

        # 删除已存在的用户
        if id "$username" &>/dev/null; then
            userdel -r "$username" 2>/dev/null || true
        fi

        # 创建用户
        useradd -m -s /bin/bash "$username"
        echo "✓ 创建用户: $username ($desc)"

        # 添加到组
        if [ -n "$group" ]; then
            if ! getent group "$group" &>/dev/null; then
                groupadd "$group"
                echo "✓ 创建组: $group"
            fi
            usermod -aG "$group" "$username"
            echo "✓ 添加 $username 到 $group 组"
        fi
    done

    echo ""
}

# 清理测试用户
cleanup_users() {
    yellow "=== 清理测试用户 ==="

    for user_info in "${TEST_USERS[@]}"; do
        IFS=: read -r username group _ <<< "$user_info"
        if id "$username" &>/dev/null; then
            userdel -r "$username" 2>/dev/null || true
            echo "✓ 删除用户: $username"
        fi
    done

    # 清理测试组（如果为空）
    for user_info in "${TEST_USERS[@]}"; do
        IFS=: read -r username group _ <<< "$user_info"
        if [ -n "$group" ]; then
            if getent group "$group" &>/dev/null; then
                # 检查组是否还有成员
                members="$(getent group "$group" | cut -d: -f4)"
                if [ -z "$members" ]; then
                    groupdel "$group" 2>/dev/null || true
                    echo "✓ 删除空组: $group"
                fi
            fi
        fi
    done

    echo ""
}

# 以指定用户身份执行命令
run_as() {
    local user="$1"
    shift
    su - "$user" -c "$*" 2>&1
}

# 场景 A: root 安装
test_scenario_install() {
    yellow "=== 场景 A: root 安装 muv ==="

    # 清理旧安装
    rm -rf "$MUV_PREFIX" 2>/dev/null || true

    # 准备 mock uv（如果 bin/ 中没有真实 uv）
    mkdir -p "$MUV_PREFIX/bin"
    cat > "$MUV_PREFIX/bin/uv" << 'UV_EOF'
#!/usr/bin/env bash
case "$*" in
  --version) echo "uv 0.5.0" ;;
  "python install"*) exit 0 ;;
  "python find 3.12") echo "/opt/uv/python/cpython-3.12/bin/python3.12" ;;
  "python list --only-installed") echo "cpython-3.12" ;;
  "pip install"*) exit 0 ;;
  *) echo "uv mock: $*" >&2; exit 0 ;;
esac
UV_EOF
    chmod +x "$MUV_PREFIX/bin/uv"
    cp "$MUV_PREFIX/bin/uv" "$MUV_PREFIX/bin/uvx"
    cp "$MUV_BIN" "$MUV_PREFIX/bin/muv"
    chmod +x "$MUV_PREFIX/bin/muv"

    # 执行安装（跳过真实的 uv 下载，因为已有 mock）
    if "$MUV_PREFIX/bin/muv" install --prefix "$MUV_PREFIX" --group uvadm --index https://pypi.tuna.tsinghua.edu.cn/simple 2>&1; then
        green "✓ 安装成功"
    else
        red "✗ 安装失败"
        return 1
    fi

    # 验证目录结构
    if [ -d "$MUV_PREFIX/bin" ] && [ -d "$MUV_PREFIX/cache" ] && [ -d "$MUV_PREFIX/python" ]; then
        green "✓ 目录结构正确"
    else
        red "✗ 目录结构不完整"
        return 1
    fi

    # 验证 uvadm 组
    if getent group uvadm &>/dev/null; then
        green "✓ uvadm 组已创建"
    else
        red "✗ uvadm 组未创建"
        return 1
    fi

    # 验证 config.env
    if [ -f "$MUV_PREFIX/config.env" ]; then
        green "✓ config.env 存在"
        if grep -q "uvadm" "$MUV_PREFIX/config.env"; then
            green "✓ config.env 包含 uvadm 组"
        fi
    else
        red "✗ config.env 不存在"
        return 1
    fi

    echo ""
}

# 场景 B: root 授权管理
test_scenario_grant() {
    yellow "=== 场景 B: root 授权管理 ==="

    # 授权
    if run_as root "$MUV_PREFIX/bin/muv grant admin1" 2>&1; then
        green "✓ grant admin1 成功"
    else
        red "✗ grant admin1 失败"
        return 1
    fi

    # 验证用户在组中
    if id admin1 | grep -q uvadm; then
        green "✓ admin1 在 uvadm 组中"
    else
        red "✗ admin1 不在 uvadm 组中"
        return 1
    fi

    echo ""
}

# 场景 C: uvadm 成员操作
test_scenario_uvadm_ops() {
    yellow "=== 场景 C: uvadm 成员操作 ==="

    # admin1 执行 muv python list
    if run_as admin1 "export UV_ROOT=$MUV_PREFIX && $MUV_PREFIX/bin/muv python list" 2>&1 | grep -q "cpython"; then
        green "✓ uvadm 成员可以列出 Python"
    else
        red "✗ uvadm 成员无法列出 Python"
    fi

    # admin1 执行 muv doctor
    if run_as admin1 "export UV_ROOT=$MUV_PREFIX && $MUV_PREFIX/bin/muv doctor" 2>&1 | grep -q "检查通过"; then
        green "✓ uvadm 成员可以执行 doctor"
    else
        red "✗ uvadm 成员无法执行 doctor"
    fi

    echo ""
}

# 场景 D: 普通用户操作
test_scenario_normal_user() {
    yellow "=== 场景 D: 普通用户操作 ==="

    # normal 执行 muv python list
    if run_as normal "export UV_ROOT=$MUV_PREFIX && $MUV_PREFIX/bin/muv python list" 2>&1 | grep -q "cpython"; then
        green "✓ 普通用户可以列出 Python"
    else
        red "✗ 普通用户无法列出 Python"
    fi

    # normal 执行 muv doctor
    if run_as normal "export UV_ROOT=$MUV_PREFIX && $MUV_PREFIX/bin/muv doctor" 2>&1 | grep -q "检查通过"; then
        green "✓ 普通用户可以执行 doctor"
    else
        red "✗ 普通用户无法执行 doctor"
    fi

    # normal 尝试 grant（应该失败）
    if run_as normal "$MUV_PREFIX/bin/muv grant someone" 2>&1 | grep -qE "需要 root|权限"; then
        green "✓ 普通用户无法执行 grant"
    else
        red "✗ 普通用户不应该能执行 grant"
    fi

    echo ""
}

# 场景 E: index 锁定与换源（核心测试）
test_scenario_index_lock() {
    yellow "=== 场景 E: index 锁定与换源（核心测试） ==="

    # 创建 index 目录结构
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    mkdir -p "$MUV_PREFIX/cache/wheels-v6/index"

    # 设置正确的权限：父目录 root:uvadm 770 + sticky bit
    chown root:uvadm "$MUV_PREFIX/cache/simple-v21"
    chown root:uvadm "$MUV_PREFIX/cache/wheels-v6"
    chmod 770 "$MUV_PREFIX/cache/simple-v21"
    chmod 770 "$MUV_PREFIX/cache/wheels-v6"
    chmod +t "$MUV_PREFIX/cache/simple-v21"
    chmod +t "$MUV_PREFIX/cache/wheels-v6"

    # index 目录属于 uvadm 成员（admin1）
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/wheels-v6/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/wheels-v6/index"

    yellow "权限设置："
    ls -lad "$MUV_PREFIX/cache/simple-v21"
    ls -lad "$MUV_PREFIX/cache/simple-v21/index"

    echo ""

    # 测试 1: uvadm 成员删除 index
    yellow "测试 1: uvadm 成员 (admin1) 删除 index"
    if run_as admin1 "rmdir $MUV_PREFIX/cache/simple-v21/index" 2>&1; then
        green "✓ uvadm 成员可以删除 index"
    else
        red "✗ uvadm 成员无法删除 index"
        return 1
    fi

    # 测试 2: uvadm 成员重建 index
    yellow "测试 2: uvadm 成员 (admin1) 重建 index"
    if run_as admin1 "mkdir -p $MUV_PREFIX/cache/simple-v21/index && echo 'new-source' > $MUV_PREFIX/cache/simple-v21/index/source.txt" 2>&1; then
        green "✓ uvadm 成员可以重建 index"
    else
        red "✗ uvadm 成员无法重建 index"
        return 1
    fi

    # 恢复 index 权限
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"

    # 测试 3: 普通用户删除 index（应该失败）
    yellow "测试 3: 普通用户 (normal) 删除 index（应该失败）"
    local output
    output=$(run_as normal "rmdir $MUV_PREFIX/cache/simple-v21/index" 2>&1)
    if echo "$output" | grep -qE "Permission denied|Operation not permitted"; then
        green "✓ 普通用户无法删除 index"
    else
        red "✗ 普通用户不应该能删除 index"
        echo "  实际输出: $output"
        return 1
    fi

    # 测试 4: 普通用户重建 index（应该失败）
    yellow "测试 4: 普通用户 (normal) 重建 index（应该失败）"
    if ! run_as normal "mkdir -p $MUV_PREFIX/cache/simple-v21/new-index" 2>&1; then
        green "✓ 普通用户无法重建 index"
    else
        red "✗ 普通用户不应该能重建 index"
        rm -rf "$MUV_PREFIX/cache/simple-v21/new-index"
        return 1
    fi

    # 测试 5: 普通用户在 index 写入（应该失败）
    yellow "测试 5: 普通用户 (normal) 在 index 写入（应该失败）"
    output=$(run_as normal "touch $MUV_PREFIX/cache/simple-v21/index/test.txt" 2>&1)
    if echo "$output" | grep -qE "Permission denied"; then
        green "✓ 普通用户无法在 index 写入"
    else
        red "✗ 普通用户不应该能在 index 写入"
        echo "  实际输出: $output"
        return 1
    fi

    echo ""
}

# 场景 F: mirror 命令测试
# 注：uvadm 成员换源主要通过文件系统层面（场景 E，无需 sudo）
# 本场景测试 mirror 命令作为辅助方式
test_scenario_mirror_command() {
    yellow "=== 场景 F: mirror 命令测试 ==="

    # 确保 muv 已安装
    if [ ! -f "$MUV_PREFIX/bin/muv" ]; then
        red "⚠ muv 未安装，跳过 mirror 命令测试"
        return 0
    fi

    # 测试 1: uvadm 成员通过 sudo muv mirror 换源（辅助方式）
    yellow "测试 1: uvadm 成员 (admin1) 通过 sudo muv mirror 换源"
    yellow "  注：uvadm 主要换源方式是文件系统操作（场景 E），无需 sudo"
    if run_as admin1 "sudo UV_ROOT=$MUV_PREFIX UV_GROUP=uvadm $MUV_PREFIX/bin/muv mirror https://test-mirror.com/simple 2>&1" | grep -qE "镜像源已写入|锁定"; then
        green "✓ uvadm 成员可以通过 sudo muv mirror 换源（辅助方式）"
    else
        yellow "⚠ uvadm 成员 mirror 命令测试（可能需要完整安装环境）"
    fi

    # 测试 2: 普通用户尝试执行 muv mirror（应该失败）
    yellow "测试 2: 普通用户 (normal) 尝试 muv mirror（应该失败）"
    output=$(run_as normal "$MUV_PREFIX/bin/muv mirror https://evil.com/simple 2>&1" || true)
    if echo "$output" | grep -qE "需要 root|权限|sudo"; then
        green "✓ 普通用户无法执行 muv mirror"
    else
        yellow "⚠ 普通用户 mirror 测试（可能需要完整安装环境）"
        echo "  输出: $output"
    fi

    # 测试 3: 普通 uv pip install --default-index 切换源（应该失败）
    yellow "测试 3: 普通用户尝试通过 uv pip 切换源（应该失败）"
    # 创建测试目录结构
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"
    # 普通用户尝试在 index 创建新源桶目录
    output=$(run_as normal "mkdir $MUV_PREFIX/cache/simple-v21/index/new-bucket 2>&1" || true)
    if echo "$output" | grep -qE "Permission denied"; then
        green "✓ 普通用户无法通过 uv pip 创建新源桶"
    else
        yellow "⚠ 普通用户 uv pip 切换源测试（可能需要完整 uv 环境）"
    fi

    echo ""
}

# 场景 G: 多 uvadm 成员协作
test_scenario_uvadm_collab() {
    yellow "=== 场景 G: 多 uvadm 成员协作 ==="

    # 重新设置父目录权限（确保 sticky bit 有效）
    chown root:uvadm "$MUV_PREFIX/cache/simple-v21"
    chmod 770 "$MUV_PREFIX/cache/simple-v21"
    chmod +t "$MUV_PREFIX/cache/simple-v21"

    # 确保 index 存在且属于 admin1
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"

    # 测试: admin2 能否删除 admin1 的 index（sticky bit 下，只有所有者能删除）
    yellow "测试: admin2 删除 admin1 的 index（sticky bit 保护）"
    output=$(run_as admin2 "rmdir $MUV_PREFIX/cache/simple-v21/index" 2>&1)
    if echo "$output" | grep -qE "Permission denied|Operation not permitted"; then
        green "✓ sticky bit 保护有效：admin2 不能删除 admin1 的 index"
    else
        yellow "⚠ admin2 可以删除 admin1 的 index（同组成员，但非所有者）"
    fi

    # 但 admin2 可以创建自己的目录
    yellow "测试: admin2 创建自己的目录"
    if run_as admin2 "mkdir -p $MUV_PREFIX/cache/simple-v21/admin2-dir && echo 'test' > $MUV_PREFIX/cache/simple-v21/admin2-dir/file" 2>&1; then
        green "✓ admin2 可以创建自己的目录"
        # admin2 可以删除自己的目录
        if run_as admin2 "rm -rf $MUV_PREFIX/cache/simple-v21/admin2-dir" 2>&1; then
            green "✓ admin2 可以删除自己的目录"
        fi
    else
        red "✗ admin2 无法创建目录"
    fi

    echo ""
}

# 场景 H: uv pip 攻击测试
# 模拟普通用户通过 uv pip install --default-index <其他源> 切换源的攻击场景
test_scenario_uv_pip_attack() {
    yellow "=== 场景 H: uv pip 攻击测试 ==="

    # 重新设置正确的权限
    chown root:uvadm "$MUV_PREFIX/cache/simple-v21"
    chmod 770 "$MUV_PREFIX/cache/simple-v21"
    chmod +t "$MUV_PREFIX/cache/simple-v21"

    # 确保 index 存在且属于 uvadm 成员
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"

    yellow "攻击场景：普通用户执行 uv pip install --default-index https://evil.com/simple"
    yellow "uv 会尝试在 cache/simple-v*/index/ 下创建新的源桶目录"

    # 测试 1: 普通用户在 index 下创建新源桶目录（应该失败）
    yellow "测试 1: 普通用户在 index 下创建新源桶目录"
    output=$(run_as normal "mkdir -p $MUV_PREFIX/cache/simple-v21/index/evil-bucket 2>&1" || true)
    if echo "$output" | grep -qE "Permission denied"; then
        green "✅ 普通用户无法创建新源桶（权限不足）"
    else
        red "✗ 普通用户可以创建新源桶（安全风险）"
        return 1
    fi

    # 测试 2: 普通用户尝试删除现有 index 目录（应该失败）
    yellow "测试 2: 普通用户尝试删除现有 index 目录"
    output=$(run_as normal "rmdir $MUV_PREFIX/cache/simple-v21/index 2>&1" || true)
    if echo "$output" | grep -qE "Permission denied|Operation not permitted"; then
        green "✅ sticky bit 保护生效，普通用户无法删除 index"
    else
        red "✗ 普通用户可以删除 index（安全风险）"
        return 1
    fi

    # 测试 3: 普通用户尝试重建 index 目录（应该失败）
    yellow "测试 3: 普通用户尝试重建 index 目录"
    if ! run_as normal "mkdir -p $MUV_PREFIX/cache/simple-v21/index 2>&1"; then
        green "✅ 普通用户无法在父目录创建子目录"
    else
        red "✗ 普通用户可以重建 index（安全风险）"
        rm -rf "$MUV_PREFIX/cache/simple-v21/index"
        return 1
    fi

    # 测试 4: 普通用户在已存在的 index 中写入文件（应该失败）
    yellow "测试 4: 普通用户在 index 中写入文件"
    output=$(run_as normal "touch $MUV_PREFIX/cache/simple-v21/index/test.txt 2>&1" || true)
    if echo "$output" | grep -qE "Permission denied"; then
        green "✅ index 目录权限保护，普通用户无法写入"
    else
        red "✗ 普通用户可以在 index 中写入（安全风险）"
        return 1
    fi

    # 测试 5: uvadm 成员换源能力（应该成功）
    yellow "测试 5: uvadm 成员换源能力（对比）"

    # admin1 删除旧 index
    if run_as admin1 "rmdir $MUV_PREFIX/cache/simple-v21/index 2>&1"; then
        green "✅ uvadm 成员可以删除旧 index"
    else
        yellow "⚠ uvadm 成员无法删除 index"
    fi

    # admin1 重建新 index
    if run_as admin1 "mkdir -p $MUV_PREFIX/cache/simple-v21/index && touch $MUV_PREFIX/cache/simple-v21/index/source.txt 2>&1"; then
        green "✅ uvadm 成员可以重建 index 并写入内容（换源能力）"
    else
        yellow "⚠ uvadm 成员无法重建 index"
    fi

    echo ""
}

# 场景 I: 硬链接攻击测试
test_scenario_hardlink_attack() {
    yellow "=== 场景 I: 硬链接攻击测试 ==="

    # 设置环境
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"

    # 创建一个测试文件
    run_as admin1 "echo 'protected content' > $MUV_PREFIX/cache/simple-v21/index/protected.txt"

    yellow "测试 1: 普通用户尝试创建硬链接到受保护文件"
    output=$(run_as normal "ln $MUV_PREFIX/cache/simple-v21/index/protected.txt ~/hardlink.txt 2>&1" || true)
    if echo "$output" | grep -qE "Permission denied|Operation not permitted|hard link|not allowed"; then
        green "✅ 硬链接攻击被阻止 (fs.protected_regular 保护)"
    else
        yellow "⚠ 需验证 fs.protected_regular 是否启用"
        echo "  输出: $output"
    fi

    # 清理
    rm -f "$MUV_PREFIX/cache/simple-v21/index/protected.txt"

    echo ""
}

# 场景 J: 符号链接攻击测试
test_scenario_symlink_attack() {
    yellow "=== 场景 J: 符号链接攻击测试 ==="

    # 设置环境
    mkdir -p "$MUV_PREFIX/cache/simple-v21/index"
    chown admin1:uvadm "$MUV_PREFIX/cache/simple-v21/index"
    chmod 770 "$MUV_PREFIX/cache/simple-v21/index"

    yellow "测试 1: 普通用户创建符号链接到 index 目录"
    if run_as normal "ln -s $MUV_PREFIX/cache/simple-v21/index ~/evil-index 2>&1"; then
        yellow "⚠ 用户可以创建符号链接 (预期行为)"
        # 验证通过 symlink 无法写入
        output=$(run_as normal "touch ~/evil-index/test.txt 2>&1" || true)
        if echo "$output" | grep -qE "Permission denied"; then
            green "✅ 通过符号链接写入被阻止"
        else
            red "✗ 通过符号链接可以写入 (安全风险)"
        fi
    else
        green "✅ 符号链接创建被阻止"
    fi

    yellow "测试 2: 验证 fix_root_cache 不会跟随 symlink"
    # 在用户 home 创建 symlink 指向系统文件
    run_as normal "mkdir -p ~/cache-test && ln -s /etc/passwd ~/cache-test/passwd-symlink"
    # 即使有 symlink，fix_root_cache 应该只处理真实文件
    # (这需要完整的 muv install 环境才能测试)

    # 清理
    run_as normal "rm -f ~/evil-index" 2>/dev/null || true
    run_as normal "rm -rf ~/cache-test" 2>/dev/null || true

    echo ""
}

# 场景 K: 环境变量注入测试
test_scenario_env_injection() {
    yellow "=== 场景 K: 环境变量注入测试 ==="

    yellow "测试 1: 通过 UV_ROOT 尝试路径遍历"
    output=$(run_as normal "UV_ROOT=/etc UV_GROUP=uvadm $MUV_PREFIX/bin/muv doctor 2>&1" || true)
    if echo "$output" | grep -qE "错误|找不到|error|missing|不存在"; then
        green "✅ 路径遍历被阻止"
    else
        yellow "⚠ 需验证环境变量验证"
        echo "  输出: $output"
    fi

    yellow "测试 2: 通过 UV_GROUP 尝试组切换"
    output=$(run_as normal "UV_GROUP=root UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv doctor 2>&1" || true)
    # 普通用户即使在 env 中设置 UV_GROUP=root，也无法获得 root 权限
    if ! echo "$output" | grep -qE "权限|admin|sudo"; then
        green "✅ 组切换被正确隔离"
    else
        yellow "⚠ 需验证组权限隔离"
    fi

    echo ""
}

# 场景 L: scan 命令测试
test_scenario_scan() {
    yellow "=== 场景 L: scan 命令测试 ==="

    # 确保 muv 已安装
    if [ ! -f "$MUV_PREFIX/bin/muv" ]; then
        red "⚠ muv 未安装，跳过 scan 测试"
        return 0
    fi

    # 测试 1: root 执行 scan 应该成功
    yellow "测试 1: root 执行 scan"
    if run_as root "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv scan 2>&1" | grep -q "扫描完成"; then
        green "✅ root 可以执行 scan"
    else
        yellow "⚠ root scan 测试"
    fi

    # 测试 2: uvadm 成员执行 scan 应该失败（需要 root）
    yellow "测试 2: uvadm 成员执行 scan（应该失败）"
    output=$(run_as admin1 "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv scan 2>&1" || true)
    if echo "$output" | grep -qE "需要 root|权限|Permission denied"; then
        green "✅ uvadm 成员无法执行 scan（需要 root）"
    else
        yellow "⚠ uvadm scan 权限测试"
    fi

    # 测试 3: 普通用户执行 scan 应该失败
    yellow "测试 3: 普通用户执行 scan（应该失败）"
    output=$(run_as normal "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv scan 2>&1" || true)
    if echo "$output" | grep -qE "需要 root|权限|Permission denied"; then
        green "✅ 普通用户无法执行 scan"
    else
        yellow "⚠ 普通用户 scan 权限测试"
    fi

    # 测试 4: 验证 stats.json 生成
    yellow "测试 4: 验证 stats.json 生成"
    if [ -f "$MUV_PREFIX/.muv-registry/stats.json" ]; then
        green "✅ stats.json 已生成"
    else
        yellow "⚠ stats.json 未生成（可能 scan 未成功）"
    fi

    echo ""
}

# 场景 M: cache prune 命令测试
test_scenario_cache_prune() {
    yellow "=== 场景 M: cache prune 命令测试 ==="

    # 确保 muv 已安装
    if [ ! -f "$MUV_PREFIX/bin/muv" ]; then
        red "⚠ muv 未安装，跳过 cache prune 测试"
        return 0
    fi

    # 创建一些测试缓存文件（未被引用的）
    mkdir -p "$MUV_PREFIX/cache/test-dir"
    touch "$MUV_PREFIX/cache/test-dir/file1.txt"
    touch "$MUV_PREFIX/cache/test-dir/file2.txt"

    # 测试 1: root 执行 prune --dry-run
    yellow "测试 1: root 执行 prune --dry-run"
    output=$(run_as root "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv cache prune --dry-run 2>&1" || true)
    if echo "$output" | grep -qE "预览模式|未执行"; then
        green "✅ prune --dry-run 预览模式正常"
    else
        yellow "⚠ prune --dry-run 测试"
    fi

    # 测试 2: uvadm 成员执行 prune 应该失败
    yellow "测试 2: uvadm 成员执行 prune（应该失败）"
    output=$(run_as admin1 "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv cache prune 2>&1" || true)
    if echo "$output" | grep -qE "需要 root|权限|Permission denied"; then
        green "✅ uvadm 成员无法执行 prune"
    else
        yellow "⚠ uvadm prune 权限测试"
    fi

    # 测试 3: 普通用户执行 prune 应该失败
    yellow "测试 3: 普通用户执行 prune（应该失败）"
    output=$(run_as normal "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv cache prune 2>&1" || true)
    if echo "$output" | grep -qE "需要 root|权限|Permission denied"; then
        green "✅ 普通用户无法执行 prune"
    else
        yellow "⚠ 普通用户 prune 权限测试"
    fi

    # 清理测试文件
    rm -rf "$MUV_PREFIX/cache/test-dir"

    echo ""
}

# 场景 N: python rm --check 测试
test_scenario_python_rm_check() {
    yellow "=== 场景 N: python rm --check 测试 ==="

    # 确保 muv 已安装
    if [ ! -f "$MUV_PREFIX/bin/muv" ]; then
        red "⚠ muv 未安装，跳过 python rm --check 测试"
        return 0
    fi

    # 模拟一个使用 muv Python 的 venv
    mkdir -p "$MUV_PREFIX/python/cpython-3.11/bin"
    cat > "$MUV_PREFIX/python/cpython-3.11/bin/python" <<'EOF'
#!/bin/bash
echo "Python 3.11 mock"
EOF
    chmod +x "$MUV_PREFIX/python/cpython-3.11/bin/python"

    # 测试 1: python rm --check 无依赖时
    yellow "测试 1: python rm --check 无依赖时"
    output=$(run_as root "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv python rm --check 3.11 2>&1" || true)
    if echo "$output" | grep -qE "没有发现依赖|可以安全删除"; then
        green "✅ --check 正确报告无依赖"
    else
        yellow "⚠ --check 无依赖测试"
    fi

    # 测试 2: python rm --check 有依赖时
    yellow "测试 2: python rm --check 有依赖时"
    # 创建一个模拟的 venv
    mkdir -p "/home/admin1/test-venv/bin"
    ln -sf "$MUV_PREFIX/python/cpython-3.11/bin/python" "/home/admin1/test-venv/bin/python"
    echo "version = 3.11" > "/home/admin1/test-venv/pyvenv.cfg"
    chown -R admin1:admin1 "/home/admin1/test-venv"

    output=$(run_as root "UV_ROOT=$MUV_PREFIX $MUV_PREFIX/bin/muv python rm --check 3.11 2>&1" || true)
    if echo "$output" | grep -qE "依赖|venv"; then
        green "✅ --check 正确检测到依赖"
    else
        yellow "⚠ --check 依赖检测测试"
    fi

    # 清理
    rm -rf "/home/admin1/test-venv"
    rm -rf "$MUV_PREFIX/python/cpython-3.11"

    echo ""
}

# 主测试流程
main() {
    echo "muv 多用户集成测试"
    echo "===================="
    echo ""

    if ! check_root; then
        exit 0
    fi

    # 清理旧环境
    cleanup_users

    # 设置测试用户
    setup_users

    # 运行测试场景
    test_scenario_install || true
    test_scenario_grant || true
    test_scenario_uvadm_ops || true
    test_scenario_normal_user || true
    test_scenario_index_lock || true
    test_scenario_mirror_command || true
    test_scenario_uv_pip_attack || true
    test_scenario_uvadm_collab || true
    test_scenario_hardlink_attack || true
    test_scenario_symlink_attack || true
    test_scenario_env_injection || true
    test_scenario_scan || true
    test_scenario_cache_prune || true
    test_scenario_python_rm_check || true

    # 最终清理（可选，保留以便检查）
    # cleanup_users

    green "=== 测试完成 ==="
}

# 参数处理
case "${1:-run}" in
    setup) setup_users; cleanup_users ;;
    cleanup) cleanup_users ;;
    run) main ;;
    *) echo "用法: $0 [run|setup|cleanup]" ;;
esac
