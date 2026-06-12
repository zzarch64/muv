# muv — 共享 uv 环境管理器

`muv` 是一个把 [uv](https://github.com/astral-sh/uv) 部署成**多用户共享环境**的轻量管理脚本。一次安装,全机用户共用同一份缓存、Python 和镜像源,同时通过 Unix 权限保护 uv 本身不被普通用户篡改。

## 特性

- **共享存储** —— 缓存与 Python 安装目录全机共用,省磁盘、省带宽
- **权限分层** —— 管理员(`uvusers` 组)与普通用户能力分明,由文件系统权限强制
- **保护 uv** —— 普通用户无法修改 uv 二进制或默认 Python 版本
- **可配置前缀** —— 默认装到 `/opt/uv`,可改到任意目录
- **自动选源** —— 安装时用 `cnpip` 测速挑最快的国内镜像

## 环境要求

- Linux,文件系统支持 ACL(主流发行版默认支持)
- `acl` 包(提供 `setfacl`/`getfacl`):
  ```bash
  sudo apt install acl     # Debian/Ubuntu
  sudo yum install acl     # RHEL/CentOS
  ```
- `curl` 或 `wget`(安装时若 `bin/` 没有 uv,会从官网自动下载)

## 安装

由 root 执行一次:

```bash
sudo ./muv install                       # 装到默认 /opt/uv,并测速选镜像
sudo ./muv install --prefix /srv/uv      # 自定义安装前缀
sudo ./muv install --index <url>         # 指定镜像源,不执行镜像测速
sudo ./muv install --index auto         # 自动测速选最快镜像
sudo ./muv install --python 3.11         # 指定默认 Python 版本(不传默认 3.12)
```

安装后 `muv` 会被部署为 `$PREFIX/bin/muv`;后续镜像、升级、Python 管理等操作都通过安装后的 `muv` 执行,避免回写源码目录。

安装流程:

1. 创建 `uvusers` 组。
2. 创建共享目录并设置权限/ACL。
3. 部署 `uv`/`uvx`/`pip`/`env.sh`/`muv`。若源码 `bin/` 中没有 `uv`/`uvx`,安装器会从 `astral.sh` 下载。
4. 写入 `$PREFIX/muv.env`,保存管理员组、默认镜像源等机器配置。
5. 安装默认 Python 并执行自检。

## 快速开始

**管理员**将用户加入 `uvusers` 组(需 root,用户需重新登录生效):

```bash
muv grant alice bob
```

`muv grant` 会在需要时自动通过 `sudo` 重新执行。不要依赖 `sudo muv ...`;
`sudo` 的 `secure_path` 可能找不到 `$PREFIX/bin/muv`。如需显式 sudo,请使用完整路径,
例如 `sudo /opt/uv/bin/muv grant alice bob`。

**每个用户**在 `~/.bashrc` / `~/.zshrc` 中加一行:

```bash
source /opt/uv/env.sh        # 若改了前缀,换成 $PREFIX/env.sh
```

之后可直接使用共享 `uv` 环境:

```bash
uv venv --python 3.12 && source .venv/bin/activate
uv pip install requests       # 命中共享缓存
```

## 命令参考

| 命令 | 作用 | 权限 |
|------|------|------|
| `muv install [--prefix d] [--group g] [--index url\|auto] [--python X.Y]` | 安装/修复共享环境;`--python` 默认 `3.12` | root |
| `muv grant <user>...` | 把用户加入 `uvusers` 组 | root |
| `muv revoke <user>...` | 把用户移出 `uvusers` 组 | root |
| `muv mirror [<url>]` | 替换镜像源;不带 url 用 cnpip 测速自动选最快 | uvusers 成员 |
| `muv update` | 从官网下载最新 uv 并替换共享二进制 | root |
| `muv python add <ver>` | 安装共享 Python | uvusers 成员 |
| `muv python rm [--yes] <ver>` | 删除共享 Python(默认从终端确认;脚本化需显式 `--yes`) | uvusers 成员 |
| `muv python list` | 列出已安装的共享 Python | 任何人 |
| `muv doctor` | 自检:组 / 权限 / ACL / 二进制 / 当前源 | 任何人 |
| `muv help` | 显示帮助 | 任何人 |
| `muv --version` | 显示 muv 版本 | 任何人 |

## 工作原理

### 目录结构

```
$PREFIX/                   # 默认 /opt/uv
├── env.sh                 # 用户 source 的环境脚本模板(664 root:uvusers)
├── muv.env                # 机器相关运行配置(664 root:uvusers)
├── bin/                   # 2775 root:uvusers — uv/uvx/pip/muv + Python symlink
├── cache/                 # 3777 root:uvusers — 共享缓存(所有用户可写,sticky 防互删)
├── python/                # 2775 root:uvusers — 共享 Python(仅管理员可装/删)
├── python-cache/          # 2775 root:uvusers — Python 下载缓存(仅管理员可写)
└── tools/                 # 2775 root:uvusers — 共享工具(仅管理员可写)
```

### 权限模型

- **Python 集中管理** —— `python/`、`python-cache/` 为 `2775 root:uvusers`,只有管理员能装/删 Python;普通用户 `env.sh` 里 `UV_PYTHON_DOWNLOADS=never`,只能使用预置版本,需要新版本时找管理员 `muv python add`。这样避免版本在各用户家目录里分散。`cache/` 则对所有用户可写,共享可重建的缓存。
- **default ACL + sticky cache** —— 共享目录用目录级 default ACL 保证新建文件对组(及 `cache` 的 others)可写,`env.sh` 不改用户 umask。`cache/` 使用 sticky bit,普通用户不能删除其他用户拥有的缓存目录项。
- **保护 uv/muv** —— `bin/` 为 `2775 root:uvusers` 且 ACL `other::r-x`:非 uvusers 用户既无法改 `bin/uv` / `bin/muv` 内容,也无法在 `bin/` 内替换它们,从文件系统层强制"只有 uv 管理员能管 uv"。`muv` 的成员校验只是更友好的报错,不是唯一防线。
- **hardlink** —— `UV_LINK_MODE=hardlink` 让多用户 venv 共享缓存数据块,要求缓存与用户 home 在同一文件系统分区,跨分区自动 fallback 到 copy(安装时会提示)。

## 配置(env.sh / muv.env)

| 变量 | 值 | 生效范围 |
|------|----|----------|
| `UV_ROOT` / `UV_GROUP` | 安装前缀 / 管理员组(可被环境覆盖) | — |
| `UV_CACHE_DIR` | `$UV_ROOT/cache` | 所有用户 |
| `UV_DEFAULT_INDEX` | 镜像源(由 `muv install` / `muv mirror` 写入 `muv.env`,可被用户预设覆盖) | 所有用户 |
| `UV_PYTHON_INSTALL_DIR` / `UV_PYTHON_CACHE_DIR` | `$UV_ROOT/python` / `python-cache` | 所有用户 |
| `UV_MANAGED_PYTHON` | `true` | 所有用户 |
| `UV_PYTHON_DOWNLOADS` | `never`(普通用户)/ `manual`(管理员) | 分层 |
| `UV_LINK_MODE` | `hardlink` | 所有用户 |
| `PATH` | 追加 `$UV_ROOT/bin` | 所有用户 |
| `UV_PYTHON_BIN_DIR` / `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` | 共享 `bin` / `tools` | 仅管理员 |

## 角色与权限

常规使用不需要 sudo。`muv install` / `muv grant` / `muv revoke` / `muv update` 需要 root;`muv mirror` / `muv python add` / `muv python rm` 需要 `uvusers` 成员身份;`muv python list` / `muv doctor` / `muv help` 任意用户可执行。

| 操作 | 管理员 | 普通用户 |
|------|--------|----------|
| 运行 `uv`/`uvx`、写入共享缓存与使用镜像源 | ✅ | ✅ |
| 使用已安装的 Python | ✅ | ✅ |
| 安装 Python 到共享目录 | ✅ | ❌ |
| 删除共享 Python | ✅ | ❌ |
| 创建 Python symlink 到 `$UV_ROOT/bin/` | ✅ | ❌ |
| 安装/卸载共享工具 | ✅ | ❌ |
| 修改 uv/uvx 二进制 | ✅ | ❌ |

## 运维

- **磁盘** —— 用户可持续往 `python/` 装版本、缓存也持续增长,无自动清理。定期看 `df`,必要时由管理员 `source env.sh` 后 `uv cache prune`(清陈旧条目)或低峰期 `uv cache clean`(整体清空,可重新下载恢复)。换源只留下少量索引元数据,不影响占大头的解包内容。
- **删除共享 Python 有风险** —— venv 通过 symlink(及 `pyvenv.cfg` 路径)指向共享解释器,删除共享解释器会使依赖该路径的 venv 无法运行。使用 `muv python rm`,不要直接执行 `uv python uninstall`:删除前会显示风险提示并要求确认。误删后重新执行 `muv python add <ver>` 可恢复同一路径,无需重建 venv。`muv` 不扫描用户目录,也不提供 venv 反向索引。
- **组成员变更** —— 加入/移除 `uvusers` 组后需重新登录生效。
- **升级 uv** —— `muv update`,从官网拉最新版并打印 old → new 版本。

## 许可证

[MIT](LICENSE) © 2026 muv contributors
