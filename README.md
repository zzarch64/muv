# muv

> 多用户共享 uv 环境管理器

`muv` 是一个将 [uv](https://github.com/astral-sh/uv) 部署为多用户共享环境的管理脚本。一次安装后，全机用户共用同一份缓存、Python 与镜像源，并通过 Unix 权限保护 uv 自身不被普通用户篡改。

## 使用场景

- **多用户服务器** —— 统一管理 Python 环境，避免每个用户各自安装相同包
- **共享缓存** —— 节省磁盘空间和网络带宽，同一包仅需下载一次
- **权限分层** —— 管理员管理 Python 和镜像源，普通用户使用共享环境

## 与 uv 的差异

| 特性 | uv | muv |
|------|----|-----|
| 用户模式 | 单用户 | 多用户共享 |
| 缓存管理 | 各用户独立缓存 | 全机共享缓存 |
| Python 管理 | 用户各自安装 | 统一托管、集中管理 |
| 权限控制 | 无 | 文件系统权限 + ACL 保护 |
| 镜像源锁定 | 不支持 | 支持，防止普通用户换源 |

## 核心原理

1. **共享文件而非整个环境** —— 通过 `hardlink` 共享底层 wheel 文件，各用户的 venv 仍保持独立
2. **权限分层保护** —— 文件系统权限 + ACL + sticky bit 确保 uv 自身不被普通用户篡改
3. **index 锁定机制** —— 只有 root 和 uvadm 成员可换源，普通用户无法写入新源桶

## 环境要求

- Linux，文件系统支持 ACL
- `acl` 包（提供 `setfacl`/`getfacl`）
- `curl` 或 `wget`

## 安装

```bash
sudo ./muv install                       # 安装到 /opt/uv，自动测速选源
sudo ./muv install --prefix /srv/uv      # 自定义安装前缀
sudo ./muv install --index <url>         # 指定镜像源
sudo ./muv install --index auto         # 自动测速选择最快镜像
sudo ./muv install --python 3.11         # 指定默认 Python 版本
```

## 快速开始

**管理员**将用户加入 `uvadm` 组：

```bash
muv grant alice bob
```

**每个用户**在 `~/.bashrc` 或 `~/.zshrc` 中添加：

```bash
source /opt/uv/env.sh
```

之后即可使用：

```bash
uv venv --python 3.12 && source .venv/bin/activate
uv pip install requests       # 命中共享缓存
```

## 命令参考

| 命令 | 说明 | 权限 |
|------|------|------|
| `muv install [--prefix <dir>] [--group <name>] [--index <url\|auto>] [--python <ver>]` | 安装共享环境 | root |
| `muv grant <user>...` | 授权用户加入 uvadm 组 | root |
| `muv revoke <user>...` | 撤销用户 uvadm 成员资格 | root |
| `muv mirror [<url>]` | 更换镜像源 | root / uvadm 成员 |
| `muv update` | 升级 uv 到最新版本 | root |
| `muv python add <ver>` | 安装共享 Python | uvadm 成员 |
| `muv python rm [--yes] <ver>` | 删除共享 Python | uvadm 成员 |
| `muv python list` | 列出已安装的 Python | 任何人 |
| `muv doctor` | 环境自检 | 任何人 |
| `muv help` | 显示帮助 | 任何人 |
| `muv --version` | 显示版本 | 任何人 |

## 角色权限

| 操作 | root | uvadm 成员 | 普通用户 |
|------|------|------------|----------|
| 安装共享环境 | ✅ | ❌ | ❌ |
| 授权/撤销用户 | ✅ | ❌ | ❌ |
| 换源 | ✅ | ✅ | ❌ |
| 安装/删除 Python | ✅ | ✅ | ❌ |
| 使用共享 uv | ✅ | ✅ | ✅ |

> **换源说明**：root 和 uvadm 成员都可直接执行 `muv mirror` 换源；uvadm 成员也可直接删除/重建 index 目录（sticky bit 保护下只能操作自己的目录）；普通用户无法换源。

## 故障排查

| 问题 | 解决方案 |
|------|----------|
| `muv: command not found` | 确保 `/opt/uv/bin` 在 PATH 中，或使用完整路径 |
| 权限被拒绝 | 使用 `sudo` 或确认你在 `uvadm` 组中 |
| index 锁报告失败 | 运行 `sudo muv mirror <url>` 重新锁定 |
| `env.sh: No such file` | 先运行 `sudo muv install` |
| ACL 相关错误 | 安装 `acl` 包：`sudo apt install acl` |

运行 `muv doctor` 进行完整的环境检查。

## 许可证

[MIT](LICENSE) © 2026 muv contributors
