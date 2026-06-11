# muv — 共享 uv 环境管理器

`muv` 是一个把 [uv](https://github.com/astral-sh/uv) 部署成**多用户共享环境**的轻量管理脚本。一次安装,全机用户共用同一份缓存、Python 和镜像源,同时通过 Unix 权限保护 uv 本身不被普通用户篡改。

## 特性

- **共享存储** —— 缓存与 Python 安装目录全机共用,省磁盘、省带宽
- **权限分层** —— 管理员(`uvusers` 组)与普通用户能力分明,由文件系统权限强制
- **保护 uv** —— 普通用户无法修改 uv 二进制或默认 Python 版本
- **可配置前缀** —— 默认装到 `/opt/uv`,可改到任意目录
- **自动选源** —— 安装时用 `cnpip` 测速挑最快的国内镜像
- **幂等** —— `install` 可重复执行以修复权限或升级

## 环境要求

- Linux,文件系统支持 ACL(主流发行版默认支持)
- `acl` 包(提供 `setfacl`/`getfacl`):
  ```bash
  sudo apt install acl     # Debian/Ubuntu
  sudo yum install acl     # RHEL/CentOS
  ```
- 仓库内需带 uv 二进制:`bin/uv`、`bin/uvx`

## 安装

由 root 执行一次:

```bash
sudo ./muv install                      # 装到默认 /opt/uv,并测速选镜像
sudo ./muv install --prefix /srv/uv     # 自定义安装前缀
sudo ./muv install --index <url>        # 指定镜像源,跳过测速
sudo ./muv install --python 3.12        # 指定默认 Python 版本
```

安装会:建 `uvusers` 组 → 建目录并设权限/ACL → 部署 `uv`/`uvx`/`pip`/`env.sh`/`muv` → 写入镜像源 → 装默认 Python → 自检。完成后 `muv` 位于 `$PREFIX/bin/muv`,进入共享 `PATH`。

## 快速开始

**管理员**把用户加入 `uvusers` 组(需 root,用户需重新登录生效):

```bash
sudo muv add-admin alice bob
```

**每个用户**在 `~/.bashrc` / `~/.zshrc` 中加一行:

```bash
source /opt/uv/env.sh        # 若改了前缀,换成 $PREFIX/env.sh
```

之后**全程无需 sudo**:

```bash
uv venv --python 3.12 && source .venv/bin/activate
uv pip install requests       # 命中共享缓存
```

## 命令参考

| 命令 | 作用 | 权限 |
|------|------|------|
| `muv install [--prefix d] [--group g] [--index url\|--no-mirror] [--python X.Y]` | 安装/修复共享环境(幂等) | root(自动 sudo) |
| `muv add-admin <user>...` | 把用户加入 `uvusers` 组 | root(自动 sudo) |
| `muv rm-admin <user>...` | 把用户移出 `uvusers` 组 | root(自动 sudo) |
| `muv set-index [<url>]` | 替换镜像源;不带 url 用 cnpip 测速自动选最快 | uvusers 成员 |
| `muv update <新uv目录\|uv二进制>` | 替换共享 uv/uvx 二进制 | uvusers 成员 |
| `muv doctor` | 自检:组 / 权限 / ACL / 二进制 / 当前源 | 任何人 |
| `muv help` | 显示帮助 | 任何人 |

## 工作原理

### 目录结构

```
$PREFIX/                   # 默认 /opt/uv
├── muv                    # 管理命令
├── env.sh                 # 用户 source 的环境脚本(664 root:uvusers)
├── bin/                   # 2775 root:uvusers — uv/uvx/pip + Python symlink
├── cache/                 # 2777 uvusers:uvusers — 共享缓存(无 sticky bit)
├── python/                # 3777 root:uvusers — 共享 Python(sticky bit 保护)
├── python-cache/          # 3777 root:uvusers — Python 下载缓存(sticky bit 保护)
└── tools/                 # 2775 root:uvusers — 共享工具(仅管理员可写)
```

### 权限模型

- **sticky bit** —— `python/`、`python-cache/` 设 sticky bit,用户只能删自己装的版本;`cache/` 不设,便于任意用户清理可重建的缓存。
- **default ACL** —— 共享目录用目录级 default ACL 保证新建文件对组(及 `cache` 的 others)可写,`env.sh` 不改用户 umask。
- **保护 uv** —— `bin/` 为 `2775 root:uvusers` 且 ACL `other::r-x`:非 uvusers 用户既无法改 `bin/uv` 内容,也无法在 `bin/` 内替换它,从文件系统层强制"只有 uv 管理员能管 uv"。`muv` 的成员校验只是更友好的报错,不是唯一防线。
- **hardlink** —— `UV_LINK_MODE=hardlink` 让多用户 venv 共享缓存数据块,要求缓存与用户 home 在同一文件系统分区,跨分区自动 fallback 到 copy(`muv install` 会提示)。

### sudo 边界

日常使用不碰 sudo。仅 `install` / `add-admin` / `rm-admin` 需要 root(建组、建目录、改 `/etc/group`),`muv` 会自动提权重跑。`set-index` / `update` / `doctor` 只需 `uvusers` 成员身份——因为 `env.sh`(组可写)和 `bin/`(setgid 组可写)都对该组开放。

## 配置(env.sh)

| 变量 | 值 | 生效范围 |
|------|----|----------|
| `UV_ROOT` / `UV_GROUP` | 安装前缀 / 管理员组(可被环境覆盖) | — |
| `UV_CACHE_DIR` | `$UV_ROOT/cache` | 所有用户 |
| `UV_DEFAULT_INDEX` | 镜像源(由 `muv` 写入,可被用户预设覆盖) | 所有用户 |
| `UV_PYTHON_INSTALL_DIR` / `UV_PYTHON_CACHE_DIR` | `$UV_ROOT/python` / `python-cache` | 所有用户 |
| `UV_MANAGED_PYTHON` | `true` | 所有用户 |
| `UV_LINK_MODE` | `hardlink` | 所有用户 |
| `PATH` | 追加 `$UV_ROOT/bin` | 所有用户 |
| `UV_PYTHON_BIN_DIR` / `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` | 共享 `bin` / `tools` | 仅管理员 |

## 角色与权限

| 操作 | 管理员 | 普通用户 |
|------|--------|----------|
| 运行 `uv`/`uvx`、用共享缓存与镜像源 | ✅ | ✅ |
| 使用已安装的 Python | ✅ | ✅ |
| 安装 Python 到共享目录 | ✅ | ✅ |
| 删除自己安装的 Python | ✅ | ✅ |
| 删除别人安装的 Python | ✅ | ❌ sticky bit |
| 创建 Python symlink 到 `$UV_ROOT/bin/` | ✅ | ❌(进 `~/.local/bin/`) |
| 安装/卸载共享工具 | ✅ | ❌(装到 `~/.local/`) |
| 修改 uv/uvx 二进制 | ✅ | ❌ |

## 运维

- **磁盘** —— 用户可持续往 `python/` 装版本、缓存也持续增长,无自动清理。定期看 `df`,必要时由管理员 `source env.sh` 后 `uv cache prune`(清陈旧条目)或低峰期 `uv cache clean`(整体清空,可重新下载恢复)。换源只留下少量索引元数据,不影响占大头的解包内容。
- **组成员变更** —— 加入/移除 `uvusers` 组后需重新登录生效。
- **升级 uv** —— `muv update <新uv二进制>`,会打印 old → new 版本。

## 许可证

[MIT](LICENSE) © 2026 muv contributors
