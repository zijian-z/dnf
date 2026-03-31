# 神迹 Overlay 方案

本文档对应当前仓库的最终目标:

1. 继续复用清风 `qf1031` 的 Docker 化运行时
2. 神迹内容只通过 overlay 方式叠加，不直接侵入清风原始文件
3. 数据库以 VMDK 导出结果为准，不再以清风初始化 SQL 为准
4. 后续无论是清风仓库更新还是 VMDK 更新，都可以重复执行同一套脚本

## 设计结论

### 1. VMDK 是最终基线

- 运行时覆盖文件以神迹 VMDK 为准
- 数据库初始化 SQL 以 VMDK 全库 dump 为准
- 清风初始化 SQL 只作为对比输入，不作为最终导入基线

### 2. 数据库差异只看结构，不看数据

当前对比逻辑固定为:

- 忽略 `INSERT`
- 忽略 `REPLACE`
- 忽略 `LOCK TABLES`
- 忽略 `UNLOCK TABLES`
- 忽略 `CREATE TABLE` 中仅代表当前数据状态的 `AUTO_INCREMENT=<数字>`

当前对比逻辑会输出三类结果:

- 仅清风存在的库
- 仅 VMDK 存在的库
- 同名表的 `CREATE TABLE` 结构差异

对比结果固定输出到:

```text
deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/
├── schema_summary.txt
├── only_in_qf_databases.txt
├── only_in_vmdk_databases.txt
├── qf_only_tables.txt
├── vmdk_only_tables.txt
└── table_structure_diff.txt
```

### 3. `df_game_r` 默认替换

当前策略已经改为:

- `rootfs/home/template/init/df_game_r` 为默认覆盖文件
- 不再放在 `optional/`
- 后续构建 rootfs overlay 时会直接写入镜像覆盖层

### 4. 大目录以归档形式保留

为了减少 GitHub 上的噪音，当前仓库默认不保留以下目录的展开版本:

- `deploy/dnf/docker-compose/shenji_overlay/data`
- `gm/dist`

它们会被收敛为:

```text
deploy/dnf/docker-compose/shenji_overlay/rootfs/
deploy/dnf/docker-compose/shenji_overlay/payload/gm_dist.tgz
```

其中:

- DNF 发布输入只保留 `rootfs/`
- `dp` 会收敛为 `rootfs/home/template/init/dp.tgz`
- `deploy/.../data` 不再作为仓库内的发布输入，只是容器运行时的外部卷目录

### 5. compose 采用分层覆盖

当前本地启动不再要求直接维护一份完整的独立 compose。

实际推荐入口是:

```bash
deploy/dnf/docker-compose/shenji_overlay/compose.sh
```

它会组合:

1. `docker-compose.project.yaml`
2. 清风原始 `../basic/docker-compose.yaml`
3. `docker-compose.override.yaml`

这样可以把对清风 compose 的侵入降到最低。

## 目录说明

当前 overlay 目录的关键内容如下:

```text
deploy/dnf/docker-compose/shenji_overlay
├── compose.sh
├── docker-compose.project.yaml
├── docker-compose.override.yaml
├── data
│   ├── Script.pvf
│   ├── df_game_r
│   ├── libfd.so
│   ├── game/
│   ├── channel/
│   └── run/
├── payload
│   ├── dp_overlay.tgz
│   └── gm_dist.tgz
├── meta
│   ├── checksums.txt
│   ├── db_compare/
│   ├── db_overlay_summary.txt
│   ├── recommended-env.txt
│   └── source_scripts/
└── rootfs
    ├── home/template/init/
    └── opt/shenji-overlay-meta/
```

说明:

- `data/` 只保留需要人工审阅、部署时常用的少量覆盖文件
- `payload/*.tgz` 用来存放大目录
- `rootfs/` 是最终要打进主镜像的 rootfs overlay
- `meta/` 用来保留比对结果、来源信息和校验信息

## 一键流程

### 方式一: 一键更新

```bash
plugin/dp2/update_from_vmdk.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
```

它会顺序执行:

1. `sync_from_vmdk.sh`
2. `build_db_overlay.sh`
3. `package_shenji_overlay.sh`

适合后续重复更新。

### 方式二: 分步执行

#### 1. 从 VMDK 同步覆盖文件

```bash
plugin/dp2/sync_from_vmdk.sh /path/to/DNFServer.vmdk
```

这一步会:

- 直接生成 `rootfs/home/template/init/Script.pvf`
- 直接生成 `rootfs/home/template/init/df_game_r`
- 直接生成 `rootfs/home/template/init/dp.tgz`
- 直接生成 `rootfs/home/template/neople/game/*`
- 直接生成 `rootfs/home/template/neople/channel/*`
- 直接生成 `rootfs/home/template/init/run/start_game.sh` / `start_channel.sh`
- 提取网页 GM 目录
- 将 `gm/dist` 压缩为 `payload/gm_dist.tgz`

#### 2. 基于 VMDK dump 生成数据库 overlay

```bash
plugin/dp2/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
```

这一步会:

- 将 VMDK 全库 dump 拆成分库 SQL
- 将清风初始化 SQL 与 VMDK SQL 做结构对比
- 生成 `meta/db_compare/*`
- 将最终导入 SQL 改写为基于 VMDK 的 `init_sql.tgz`
- 组装 `rootfs/`

说明:

- `meta/db_compare/*`、`meta/db_overlay_summary.txt` 等分析报告默认只保留在本地，不再提交到 GitHub

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

## rootfs 覆盖内容

当前主镜像真正写入的是 `rootfs/`，不是旧的整目录快照。

`rootfs/` 中包含:

- 基于 VMDK 生成的 `home/template/init/init_sql.tgz`
- `df_game_r`
- `dp`
- `run`
- `game/channel_info`
- `channel/channel_amd64`
- `channel/channel_info`
- `libfd.so`
- 数据库对比报告和源脚本元数据

这意味着:

- 清风更新时，只要它的基础运行时兼容，这套 overlay 可以继续复用
- VMDK 更新时，只要重新生成 payload、DB overlay 和工件即可

## 外部卷覆盖规则

当前方案仍然保留了清风“外部 `data/` 目录优先”的思路，但不是所有文件都采用同一策略。

### 1. 缺失时播种，不覆盖已有卷文件

这一类当前包括:

- `./data/Script.pvf`
- `./data/dp/*`

行为:

- 如果卷里没有 `./data/Script.pvf`，镜像首启会从 overlay 播种一份
- 如果卷里已经有 `./data/Script.pvf`，镜像不会覆盖
- 如果 `./data/dp/` 为空，镜像首启会从 `home/template/init/dp.tgz` 解压播种
- 如果 `./data/dp/` 已经有内容，镜像不会覆盖

也就是说:

- `Script.pvf` 仍然完全支持手工放到外部卷后长期替换
- `dp` 现在也支持长期通过外部卷目录替换

### 2. 运行时优先读取外部卷

这一类当前包括:

- `./data/libfd.so`
- `./data/game/channel_info/*`
- `./data/channel/channel_info/*`
- `./data/channel/channel_amd64`

行为:

- 启动脚本会优先读取 `./data` 里的这些文件
- 如果外部卷中存在，就在启动时覆盖到容器运行目录
- 如果外部卷中不存在，再退回镜像内置版本

也就是说:

- 这几类文件依然适合通过外部卷热替换

### 3. 当前会被镜像 overlay 强制刷新

这一类当前包括:

- `./data/df_game_r`
- `./data/run/*.sh`

行为:

- 容器初始化时会把镜像中的版本直接刷新到 `./data`
- 因此如果你手工修改了卷里的同名文件，重启容器后会被镜像版本覆盖

这样做的原因是当前方案已经固定为“以 VMDK 为准”，先保证:

- `df_game_r`
- `dp2`
- `run` 语义

三者始终与 VMDK 基线一致。

如果后续要进一步贴近清风原始习惯，也可以再改成:

- 仅缺失时播种
- 或增加环境变量控制是否强制刷新

## IP 与启动脚本策略

当前 overlay 启动脚本已经按下面原则处理:

- 保留清风的 Docker 化启动方式
- 保留清风的动态 IP 配置能力
- 神迹写死 IP 的部分改为使用 `PUBLIC_IP` / `AUTO_PUBLIC_IP`
- 保留 `libglibc_compat.so` 的兼容行为
- 频道进程优先使用神迹 `channel_amd64`

固定环境约束如下:

```dotenv
SERVER_GROUP=3
SERVER_GROUP_DB=cain
DNF_DB_GAME_PASSWORD=uu5!^%jg
OPEN_CHANNEL=11
```

除非明确验证通过，否则不要随意改动。

## 关于 `Script.pvf`

- `Script.pvf` 仍按清风风格放在 `./data/Script.pvf`
- 仓库不再保留 `deploy/dnf/docker-compose/shenji_overlay/data/` 作为发布输入
- 运行时外部卷中的 `./data/Script.pvf` 优先于镜像内种子，替换时直接覆盖这个文件即可

## VMDK 关键 SO 分析

VMDK 中几个关键 `.so` 的职责已经做过一轮静态分析，结论是:

- `libhook.so`
  实际来自神迹 `libdp2pre.so`，是预加载引导器
- `libdp2.so`
  是 DP2 核心装载器
- `libdp2game.so`
  是面向 `df_game_r.lua` 的游戏插件桥接层
- `frida.so`
  是通用 Frida Gadget，并不是神迹自写业务补丁
- `libfd.so`
  才是直接改 `df_game_r` 行为的核心补丁模块

其中:

- 当前神迹实际优先挂的是 `libfd.so`
- `frida.so` 只作为回退
- `libfd.so` 还会在数据库中创建 `frida.charac_ex`

详细说明见:

- `doc/ShenjiSoAnalysis.md`

## 常用产物

后续排查时最常看的文件:

- `deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/schema_summary.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/table_structure_diff.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/db_overlay_summary.txt`
- `deploy/dnf/docker-compose/shenji_overlay/meta/checksums.txt`
- `.artifacts/shenji-overlay-summary.txt`
- `doc/ShenjiSoAnalysis.md`

其中 `meta/db_compare/*`、`meta/db_overlay_summary.txt` 属于本地产物，默认不会提交到 GitHub。

## 更新建议

### 清风更新后

```bash
git pull
plugin/dp2/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
plugin/dp2/package_shenji_overlay.sh
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

如果神迹 VMDK 内容没有变化，通常不需要重新挂载同步文件，只需要重建 DB overlay 和工件。

### VMDK 更新后

```bash
plugin/dp2/update_from_vmdk.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

这是推荐方式。
