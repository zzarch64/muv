# muv — 共享 uv 环境管理器

`muv` 是一个将 [uv](https://github.com/astral-sh/uv) 部署为**多用户共享环境**的轻量管理脚本。一次安装后,全机用户共用同一份缓存、Python 与镜像源,并通过 Unix 权限保护 uv 自身不被普通用户篡改。

## 为什么用 muv

在多用户机器上,Python 环境的主要磁盘开销来自**每个用户、每个 venv 各自保存一份相同的包**——一个 2 GB 的 PyTorch,十个用户即占用约 20 GB。muv 从根本上消除这类重复,关键在于它**共享的粒度**与 conda/mamba 不同。

**共享文件,而不是共享整个环境(核心优势)。** muv 让每个用户保留自己独立的 venv,只把底层文件(wheel 解包内容,含 `.so` 等编译二进制)通过 `UV_LINK_MODE=hardlink` 链接到全机共享缓存——同一包版本在磁盘上仅存一份,而各用户的 venv 仍彼此隔离、互不影响。conda/mamba 若要跨用户、或共享 pip 安装的包,实际只能共享整个环境:多人共用同一个 env,安装包需对其拥有写权,一人改动即波及所有人,设为只读则每次安装都需经管理员代办。(conda 对自家 conda 包同样以硬链接去重,但仅限单用户内,且不含 pip 包。)

| | conda / mamba | muv (uv) |
|------|---------------|----------|
| 共享粒度 | 整个环境 | 底层文件(wheel / `.so`) |
| 各用户独立环境 | ❌ 共用一个 env | ✅ 各自独立 venv |
| 安装时所需写权 | 共享 env 的写权 | 仅自己的 venv |
| **pip / wheel 包去重** | ❌ 完整复制 | ✅ 硬链接共享 |
| **跨用户去重** | ❌ 各存一份 | ✅ 全机共享缓存 |

> 硬链接要求缓存与用户 home 在同一文件系统分区,跨分区会自动退化为复制(安装时会提示)。

**一次下载,全机复用。** 缓存全机共用,同一包仅需下载一次,之后所有用户、所有 venv 均直接命中本地缓存,节省带宽。配合 `muv install --index auto` 自动测速选择最快的国内镜像,首次下载同样快速。

**Python 集中托管,uv 自身受保护。** 管理员通过 `muv python add` 将解释器统一安装到共享目录,普通用户(`UV_PYTHON_DOWNLOADS=never`)仅使用预置版本,避免每个用户各自安装、版本分散;能力边界由文件系统权限与 ACL 强制划分——普通用户可运行 uv、写入共享缓存,但无法修改 uv/muv 二进制与默认 Python,杜绝"共用环境却人人可改"的情况。

**轻量、无侵入。** 仅为单个 bash 脚本,无常驻进程,直接构建在 uv 之上;用户只需在 shell 配置中加入一行 `source env.sh`,其余照常使用 `uv` / `uv pip`,并继承 uv 自身的性能。

## 特性

- **共享存储** —— 缓存与 Python 安装目录全机共用,节省磁盘与带宽
- **权限分层** —— 管理员(`uvusers` 组)与普通用户权责分明,由文件系统权限强制
- **保护 uv** —— 普通用户无法修改 uv 二进制或默认 Python 版本
- **可配置前缀** —— 默认安装到 `/opt/uv`,可指定为任意目录
- **自动选源** —— 安装时通过 `cnpip` 测速,选择最快的国内镜像

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
sudo ./muv install                       # 安装到默认 /opt/uv,并测速选择镜像
sudo ./muv install --prefix /srv/uv      # 自定义安装前缀
sudo ./muv install --index <url>         # 指定镜像源,不执行镜像测速
sudo ./muv install --index auto         # 自动测速选择最快镜像
sudo ./muv install --python 3.11         # 指定默认 Python 版本(默认 3.12)
```

安装后 `muv` 会被部署为 `$PREFIX/bin/muv`;后续镜像、升级、Python 管理等操作均通过安装后的 `muv` 执行,避免回写源码目录。

安装流程:

1. 创建 `uvusers` 组。
2. 创建共享目录并设置权限/ACL。
3. 部署 `uv`/`uvx`/`pip`/`env.sh`/`muv`。若源码 `bin/` 中没有 `uv`/`uvx`,安装器会从 `astral.sh` 下载。
4. 写入 `$PREFIX/config.env`,保存管理员组、默认镜像源等机器配置。
5. 安装默认 Python 并执行自检。

## 快速开始

**管理员**将用户加入 `uvusers` 组(需 root,用户需重新登录生效):

```bash
muv grant alice bob
```

`muv grant` 会在需要时自动通过 `sudo` 重新执行。不要依赖 `sudo muv ...`;
`sudo` 的 `secure_path` 可能找不到 `$PREFIX/bin/muv`。如需显式 sudo,请使用完整路径,
例如 `sudo /opt/uv/bin/muv grant alice bob`。

**每个用户**在 `~/.bashrc` / `~/.zshrc` 中添加一行:

```bash
source /opt/uv/env.sh        # 若修改了前缀,替换为 $PREFIX/env.sh
```

之后即可直接使用共享 `uv` 环境:

```bash
uv venv --python 3.12 && source .venv/bin/activate
uv pip install requests       # 命中共享缓存
```

## 命令参考

| 命令 | 作用 | 权限 |
|------|------|------|
| `muv install [--prefix d] [--group g] [--index url\|auto] [--python X.Y]` | 安装/修复共享环境;`--python` 默认 `3.12` | root |
| `muv grant <user>...` | 将用户加入 `uvusers` 组 | root |
| `muv revoke <user>...` | 将用户移出 `uvusers` 组 | root |
| `muv mirror [<url>]` | 替换镜像源并锁定缓存 index;省略 url 时通过 cnpip 测速自动选择最快 | root |
| `muv update` | 从官网下载最新 uv 并替换共享二进制 | root |
| `muv python add <ver>` | 安装共享 Python | uvusers 成员 |
| `muv python rm [--yes] <ver>` | 删除共享 Python(默认从终端确认;脚本化需显式 `--yes`) | uvusers 成员 |
| `muv python list` | 列出已安装的共享 Python | 任何人 |
| `muv doctor` | 自检:组 / 权限 / ACL / 二进制 / 当前源 / index 锁 | 任何人 |
| `muv help` | 显示帮助 | 任何人 |
| `muv --version` | 显示 muv 版本 | 任何人 |

## 工作原理

### 目录结构

```
$PREFIX/                   # 默认 /opt/uv
├── env.sh                 # 用户 source 的环境脚本模板(664 root:uvusers)
├── config.env             # 机器相关运行配置(664 root:uvusers)
├── bin/                   # 2775 root:uvusers — uv/uvx/pip/muv + Python symlink
├── cache/                 # 3777 root:uvusers — 共享缓存(所有用户可写,sticky 位防互删)
├── python/                # 2775 root:uvusers — 共享 Python(仅管理员可安装/删除)
├── python-cache/          # 2775 root:uvusers — Python 下载缓存(仅管理员可写)
└── tools/                 # 2775 root:uvusers — 共享工具(仅管理员可写)
```

### 权限模型

- **Python 集中管理** —— `python/`、`python-cache/` 为 `2775 root:uvusers`,只有管理员可安装/删除 Python;普通用户 `env.sh` 中 `UV_PYTHON_DOWNLOADS=never`,仅能使用预置版本,需要新版本时由管理员执行 `muv python add`,从而避免版本分散在各用户主目录中。`cache/` 则对所有用户可写,共享可重建的缓存。
- **default ACL + sticky cache** —— 共享目录使用目录级 default ACL,保证新建文件对组(及 `cache` 的 others)可写,`env.sh` 不修改用户 umask。`cache/` 使用 sticky bit,普通用户不能删除其他用户拥有的缓存目录项。
- **保护 uv/muv** —— `bin/` 为 `2775 root:uvusers` 且 ACL `other::r-x`:非 uvusers 用户既无法修改 `bin/uv` / `bin/muv` 内容,也无法在 `bin/` 内替换它们,在文件系统层面强制"仅 uv 管理员可管理 uv"。`muv` 的成员校验仅用于提供更友好的报错,并非唯一防线。
- **hardlink** —— `UV_LINK_MODE=hardlink` 使多用户 venv 共享缓存数据块,要求缓存与用户 home 在同一文件系统分区,跨分区时自动退化为复制(安装时会提示)。
- **源锁定** —— uv 缓存按"源 URL"在 `cache/simple-v*/index/` 与 `wheels-v*/index/` 下分桶。配置审定源后,`muv install` / `muv mirror` 会把这两层 `index/` 目录 chown 为 `root` 并将 ACL `mask`/`other` 降为 `r-x`(default ACL 保持 `rwx`,新审定桶仍世界可写)。效果:**只有 root 能在 `index/` 下新建桶**,普通用户用 `uv pip install --default-index <其它源>` 切换源时因无法建桶而失败,从而无法向共享缓存写入新的源。审定桶本身保持可写,正常安装不受影响。换源由 root 执行,走"解锁 → 清空旧桶 → 用新源预热建桶 → 重新锁定";`uv` 升级可能令缓存版本目录跳号,故 `muv update` 会自动重新锁定。`muv doctor` 会报告 index 锁状态。

## 配置(env.sh / config.env)

| 变量 | 值 | 生效范围 |
|------|----|----------|
| `UV_ROOT` / `UV_GROUP` | 安装前缀 / 管理员组(可被环境覆盖) | — |
| `UV_CACHE_DIR` | `$UV_ROOT/cache` | 所有用户 |
| `UV_DEFAULT_INDEX` | 镜像源(由 `muv install` / `muv mirror` 写入 `config.env`;用户可预设环境变量改变自身解析源,但锁定后无法向共享缓存写入新源桶) | 所有用户 |
| `UV_PYTHON_INSTALL_DIR` / `UV_PYTHON_CACHE_DIR` | `$UV_ROOT/python` / `python-cache` | 所有用户 |
| `UV_MANAGED_PYTHON` | `true` | 所有用户 |
| `UV_PYTHON_DOWNLOADS` | `never`(普通用户)/ `manual`(管理员) | 分层 |
| `UV_LINK_MODE` | `hardlink` | 所有用户 |
| `PATH` | 追加 `$UV_ROOT/bin` | 所有用户 |
| `UV_PYTHON_BIN_DIR` / `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` | 共享 `bin` / `tools` | 仅管理员 |

## 角色与权限

常规使用无需 sudo。`muv install` / `muv grant` / `muv revoke` / `muv update` / `muv mirror` 需要 root;`muv python add` / `muv python rm` 需要 `uvusers` 成员身份;`muv python list` / `muv doctor` / `muv help` 任意用户均可执行。

| 操作 | 管理员 | 普通用户 |
|------|--------|----------|
| 运行 `uv`/`uvx`、向审定源缓存桶写入 | ✅ | ✅ |
| 使用已安装的 Python | ✅ | ✅ |
| 切换审定源 / 向共享缓存写入新源桶 | ❌(仅 root) | ❌ |
| 安装 Python 到共享目录 | ✅ | ❌ |
| 删除共享 Python | ✅ | ❌ |
| 创建 Python symlink 到 `$UV_ROOT/bin/` | ✅ | ❌ |
| 安装/卸载共享工具 | ✅ | ❌ |
| 修改 uv/uvx 二进制 | ✅ | ❌ |

## 运维

- **磁盘** —— 用户可持续向 `python/` 安装版本,缓存也会持续增长,且无自动清理。请定期查看 `df`,必要时由管理员 `source env.sh` 后执行 `uv cache prune`(清理陈旧条目)或在低峰期执行 `uv cache clean`(整体清空,可重新下载恢复)。换源仅留下少量索引元数据,不影响占主要空间的解包内容。
- **删除共享 Python 有风险** —— venv 通过 symlink(及 `pyvenv.cfg` 路径)指向共享解释器,删除共享解释器会使依赖该路径的 venv 无法运行。请使用 `muv python rm`,不要直接执行 `uv python uninstall`:删除前会显示风险提示并要求确认。误删后重新执行 `muv python add <ver>` 可恢复同一路径,无需重建 venv。`muv` 不扫描用户目录,也不提供 venv 反向索引。
- **组成员变更** —— 加入/移除 `uvusers` 组后需重新登录生效。
- **升级 uv** —— 执行 `muv update`,从官网获取最新版本并输出 old → new 版本号。

## 许可证

[MIT](LICENSE) © 2026 muv contributors
