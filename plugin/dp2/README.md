# 神迹 DP 与 Overlay 工具

狗哥神迹·因果专用 DP 插件。

## 版本信息

`dp2.9.0+frida_240418`

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
2. 生成数据库 overlay
3. 打包构建工件

## 推荐流程

### 一键执行

```bash
plugin/dp2/update_from_vmdk.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
```

### 分步执行

```bash
plugin/dp2/sync_from_vmdk.sh /path/to/DNFServer.vmdk
plugin/dp2/build_db_overlay.sh /path/to/vmdk_latest_all.sql.gz
plugin/dp2/package_shenji_overlay.sh
```

之后进入:

```bash
cd deploy/dnf/docker-compose/shenji_overlay
./compose.sh up -d --build
```

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

## 手工 DP 使用方式

如果你只是单独使用本目录原始 DP 包，可以继续按老方式解压 `dp2.tgz` 到清风的 `data/dp/` 目录。

但如果你的目标是“把神迹 VMDK 适配到清风 Docker 化方案”，请优先使用上面的 overlay 脚本流程，而不是手工散改目录。
