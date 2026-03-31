# 神迹 Overlay README

这份 README 是当前神迹 overlay 的主入口文档。

目标很简单:

1. 继续复用清风 `qf1031` 的 Docker 化运行时
2. 神迹内容通过 overlay 叠加，不直接散改清风原始目录
3. DNF 发布输入只保留 `rootfs/`
4. 数据库初始化以 VMDK 全库 dump 为准

## 先看结论

当前目录里真正重要的东西只有三类:

- `rootfs/`
  DNF 主镜像唯一发布输入
- `payload/gm_dist.tgz`
  GodOfGM 发布输入
- `meta/`
  数据库对比报告、校验信息、来源信息

仓库里不再保留 `deploy/dnf/docker-compose/shenji_overlay/data/` 作为发布输入。
`./data` 现在只表示容器运行时外部卷目录。

## 核心流程

### 一键更新

```bash
plugin/dp2/update_from_vmdk.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
```

它会顺序执行:

1. `plugin/dp2/sync_from_vmdk.sh`
2. `plugin/dp2/build_db_overlay.sh`
3. `plugin/dp2/package_shenji_overlay.sh`

适合后续重复更新。

### 分步执行

#### 1. 从 VMDK 同步文件

```bash
plugin/dp2/sync_from_vmdk.sh /path/to/DNFServer.vmdk
```

这一步会直接生成:

- `rootfs/home/template/init/Script.pvf`
- `rootfs/home/template/init/df_game_r`
- `rootfs/home/template/init/dp.tgz`
- `rootfs/home/template/init/run/start_game.sh`
- `rootfs/home/template/init/run/start_channel.sh`
- `rootfs/home/template/neople/game/*`
- `rootfs/home/template/neople/channel/*`
- `rootfs/opt/shenji-overlay-meta/source_scripts/*`
- `payload/gm_dist.tgz`

#### 2. 基于 VMDK dump 生成数据库 overlay

```bash
plugin/dp2/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
```

这一步会:

- 拆分 VMDK 全库 SQL
- 对比清风初始化 SQL 与 VMDK SQL
- 输出 `meta/db_compare/*`
- 生成新的 `rootfs/home/template/init/init_sql.tgz`
- 刷新 `rootfs/`

#### 3. 打包构建工件

```bash
plugin/dp2/package_shenji_overlay.sh
```

默认输出:

```text
.artifacts/shenji-overlay-dnf.tar.gz
.artifacts/shenji-overlay-gm.tar.gz
.artifacts/shenji-overlay-summary.txt
```

#### 4. 本地 compose 启动

```bash
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

注意:

- `compose.sh` 依赖 `.artifacts/` 中的打包结果
- 所以本地启动前需要先执行 `package_shenji_overlay.sh`

## 目录说明

当前目录结构的核心部分如下:

```text
deploy/dnf/docker-compose/shenji_overlay
├── README.md
├── compose.sh
├── docker-compose.project.yaml
├── docker-compose.override.yaml
├── docker-compose.release.yaml
├── .env.example
├── meta
│   ├── checksums.txt
│   ├── db_compare/
│   ├── db_overlay_summary.txt
│   ├── recommended-env.txt
│   └── shenji_overlay.manifest
├── payload
│   └── gm_dist.tgz
└── rootfs
    ├── home/template/init/
    ├── home/template/neople/
    └── opt/shenji-overlay-meta/
```

其中:

- `rootfs/` 是 DNF 主镜像唯一发布输入
- `rootfs/home/template/init/dp.tgz` 是收敛后的 DP 包
- `rootfs/opt/shenji-overlay-meta/source_scripts/` 只保留神迹原始 `run` / `run_nopvp` / `stop` 作为参考留档
- `payload/gm_dist.tgz` 是 GodOfGM 打包输入
- `meta/` 是仓库侧的分析与校验输出

## 固定约束

当前神迹 overlay 默认依赖这些约束:

```dotenv
SERVER_GROUP=3
SERVER_GROUP_DB=cain
DNF_DB_GAME_PASSWORD=uu5!^%jg
OPEN_CHANNEL=11
```

除非明确验证通过，否则不要随意改。

## 数据库策略

当前数据库策略已经固定:

- 最终导入内容以 VMDK dump 为准
- 清风初始化 SQL 只作为结构对比输入
- `INSERT` 差异忽略
- 表结构差异必须保留

当前对比报告输出在:

```text
deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/
```

重点看这几个文件:

- `schema_summary.txt`
- `only_in_qf_databases.txt`
- `only_in_vmdk_databases.txt`
- `qf_only_tables.txt`
- `vmdk_only_tables.txt`
- `table_structure_diff.txt`

## 外部卷覆盖规则

当前方案仍然保留清风“外部 `./data` 目录优先”的思路，但不同文件的策略不完全一样。

### 1. 缺失时播种，不覆盖已有卷文件

这一类当前包括:

- `./data/Script.pvf`
- `./data/dp/*`

行为:

- 如果卷里没有 `./data/Script.pvf`，镜像首启会从 overlay 播种一份
- 如果卷里已经有 `./data/Script.pvf`，镜像不会覆盖
- 如果 `./data/dp/` 为空，镜像首启会从 `rootfs/home/template/init/dp.tgz` 解压播种
- 如果 `./data/dp/` 已经有内容，镜像不会覆盖

这意味着:

- `Script.pvf` 支持长期通过外部卷替换
- `dp` 也支持长期通过外部卷目录替换

### 2. 运行时优先读取外部卷

这一类当前包括:

- `./data/libfd.so`
- `./data/game/channel_info/*`
- `./data/channel/channel_info/*`
- `./data/channel/channel_amd64`

行为:

- 启动脚本优先读取 `./data` 里的这些文件
- 如果外部卷中存在，就在启动时覆盖到容器运行目录
- 如果外部卷中不存在，再退回镜像内置版本

### 3. 当前会被镜像 overlay 强制刷新

这一类当前包括:

- `./data/df_game_r`
- `./data/run/*.sh`

行为:

- 容器初始化时会把镜像中的版本直接刷新到 `./data`
- 因此如果你手工修改了卷里的同名文件，重启容器后会被镜像版本覆盖

## 本地开发与更新建议

### 清风更新后

如果神迹 VMDK 本身没有变化，通常不需要重新同步 VMDK 文件，只需要重建数据库 overlay 和工件:

```bash
git pull
plugin/dp2/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
plugin/dp2/package_shenji_overlay.sh
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

### VMDK 更新后

```bash
plugin/dp2/update_from_vmdk.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

## Release 部署

如果已经有 GitHub Release / GHCR 镜像，真正需要运行的是:

1. `dnf-shenji-overlay:<tag>`
2. `dnf-shenji-godofgm:<tag>`

`dnf:debian13-qf1031-*` 只是构建基底，不是最终运行镜像。

部署时最常用的文件是:

- `docker-compose.release.yaml`
- `.env.example`

典型部署目录:

```bash
mkdir -p /srv/dnf-shenji
cd /srv/dnf-shenji
mkdir -p data data/godofgm mysql log log/godofgm
```

然后复制:

- `deploy/dnf/docker-compose/shenji_overlay/docker-compose.release.yaml`
- `deploy/dnf/docker-compose/shenji_overlay/.env.example`

改名:

```bash
cp docker-compose.release.yaml docker-compose.yaml
cp .env.example .env
```

至少改这些环境变量:

```dotenv
DNF_IMAGE=ghcr.io/<owner>/dnf-shenji-overlay:<tag>
GM_IMAGE=ghcr.io/<owner>/dnf-shenji-godofgm:<tag>
DNF_DB_ROOT_PASSWORD=改成你自己的密码
GATE_AES_KEY=替换成64位十六进制密钥
PUBLIC_IP=你的公网IP或局域网IP
AUTO_PUBLIC_IP=false
GODOFGM_ADMIN_PASSWORD=改成强密码
```

如果 GHCR 是私有仓库，先登录:

```bash
echo '<ghcr_token>' | docker login ghcr.io -u <github_user> --password-stdin
```

启动:

```bash
docker compose up -d
```

查看状态:

```bash
docker compose ps
docker compose logs -f dnf-1
docker compose logs -f godofgm
```

## 关键模块说明

这部分把原先几份文档里的重点压成一个最短结论。

### `libhook.so`

- 实际来源是神迹 `libdp2pre.so`
- 它是 DP2 的预加载引导器
- 负责把 `/dp2/libdp2.so` 拉起来

### `libdp2.so`

- DP2 核心装载器
- 负责初始化 DP2 运行环境

### `libdp2game.so`

- 游戏侧插件桥接层
- 给 `df_game_r.lua` 暴露游戏接口

### `frida.so`

- 通用 Frida Gadget
- 不是神迹专属玩法补丁本体

### `libfd.so`

- 神迹最关键的业务补丁模块
- 会直接改写 `df_game_r` 进程行为
- 当前启动链路里它比 `frida.so` 更关键

## 常看产物

后续排查时最常看的文件:

- `deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/schema_summary.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/table_structure_diff.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/db_overlay_summary.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/checksums.txt`
- `.artifacts/shenji-overlay-summary.txt`
- `deploy/dnf/docker-compose/shenji_overlay/rootfs/opt/shenji-overlay-meta/source_scripts/run`
- `deploy/dnf/docker-compose/shenji_overlay/rootfs/opt/shenji-overlay-meta/source_scripts/stop`

其中:

- `meta/db_compare/*`、`meta/db_overlay_summary.txt` 属于本地产物，默认不会提交到 GitHub
- `rootfs/opt/shenji-overlay-meta/source_scripts/*` 只是神迹原始脚本留档，不参与当前运行链路
