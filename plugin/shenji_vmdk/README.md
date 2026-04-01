# 神迹新生 VMDK 与 Overlay 工具

狗哥神迹·新生 VMDK / overlay 工具。
本流程直接使用 VMDK 内的完整 `dp2/` 目录，不依赖 `plugin/dp2` 中的因果 DP 包。

## 版本信息

当前流程默认以 VMDK 内的 `dp2/` 目录为准。
如果源目录只有 `libdp2pre.so` 没有 `libhook.so`，打包时会额外补一份 `libhook.so` 以兼容当前 Docker 启动链路。

## 固定约束

当前神迹 overlay 方案默认依赖以下约束:

- Docker 镜像版本建议 `>= 2.1.9.fix1`
- `SERVER_GROUP=3`
- `SERVER_GROUP_DB=cain`
- `DNF_DB_GAME_PASSWORD=uu5!^%jg`
- `OPEN_CHANNEL=11`

除非明确验证通过，否则不要随意改。

## 本目录脚本的用途

### 1. `sync_from_vmdk.sh`

从神迹 VMDK 或已挂载根目录中提取运行时覆盖文件。

生成内容包括:

- `rootfs/home/template/init/Script.pvf`
- `rootfs/home/template/init/df_game_r`
- `rootfs/home/template/init/dp.tgz`
- `rootfs/home/template/init/run/*`
- `rootfs/home/template/neople/game/*`
- `rootfs/home/template/neople/channel/*`
- `payload/gm_dist.tgz`
- `meta/*`

注意:

- `df_game_r` 现在是默认覆盖文件，不再放在 `optional/`
- DNF 发布输入只保留 `rootfs/`
- `gm/dist` 默认会被压成 `payload/gm_dist.tgz`

### 2. `build_db_overlay.sh`

基于 VMDK 全库 dump 生成数据库 overlay 和结构对比报告。

它会:

- 拆分 VMDK 全库 SQL
- 对比清风初始化 SQL 与 VMDK SQL
- 忽略 `INSERT` 数据差异
- 保留表结构差异
- 生成新的 `rootfs/home/template/init/init_sql.tgz`
- 输出 `meta/db_compare/*`

说明:

- `meta/db_compare/*`、`meta/db_overlay_summary.txt` 这类分析报告默认只保留在本地，不再提交到 GitHub

核心输出:

- `meta/db_compare/schema_summary.txt`
- `meta/db_compare/table_structure_diff.txt`
- `rootfs/`

### 3. `package_shenji_overlay.sh`

将当前 overlay 目录打包为主镜像与 GM 镜像的构建工件。

默认输出:

- `.artifacts/shenji-overlay-dnf.tar.gz`
- `.artifacts/shenji-overlay-gm.tar.gz`
- `.artifacts/shenji-overlay-summary.txt`

### 4. `update_from_vmdk.sh`

一键执行完整流程:

1. 同步 VMDK 文件
2. 用 Docker 导出 VMDK 内 MySQL SQL
3. 生成数据库 overlay 和结构对比报告
4. 打包构建工件

## 推荐流程

### 一键执行

```bash
plugin/shenji_vmdk/update_from_vmdk.sh /path/to/DNFServer.vmdk
```

### 分步执行

```bash
plugin/shenji_vmdk/sync_from_vmdk.sh /path/to/DNFServer.vmdk
plugin/shenji_vmdk/export_vmdk_sql.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
plugin/shenji_vmdk/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
plugin/shenji_vmdk/package_shenji_overlay.sh
```

之后进入:

```bash
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

## 如何从 VMDK 备份数据库

推荐直接执行:

```bash
plugin/shenji_vmdk/export_vmdk_sql.sh /path/to/DNFServer.vmdk
```

如果要指定输出路径:

```bash
plugin/shenji_vmdk/export_vmdk_sql.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
```

这个脚本会按下面的方式工作:

- 自动挂载 VMDK，或直接使用你传入的已挂载根目录
- 检查 VMDK 内是否存在 `/opt/lampp` 的 MySQL 可执行文件与数据目录
- 把 `opt/lampp/var/mysql` 复制到临时工作目录，避免直接在原始数据目录上操作
- 启动一个临时 Docker 容器，使用 VMDK 自带的 `mysqld` / `mysqldump` 做逻辑导出
- 如果 MySQL 无法正常拉起，会自动尝试 `innodb_force_recovery=0..6`
- 只导出 DNF 相关库: `d_*`、`taiwan_*`、`tw`、`frida`
- 输出 `.sql` 或 `.sql.gz`，导出完成后自动清理容器、临时目录和挂载点

默认输出路径是仓库工作区上一级目录下的:

```text
tmp/db_dumps/vmdk_latest_all.sql.gz
```

后续把这个 dump 直接交给:

```bash
plugin/shenji_vmdk/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
```

关于原始 `run` / `run_nopvp` / `stop` 快照:

- `sync_from_vmdk.sh` 每次都会直接从 VMDK 的 `root/` 目录重新复制这三份脚本
- 快照先写到 `overlay_dir/meta/source_scripts/`
- 仓库里长期保留的只有这份 `meta/source_scripts/` 快照
- `package_shenji_overlay.sh` 打包 DNF 工件时，才会把它们放进最终 rootfs 的 `opt/shenji-overlay-meta/source_scripts/`
- 所以一键执行 `update_from_vmdk.sh` 时，如果 VMDK 更新了，这三份脚本也会跟着刷新

## 关于数据库对比

当前数据库策略已经固定:

- 最终导入内容以 VMDK dump 为准
- 清风初始化 SQL 只用来做差异对比
- `INSERT` 数据差异忽略
- 表结构差异必须保留

当前对比报告输出在:

```text
deploy/dnf/docker-compose/shenji_overlay/meta/db_compare/
```

## 关于 GitHub 仓库里的大目录

为了避免 overlay 文件过多、难以审阅，当前策略是:

- DNF 发布输入只保留 `rootfs/`
- 仓库内不再保留 `deploy/dnf/docker-compose/shenji_overlay/data/`
- `dp` 收敛为 `rootfs/home/template/init/dp.tgz`
- `gm/dist` 收敛为 `payload/gm_dist.tgz`

## 运行时覆盖优先级

- `./data/Script.pvf` 存在时，优先使用外部卷文件
- `./data/dp/` 非空时，优先使用外部卷目录
- 只有 `./data/dp/` 为空时，才会从镜像内的 `home/template/init/dp.tgz` 解压播种
- 这意味着后续若要替换 dp，直接覆盖 `./data/dp/` 即可；若要重新使用镜像内种子，清空 `./data/dp/` 再重启

## 文档

主说明见:

- `deploy/dnf/docker-compose/shenji_overlay/README.md`

它已经合并了:

- overlay 核心流程
- Release 部署说明
- 运行时覆盖规则
- 关键 `.so` 的职责摘要

## 因果 DP 包

`plugin/dp2` 仍然保留为神迹因果的独立插件目录，但它不参与本目录的 VMDK 同步流程。
如果你只是单独使用神迹因果 DP 包，请直接查看 `plugin/dp2/README.md`。

如果你的目标是“把神迹新生 VMDK 适配到清风 Docker 化方案”，请优先使用上面的 overlay 脚本流程，而不是把 VMDK 工具继续放进 `plugin/dp2`。
