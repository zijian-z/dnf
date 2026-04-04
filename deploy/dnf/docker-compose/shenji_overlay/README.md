# 神迹 Overlay README

这份 README 是当前神迹 overlay 的主入口文档。

目标很简单:

1. 继续复用清风 `qf1031` 的 Docker 化运行时
2. 神迹内容通过 overlay 叠加，不直接散改清风原始目录
3. DNF 发布输入只保留 `rootfs/`
4. 数据库初始化以 VMDK 全库 dump 为准

## 先看结论

当前目录里真正需要长期维护的东西只有两类:

- `rootfs/`
  DNF 主镜像唯一发布输入
- `payload/gm_dist.tgz`
  GodOfGM 发布输入

仓库里不再保留 `deploy/dnf/docker-compose/shenji_overlay/data/` 作为发布输入。
`./data` 现在只表示容器运行时外部卷目录。
`meta/` 仅在执行数据库对比时作为本地分析输出临时生成，不再作为仓库常驻内容。

## 核心流程

### 一键更新

```bash
plugin/shenji_vmdk/update_from_vmdk.sh /path/to/DNFServer.vmdk
```

它会顺序执行:

1. `plugin/shenji_vmdk/sync_from_vmdk.sh`
2. `plugin/shenji_vmdk/export_vmdk_sql.sh`
3. `plugin/shenji_vmdk/build_db_overlay.sh`
4. `plugin/shenji_vmdk/package_shenji_overlay.sh`

适合后续重复更新。

### 分步执行

#### 1. 从 VMDK 同步文件

```bash
plugin/shenji_vmdk/sync_from_vmdk.sh /path/to/DNFServer.vmdk
```

这一步会直接生成:

- `rootfs/home/template/init/Script.pvf`
- `rootfs/home/template/init/df_game_r`
- `rootfs/home/template/init/dp.tgz`
- `rootfs/home/template/init/run/start_game.sh`
- `rootfs/home/template/init/run/start_channel.sh`
- `rootfs/home/template/neople/game/*`
- `rootfs/home/template/neople/channel/*`
- `payload/gm_dist.tgz`

#### 2. 从 VMDK 备份数据库

```bash
plugin/shenji_vmdk/export_vmdk_sql.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
```

这一步会:

- 自动挂载 VMDK，或直接使用你传入的已挂载根目录
- 检查 `opt/lampp/bin/mysql`、`mysqldump`、`mysqld` 与 `opt/lampp/var/mysql`
- 把 VMDK 里的 MySQL 数据目录复制到临时目录
- 在临时 Docker 容器中用 VMDK 自带的 LAMPP MySQL 做逻辑导出
- 自动尝试 `innodb_force_recovery=0..6`
- 导出 `d_*`、`taiwan_*`、`tw`、`frida`
- 生成 `.sql` 或 `.sql.gz` 文件

如果不传第二个参数，默认输出到:

```text
tmp/db_dumps/vmdk_latest_all.sql.gz
```

#### 3. 基于 VMDK dump 生成数据库 overlay

```bash
plugin/shenji_vmdk/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
```

这一步会:

- 拆分 VMDK 全库 SQL
- 对比清风初始化 SQL 与 VMDK SQL
- 输出 `meta/db_compare/*`
- 生成新的 `rootfs/home/template/init/init_sql.tgz`
- 刷新 `rootfs/`

#### 4. 打包构建工件

```bash
plugin/shenji_vmdk/package_shenji_overlay.sh
```

默认输出:

```text
.artifacts/shenji-overlay-dnf.tar.gz
.artifacts/shenji-overlay-gm.tar.gz
.artifacts/shenji-overlay-summary.txt
```

#### 5. 本地 compose 启动

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
├── payload
│   └── gm_dist.tgz
└── rootfs
    ├── home/template/init/
    └── home/template/neople/
```

其中:

- `rootfs/` 是 DNF 主镜像唯一发布输入
- `rootfs/home/template/init/dp.tgz` 是由 VMDK 内完整 `dp2/` 目录重打包得到的 DP 包
- `payload/gm_dist.tgz` 是 GodOfGM 打包输入
- `meta/db_compare/` 只在执行数据库对比时临时生成，用于本地分析
- 启动脚本现在只维护 `rootfs/home/template/init/run/*.sh` 这一套，不再额外保留 template 重复脚本

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
plugin/shenji_vmdk/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
plugin/shenji_vmdk/package_shenji_overlay.sh
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

### VMDK 更新后

```bash
plugin/shenji_vmdk/update_from_vmdk.sh /path/to/DNFServer.vmdk
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

## Release 部署

如果已经有 GitHub Release / GHCR 镜像，真正需要运行的是:

1. `dnf-shenji-overlay:<tag>`
2. `dnf-shenji-godofgm:<tag>`

`dnf:centos7-qf1031-*` 只是构建基底，不是最终运行镜像。

部署时最常用的文件是:

- [`docker-compose.release.yaml`](./docker-compose.release.yaml)
- [`.env.example`](./.env.example)

典型部署目录:

```bash
mkdir -p /srv/dnf-shenji
cd /srv/dnf-shenji
mkdir -p data data/godofgm mysql log log/godofgm
```

然后复制:

- [`deploy/dnf/docker-compose/shenji_overlay/docker-compose.release.yaml`](./docker-compose.release.yaml)
- [`deploy/dnf/docker-compose/shenji_overlay/.env.example`](./.env.example)

准备环境文件:

```bash
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
docker compose --env-file .env -f docker-compose.release.yaml up -d
```

查看状态:

```bash
docker compose --env-file .env -f docker-compose.release.yaml ps
docker compose --env-file .env -f docker-compose.release.yaml logs -f dnf-1
docker compose --env-file .env -f docker-compose.release.yaml logs -f godofgm
```

## 关键模块说明

这部分对应原先 `.so` 分析文档的收敛版，不做完整逆向，但保留当前迁移最需要的判断依据。

判断依据主要来自三类信息:

- 当前仓库里的启动脚本与 overlay 文件
- 神迹同步出的 `dp2` / `libfd.so` / `df_game_r.lua`
- 历史源码快照与静态分析结论

### 启动链总览

当前 overlay 模板和清风镜像里的游戏进程启动链路，不是“只挂一个 `frida.so`”这么简单，而是:

1. `LD_PRELOAD` 优先挂 `/dp2/libdp2pre.so`
2. 如果缺少 `libdp2pre.so`，再回退到 `/dp2/libhook.so`
3. `libdp2.so` 初始化 DP2 运行环境
4. `libdp2.xml` 把 `df_game_r`、`df_game_r.lua`、`libdp2game.so` 串起来
5. 游戏进程额外挂 `libfd.so`
6. 只有 `libfd.so` 缺失时，启动脚本才回退到 `frida.so`

这也是为什么当前 overlay 不只是保留一个 `frida.so`，而是保留整套 `dp.tgz + libfd.so + 启动脚本`。
这里描述的是当前仓库内 overlay / 清风镜像的加载方式，不等同于“原始 VMDK 自带 run 脚本已经被完整验证”。
当前仓库保留的神迹原始 `run` 快照里，游戏侧实际使用的是 `LD_PRELOAD="/dp2/libdp2pre.so:/home/neople/game/libfd.so"`。
当前 overlay 也默认贴近这条 CentOS7 启动语义，不再额外注入 Debian / Ubuntu 系列的 glibc 兼容层。

### `libhook.so`

- 当前 overlay 中如果 VMDK 的 `dp2/` 只有 `libdp2pre.so`，会补出同内容的 `libhook.so` 文件名
- 它是 DP2 的预加载引导器
- 负责把 `/dp2/libdp2.so` 拉起来
- 它不是主要玩法逻辑承载层

从历史静态分析看，它的关键点是:

- `SONAME` 仍然是 `libdp2pre.so`
- 字符串里能看到 `/dp2/libdp2.so`
- 会触发 `dp2_init`

### `libdp2.so`

- DP2 核心装载器
- 负责初始化 DP2 运行环境
- 会承接 `libhook.so` 拉起后的后续流程
- 历史静态分析里可以看到 `dp2_init`、`dp2_frida_resolver` 一类符号

### `libdp2game.so`

- 游戏侧插件桥接层
- 给 `df_game_r.lua` 暴露游戏接口
- 它不是完整玩法逻辑本体，更像 Lua 与游戏进程之间的桥

和它配套的还包括:

- `liblua53.so`
- `libuv.so`
- `luv.so`
- `luasql/mysql.so`
- `luasql/sqlite3.so`

这些更接近“DP2 执行环境”而不是单独业务补丁。

### `libdp2.xml`

`libdp2.xml` 的含义很关键，因为它把 DP2 的主链路写死了:

- 目标进程是 `df_game_r`
- 主脚本是 `/dp2/df_game_r.lua`
- 插件是 `/dp2/lib/libdp2game.so`
- 还会声明 Lua / uv 一类依赖

这说明:

- 玩法逻辑并不都写在 `.so` 里
- 很多规则其实落在 `df_game_r.lua`
- `.so` 更多承担“注入入口 + 运行时 + 桥接层”的职责

### `frida.so`

- 通用 Frida Gadget
- 不是神迹专属玩法补丁本体
- 更适合理解成通用动态插桩运行时

当前启动语义不是优先使用它，而是:

1. 先挂 `libhook.so`
2. 优先挂 `libfd.so`
3. `libfd.so` 缺失时再回退到 `frida.so`

README 前面的运行日志和当前 `start_game.sh` 也对应这条逻辑。

### `libfd.so`

- 神迹最关键的业务补丁模块
- 会直接改写 `df_game_r` 进程行为
- 当前启动链路里它比 `frida.so` 更关键

它和上面的 DP2 不是同一层。

根据历史源码快照，`libfd.so` 有几个关键特征:

- 使用 `constructor` / `destructor`，说明库加载和卸载时会自动执行逻辑
- 会直接调用 Frida Gum 一类能力改写进程行为，而不是只做普通函数调用
- 里面包含大量业务级 patch，而不是单纯启动一个通用 Gadget

这也是为什么它应被理解为“核心行为补丁”，而不是“可有可无的附加库”。

另外一个容易忽略的点是: `libfd.so` 还会主动接数据库。

根据历史源码快照，它会:

- 访问 `taiwan_cain`
- 访问 `d_guild`
- 创建 `frida` 数据库
- 创建 `frida.charac_ex` 一类扩展表

这解释了为什么迁移时即使清风初始化 SQL 里没有 `frida` 库，神迹实际运行后仍可能把它建出来。

### `df_game_r.lua`

虽然这里分析的是 `.so`，但 `df_game_r.lua` 不能分开看。

它能帮助判断真实职责划分:

- Lua 脚本里承载了大量玩法规则
- `.so` 更偏向负责注入、装载、运行时与桥接
- 所以迁移时不能只盯着几个 `.so`，还必须保留整套 `dp` 内容

### 对 overlay 方案的影响

基于上面的分析，当前 overlay 里的几个取舍是有依据的:

1. 必须保留 `libhook.so`
2. 必须保留 `libdp2.so + libdp2game.so + Lua 运行时`
3. 必须优先保留 `libfd.so`
4. `frida.so` 应视为回退项，不应误判为主逻辑本体
5. `dp.tgz` 必须和 `libfd.so` 一起看，不能拆成孤立文件处理

### 当前分析边界

这部分目前属于“静态分析 + 历史源码快照 + 当前启动脚本交叉验证”，还不是完整逆向。

但对于当前 overlay 设计、迁移判断、文件保留优先级和问题排查，已经够用。

## 常看产物

后续排查时最常看的文件:

- `deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/schema_summary.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/table_structure_diff.txt`
- `.artifacts/shenji-overlay-summary.txt`

其中:

- `meta/db_compare/*` 属于本地产物，默认不会提交到 GitHub
- 启动问题优先看 `rootfs/home/template/init/run/*.sh` 与容器内 `/data/run/*.sh`
