# GitHub 发布版部署文档

本文档面向以下场景:

- 你已经通过 GitHub Actions 成功发布镜像
- 你看到 GitHub 上有三类镜像，想知道实际部署该用哪几个
- 你希望直接使用 GHCR 镜像部署，不再本地 `docker build`

## 一、先看清楚这三个镜像分别是什么

工作流会发布三类镜像到 `ghcr.io/<owner>/`:

1. `dnf:debian13-qf1031-<version>`
2. `dnf-shenji-overlay:<version>`
3. `dnf-shenji-godofgm:<version>`

它们的用途分别是:

1. `dnf:debian13-qf1031-<version>`
   这是清风 `qf1031` 的基础镜像。
   它主要用于构建 `dnf-shenji-overlay`，正常部署时通常**不需要直接运行**。

2. `dnf-shenji-overlay:<version>`
   这是主服务镜像。
   里面已经包含了神迹覆盖层的运行时文件，部署时**必须使用**。

3. `dnf-shenji-godofgm:<version>`
   这是网页 GM sidecar 镜像。
   如果你需要神迹新生自带的网页 GM，就**同时运行**它。

结论:

- 日常部署真正要跑的是 2 和 3
- 1 号镜像是构建基底，不是主要运行目标

## 二、这套发布版到底替换了清风的哪些部分

这套部署方式仍然以清风 `qf1031` 为基础，**不是整机迁移**，也不是把神迹 VMDK 全量塞进容器。

发布版实际替换/覆盖的是这些运行时部分:

1. `./data/Script.pvf`
   用神迹 `Script.pvf` 替换清风默认 PVF

2. `./data/libfd.so`
   新增神迹 `libfd.so`，用于游戏进程的 preload 语义

3. `./data/game/channel_info/*`
   替换清风默认的游戏侧频道信息

4. `./data/channel/channel_amd64`
   用神迹的 `channel_amd64` 作为优先频道进程

5. `./data/channel/channel_info/*`
   替换清风默认的频道侧频道信息

6. `./data/dp/df_game_r.lua`
   替换清风原有 DP Lua 逻辑

7. `./data/dp/df_game_r.js`
   替换清风原有 DP JS 逻辑

8. `./data/dp/libhook.so`
   用神迹 `libdp2pre.so` 落到清风约定的 `libhook.so` 路径

9. `./data/run/start_game.sh`
   替换清风默认游戏启动脚本，注入神迹的 `libfd.so` 运行语义

10. `./data/run/start_channel.sh`
    替换清风默认频道启动脚本，优先拉起神迹 `channel_amd64`

11. `./data/godofgm/data.db`
    这是神迹网页 GM sidecar 的本地 SQLite 状态库，属于新增 sidecar 数据，不是清风主服务原生内容

明确**不替换**的部分:

1. 数据库初始化流程
   继续走清风原有初始化逻辑
   这一点已经拿 VMDK 实际数据库目录、GM 配置和游戏启动日志做过比对，当前神迹新生 overlay 不需要额外改一套 MySQL 初始化流程

2. 主容器运行时、Supervisor、compose 启动方式
   保留清风原有方式

3. `bridge` 等公共进程二进制
   默认继续使用清风版本

4. `df_game_r` 二进制
   默认仍保留清风版本，不直接替换成神迹版

5. 登录器网关和基础优化
   继续保留清风镜像原有实现

数据库比对的关键结论是:

- VMDK 里的网页 GM `root/dist/data/data.db` 与仓库内 `gm/dist/data/data.db` 当前是字节级一致
- VMDK 游戏服实际连接的是 `d_taiwan + taiwan_cain*` 这一组业务库
- 这与清风当前 `init_main_db.sh` / `init_server_group_db.sh` 会初始化并写回 `db_connect` 的目标库集合一致
- VMDK 额外存在的 `frida` 库由神迹 DP 运行时自动创建，不要求在初始化阶段预置

## 三、再看 GitHub Release 里的三个附件是什么

如果你是通过 tag 触发的发布，GitHub Release 里还会看到三个附件:

1. `shenji-overlay-dnf.tar.gz`
2. `shenji-overlay-gm.tar.gz`
3. `shenji-overlay-summary.txt`

这三个不是直接拿来 `docker run` 的镜像 tar 包，它们的作用是:

- `shenji-overlay-dnf.tar.gz`
  神迹主服务覆盖层构建工件
- `shenji-overlay-gm.tar.gz`
  网页 GM 构建工件
- `shenji-overlay-summary.txt`
  本次发布有没有把 `Script.pvf` 和 `gm/dist/data/data.db` 一起打进去的说明文件

正常部署 GHCR 镜像时:

- 主要看 `shenji-overlay-summary.txt`
- 一般不需要手动使用这两个 `.tar.gz`

## 四、先确认这次发布带没带默认种子文件

每次 GitHub 打包完成后，都先看 `shenji-overlay-summary.txt`，重点看这两项:

```text
included_script_pvf=<yes|no>
included_gm_data_db=<yes|no>
```

含义如下:

1. `included_script_pvf=yes`
   主服务镜像内已经带了默认 `Script.pvf` 种子文件。
   如果外部 `./data/Script.pvf` 不存在，首启会自动初始化进去。

2. `included_script_pvf=no`
   主服务镜像里没有 `Script.pvf`。
   这种情况下你必须手工准备 `./data/Script.pvf`。

3. `included_gm_data_db=yes`
   GM 镜像内已经带了默认 `data.db` 种子文件。
   如果外部 `./data/godofgm/data.db` 不存在，首启会自动初始化进去。

4. `included_gm_data_db=no`
   GM 镜像里没有 `data.db`。
   这种情况下你必须手工准备 `./data/godofgm/data.db`，否则建议先不要启动 `godofgm`。

推荐目标是:

- `included_script_pvf=yes`
- `included_gm_data_db=yes`

其中 `data.db` 的期望行为是:

- 镜像内自带一份默认种子
- 首次部署自动初始化到外部 `./data/godofgm/data.db`
- 之后所有通过网页 GM 产生的状态变化，都实时保存在外部 `./data/godofgm/data.db`
- 镜像升级不会覆盖你已经存在的外部数据库文件

## 五、部署目录准备

在服务器上准备一个单独目录，例如:

```bash
mkdir -p /srv/dnf-shenji
cd /srv/dnf-shenji
mkdir -p data data/godofgm mysql log log/godofgm
```

然后从仓库复制下面两个文件到当前目录:

- `deploy/dnf/docker-compose/shenji_overlay/docker-compose.release.yaml`
- `deploy/dnf/docker-compose/shenji_overlay/.env.release.example`

复制后改名:

```bash
cp docker-compose.release.yaml docker-compose.yaml
cp .env.release.example .env.release
```

## 六、填写 `.env.release`

至少改下面几项:

```dotenv
DNF_IMAGE=ghcr.io/<owner>/dnf-shenji-overlay:<tag>
GM_IMAGE=ghcr.io/<owner>/dnf-shenji-godofgm:<tag>
DNF_DB_ROOT_PASSWORD=改成你自己的密码
GATE_AES_KEY=替换成64位十六进制AES密钥
PUBLIC_IP=你的公网IP或局域网IP
AUTO_PUBLIC_IP=false
```

说明:

- `<owner>` 替换为你的 GitHub 用户名或组织名
- `<tag>` 替换为你这次发布出来的 tag，例如 `v1.0.0`、`release-20260329`
- 如果镜像是公开的，不需要 `docker login ghcr.io`
- 如果镜像是私有的，需要先登录 GHCR

生成 AES 密钥示例:

```bash
openssl rand -hex 32
```

注意:

- `DNF_DB_GAME_PASSWORD` 对神迹覆盖层必须保持 `uu5!^%jg`
- `SERVER_GROUP=3`
- `SERVER_GROUP_DB=cain`
- `OPEN_CHANNEL=11`

这几项不要随意改，除非你明确知道自己在改什么

另一个关键点:

- 这套发布版现在按清风的外部 `data` 目录思路工作
- 镜像内置的神迹覆盖层文件只会在目标文件**不存在**时初始化到 `./data`
- 如果你已经手工放了自己的 `Script.pvf`、`df_game_r`、`data/godofgm/data.db` 或其他覆盖文件，重启容器时不会被镜像重新覆盖

## 七、准备 `Script.pvf`

如果 `shenji-overlay-summary.txt` 里是 `included_script_pvf=yes`:

- 可以直接启动
- 首次启动时，镜像会在 `./data/Script.pvf` 缺失时自动初始化默认 `Script.pvf`

如果 `shenji-overlay-summary.txt` 里是 `included_script_pvf=no`，则必须手工把 `Script.pvf` 放进清风风格的持久化目录:

```bash
cp /绝对路径/Script.pvf ./data/Script.pvf
```

无论是哪种情况，后续如果你想替换 PVF，都直接改 `./data/Script.pvf`，然后重启容器即可。

## 八、准备 `data/godofgm/data.db`

如果 `shenji-overlay-summary.txt` 里是 `included_gm_data_db=yes`:

- 可以直接启动
- 首次启动时，镜像会在 `./data/godofgm/data.db` 缺失时自动初始化默认数据库

这是推荐的发布方式，因为它最符合清风风格:

- 镜像自带默认种子
- 真实运行状态落在外部 `./data` 目录
- 后续所有网页 GM 产生的修改都写回外部 `./data/godofgm/data.db`

如果 `shenji-overlay-summary.txt` 里是 `included_gm_data_db=no`，则需要把现成的 `data.db` 放到同一个外部 `data` 目录体系里:

```bash
cp /你的来源/data.db ./data/godofgm/data.db
```

`data.db` 的来源可以是:

- 之前可用部署里的 `gm/dist/data/data.db`
- 从神迹 VMDK 提取出的 `root/dist/data/data.db`
- 你本地保存的 `shenji-dist/data/data.db`

如果你暂时没有 `data.db`:

- 建议先只启动 `dnf-1`
- 把 `docker-compose.yaml` 里的 `godofgm` 服务先注释掉
- 等拿到 `data.db` 后再启用 GM

如果你希望后续 GitHub 发布版默认自带 `data.db`，还要确认仓库内的以下文件已经被提交:

- `deploy/dnf/docker-compose/shenji_overlay/gm/dist/data/data.db`

否则 GitHub Actions checkout 到的源码里仍然拿不到它，发布摘要就会继续显示 `included_gm_data_db=no`。

## 九、拉取并启动

如果 GHCR 是私有仓库，先登录:

```bash
echo '<ghcr_token>' | docker login ghcr.io -u <github_user> --password-stdin
```

然后启动:

```bash
docker compose --env-file .env.release up -d
```

查看容器:

```bash
docker compose --env-file .env.release ps
```

查看日志:

```bash
docker compose --env-file .env.release logs -f dnf-1
docker compose --env-file .env.release logs -f godofgm
```

## 十、启动后如何确认成功

### 1. 主服务

检查日志目录:

```bash
ls -la ./log
```

检查当天初始化日志:

```bash
find ./log -name "Log$(date +%Y%m%d).init" | head
```

如果看到类似下面内容，通常说明服务端核心进程已拉起:

```text
Connect To Guild Server ...
Connect To Monitor Server ...
```

也可以访问 Supervisor:

```text
http://<PUBLIC_IP>:2000
```

账号密码对应 `.env.release` 里的:

- `WEB_USER`
- `WEB_PASS`

### 2. 网页 GM

网页 GM 通过主服务端口映射到:

```text
http://<PUBLIC_IP>:8088
```

如果网页打不开，优先检查:

1. `godofgm` 容器是否正常运行
2. `included_gm_data_db=yes` 时，确认首启后已经自动生成 `./data/godofgm/data.db`
3. `included_gm_data_db=no` 时，确认你已经手工准备了 `./data/godofgm/data.db`
4. 容器日志里是否报 sqlite 或权限错误

## 十一、常见问题

### 1. 为什么我只需要两个镜像，却看到了三个？

因为 `dnf:debian13-qf1031-*` 是构建基底。
真正运行的是:

- `dnf-shenji-overlay`
- `dnf-shenji-godofgm`

### 2. 为什么主服务起来了，但进游戏失败？

优先检查:

1. `./data/Script.pvf` 是否已经放好
2. `.env.release` 里的 `PUBLIC_IP` 是否填对
3. `GATE_AES_KEY` 是否和登录器保持一致
4. 相关端口是否已放行

### 3. 为什么网页 GM 起不来？

优先检查:

1. 先确认本次发布的 `shenji-overlay-summary.txt` 里 `included_gm_data_db` 是 `yes` 还是 `no`
2. 如果是 `yes`，先启动一次容器，再检查 `./data/godofgm/data.db` 是否已自动生成
3. 如果是 `no`，则必须先手工准备 `./data/godofgm/data.db`
4. `godofgm` 日志是否报 sqlite 或配置错误
5. `GM_IMAGE` 是否填对

### 4. 我能不能直接运行基础镜像 `dnf:debian13-qf1031-*`？

可以，但那只是清风基础镜像。
如果你的目标是运行“神迹新生 VMDK 迁移到清风 Docker”的版本，应该使用:

- `dnf-shenji-overlay`

## 十二、推荐部署顺序

建议按这个顺序做:

1. 先准备好 `.env.release`
2. 先把 `Script.pvf` 放到 `./data/Script.pvf`
3. 如果 `included_gm_data_db=no`，提前放好 `./data/godofgm/data.db`
4. 先启动 `dnf-1`
5. 确认游戏主服务正常
6. 再确认 `godofgm` 正常

如果 `included_gm_data_db=yes`，也可以直接把第 3 步省掉:

1. 先准备好 `.env.release` 和 `./data/Script.pvf`
2. 直接执行 `docker compose --env-file .env.release up -d`
3. 启动后检查 `./data/godofgm/data.db` 是否已自动生成
4. 再检查网页 GM 是否正常

如果你手头暂时没有 `data.db`，推荐顺序改为:

1. 先只启动 `dnf-1`
2. 验证服务端和登录器可用
3. 拿到 `data.db` 后再补启 `godofgm`
