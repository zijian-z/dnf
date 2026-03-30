# GitHub Release 部署说明

本文档对应已经通过 GitHub Actions 发布好的神迹 overlay 镜像。

## 镜像说明

当前发布流程会产出三类镜像:

1. `dnf:debian13-qf1031-<version>`
2. `dnf-shenji-overlay:<version>`
3. `dnf-shenji-godofgm:<version>`

实际部署时真正需要运行的是:

1. `dnf-shenji-overlay:<version>`
2. `dnf-shenji-godofgm:<version>`

其中:

- `dnf:debian13-qf1031-*` 只是构建基底
- `dnf-shenji-overlay:*` 已经包含 VMDK 基线生成的 rootfs overlay
- `dnf-shenji-godofgm:*` 是网页 GM sidecar

## 这套发布版实际包含什么

主镜像中已经固化了以下内容:

- 神迹 `df_game_r`
- 神迹 `libfd.so`
- 神迹 `channel_amd64`
- 双份 `channel_info`
- 神迹覆盖版 `start_game.sh` / `start_channel.sh`
- `dp` 覆盖内容
- 基于 VMDK dump 生成的数据库初始化 SQL
- 数据库结构对比报告

也就是说:

- 清风初始化 SQL 不再是最终导入基线
- 发布版主镜像已经使用 VMDK 生成的初始化 SQL
- `df_game_r` 也已经按默认替换策略固化进去

## Release 附件说明

GitHub Release 通常还会带三个附件:

1. `shenji-overlay-dnf.tar.gz`
2. `shenji-overlay-gm.tar.gz`
3. `shenji-overlay-summary.txt`

其中最重要的是:

- `shenji-overlay-summary.txt`

重点看三项:

```text
included_vmdk_db_overlay=<yes|no>
included_script_pvf=<yes|no>
included_gm_data_db=<yes|no>
```

含义:

- `included_vmdk_db_overlay=yes`
  主镜像已经内置 VMDK 生成的数据库 overlay
- `included_script_pvf=yes`
  镜像内带默认 `Script.pvf` 种子
- `included_gm_data_db=yes`
  GM 镜像内带默认 `data.db` 种子

推荐看到的结果是:

```text
included_vmdk_db_overlay=yes
included_script_pvf=yes
included_gm_data_db=yes
```

## 部署目录准备

```bash
mkdir -p /srv/dnf-shenji
cd /srv/dnf-shenji
mkdir -p data data/godofgm mysql log log/godofgm
```

从仓库复制下面两个文件到当前目录:

- `deploy/dnf/docker-compose/shenji_overlay/docker-compose.release.yaml`
- `deploy/dnf/docker-compose/shenji_overlay/.env.release.example`

改名:

```bash
cp docker-compose.release.yaml docker-compose.yaml
cp .env.release.example .env.release
```

## 填写 `.env.release`

至少改这些:

```dotenv
DNF_IMAGE=ghcr.io/<owner>/dnf-shenji-overlay:<tag>
GM_IMAGE=ghcr.io/<owner>/dnf-shenji-godofgm:<tag>
DNF_DB_ROOT_PASSWORD=改成你自己的密码
GATE_AES_KEY=替换成64位十六进制密钥
PUBLIC_IP=你的公网IP或局域网IP
AUTO_PUBLIC_IP=false
```

固定约束保持不变:

```dotenv
SERVER_GROUP=3
SERVER_GROUP_DB=cain
DNF_DB_GAME_PASSWORD=uu5!^%jg
OPEN_CHANNEL=11
```

生成密钥示例:

```bash
openssl rand -hex 32
```

## `Script.pvf` 和 `data.db`

### 1. `Script.pvf`

如果 `shenji-overlay-summary.txt` 中:

- `included_script_pvf=yes`
  可以直接启动，缺失时会自动播种到 `./data/Script.pvf`
- `included_script_pvf=no`
  需要手工准备 `./data/Script.pvf`

手工放置示例:

```bash
cp /绝对路径/Script.pvf ./data/Script.pvf
```

### 2. `data/godofgm/data.db`

如果 `shenji-overlay-summary.txt` 中:

- `included_gm_data_db=yes`
  可以直接启动，缺失时会自动播种到 `./data/godofgm/data.db`
- `included_gm_data_db=no`
  需要手工准备 `./data/godofgm/data.db`

手工放置示例:

```bash
cp /绝对路径/data.db ./data/godofgm/data.db
```

## 启动

如果 GHCR 是私有仓库，先登录:

```bash
echo '<ghcr_token>' | docker login ghcr.io -u <github_user> --password-stdin
```

启动:

```bash
docker compose --env-file .env.release up -d
```

查看状态:

```bash
docker compose --env-file .env.release ps
```

查看日志:

```bash
docker compose --env-file .env.release logs -f dnf-1
docker compose --env-file .env.release logs -f godofgm
```

## 启动后确认

### 1. 主服务

可先检查:

```bash
find ./log -name "Log$(date +%Y%m%d).init" | head
```

如果日志中已经出现类似下面内容，通常说明核心服务已启动:

```text
Connect To Guild Server ...
Connect To Monitor Server ...
```

Supervisor 地址:

```text
http://<PUBLIC_IP>:2000
```

### 2. 网页 GM

访问:

```text
http://<PUBLIC_IP>:8088
```

如果打不开，优先检查:

1. `godofgm` 容器是否启动
2. `./data/godofgm/data.db` 是否存在
3. `godofgm` 日志是否有 sqlite 或权限错误
4. `GM_IMAGE` 是否填对

## 常见问题

### 1. 为什么我看到三个镜像，但只运行两个

因为 `dnf:debian13-qf1031-*` 是构建基底，不是最终运行镜像。

### 2. 为什么发布版不需要再理会清风初始化 SQL

因为当前发布版主镜像已经带了基于 VMDK dump 生成的初始化 SQL。
清风初始化 SQL 只在构建阶段参与对比，不再作为最终导入内容。

### 3. 为什么 `df_game_r` 现在是默认替换

因为当前 overlay 方案的最终策略就是以 VMDK 为准，`df_game_r` 已经被纳入默认 rootfs overlay，不再放到可选目录。

### 4. 如果后续 VMDK 再更新怎么办

本地重新执行:

```bash
plugin/dp2/update_from_vmdk.sh /path/to/DNFServer.vmdk /path/to/vmdk_latest_all.sql.gz
```

重新产物后再走发布流程即可。
