# 神迹玩法覆盖层

本文档描述的是一种**可重复执行**的迁移方式:

1. 运行时继续使用清风 `qf1031` 镜像
2. 神迹玩法只通过少量覆盖文件注入
3. 最新神迹新生自带的网页 GM 作为独立 sidecar 跟随同步
4. 主服务和网页 GM 都通过本地 Docker build 生成
5. 后续无论是清风镜像更新，还是 `VMDK` 更新，都只需要重新跑一遍同步脚本

## 设计原则

### 保留清风

以下内容默认继续使用清风镜像提供的版本:

- 容器运行时
- 登录器网关和基础优化
- `bridge` 等公共进程二进制
- 数据库初始化流程
- Supervisor / compose / Docker 启动方式

当前唯一明确需要从神迹覆盖的公共进程是:

- `channel_amd64`
- `channel_info/channel_info.etc`

### 仅同步神迹玩法相关文件

当前确认需要同步的内容:

- `home/neople/game/Script.pvf`
- `home/neople/game/libfd.so`
- `home/neople/game/channel_info/*`
- `home/neople/channel/channel_amd64`
- `home/neople/channel/channel_info/*`
- `dp2/df_game_r.lua`
- `dp2/df_game_r.js`
- `dp2/libdp2pre.so`，落到清风的 `data/dp/libhook.so`
- `root/dist`，作为网页 GM sidecar 的运行目录
- `root/run` / `root/run_nopvp` 的启动语义，用来修正清风侧的 `start_game.sh` 和 `start_channel.sh`

当前默认**不直接启用**的内容:

- `home/neople/game/df_game_r`

原因:

- 神迹与清风的 `libdp2.so`、`libdp2game.so` 实际相同
- 但最新神迹 `run` 脚本不是挂 `frida.so`，而是挂 `libfd.so`
- 最新神迹 `run` 脚本起的是 `channel_amd64`，不是清风默认的 `df_channel_r`
- 神迹双份 `channel_info.etc` 与清风默认值不同
- 当前优先保留清风的 `df_game_r` 二进制，只把神迹确认必要的 preload 语义抽出来

## 为什么不整机迁移

以下目录默认不整包搬进覆盖层:

- `/opt/lampp`

这个目录属于神迹原虚拟机的运行环境和旧数据库打包方式，不适合作为清风镜像的长期叠加层。

但有两个例外不能忽略:

- `/root/dist` 会被单独抽出来做网页 GM sidecar
- `/root/run*` 和 `/root/server` 不直接照搬，但它们的“启动语义”和 `libfd.so` 产物必须提取出来
- `home/neople/channel/channel_amd64` 和 `home/neople/*/channel_info` 必须保留

## 使用方式

### 1. 生成覆盖层

在仓库根目录执行:

```bash
chmod +x plugin/dp2/sync_from_vmdk.sh
plugin/dp2/sync_from_vmdk.sh /home/ubuntu/dnf/DNFServer.vmdk
```

默认输出到:

```text
deploy/dnf/docker-compose/shenji_overlay
```

脚本会生成:

```text
deploy/dnf/docker-compose/shenji_overlay
├── data
│   ├── Script.pvf
│   ├── channel
│   ├── game
│   ├── libfd.so
│   ├── dp
│   └── run
├── gm
│   └── dist
├── meta
│   ├── checksums.txt
│   ├── recommended-env.txt
│   ├── shenji_overlay.manifest
│   ├── source_scripts
│   └── source.txt
└── optional
    ├── df_game_r.shenji
    └── libfd_source
```

其中有一点需要单独处理:

- `data/Script.pvf` 就是清风风格的外部持久化文件
- 该文件已经被 `.gitignore` 忽略，不建议提交到 GitHub
- 本地 build 和 GitHub 发布版都统一按 `./data/Script.pvf` 管理

### 2. 启动清风容器

先准备清风风格的外部目录:

```bash
cd deploy/dnf/docker-compose/shenji_overlay
mkdir -p data data/godofgm mysql log log/godofgm
```

如果本次覆盖层目录内已经有 `data/Script.pvf`，可以直接使用。

如果你手头另有一份要替换的 PVF，则直接覆盖到:

```bash
cp /绝对路径/Script.pvf ./data/Script.pvf
```

```bash
cd deploy/dnf/docker-compose/shenji_overlay
sudo docker compose up -d --build
```

这个 compose 会同时启动:

- `dnf-1`: 清风主服务
- `godofgm`: 神迹新生网页 GM sidecar

其中:

- `dnf-1` 通过本地 `build/Debian13-DNF/Dockerfile` 构建
- `godofgm` 通过本地 `Dockerfile.godofgm` 构建
- `godofgm` 现已改成和发布版一致的外部持久化方式:
  - 镜像内自带默认 `data.db`
  - 首启缺失时自动播种到 `./data/godofgm/data.db`
  - 后续网页 GM 的修改始终落在外部 `./data/godofgm/data.db`

### 2.1 打包成镜像并通过 GitHub 发布

如果希望把 `shenji_overlay` 直接固化进 Docker 镜像，而不是每台机器都先跑本地 build，可以使用仓库补充的打包脚本和 GitHub Actions:

```bash
chmod +x plugin/dp2/package_shenji_overlay.sh
plugin/dp2/package_shenji_overlay.sh
```

默认会生成:

```text
.artifacts/shenji-overlay-dnf.tar.gz
.artifacts/shenji-overlay-gm.tar.gz
.artifacts/shenji-overlay-summary.txt
```

其中:

- `shenji-overlay-dnf.tar.gz` 用于构建叠加了神迹覆盖层的主服务镜像
- `shenji-overlay-gm.tar.gz` 用于构建网页 GM 镜像
- `shenji-overlay-summary.txt` 会标记本次打包是否包含 `Script.pvf` 和 `gm/dist/data/data.db`

GitHub Actions 工作流位于:

- `.github/workflows/publish-images.yml`

它会发布三类镜像到 `ghcr.io/<owner>/`:

- `dnf:debian13-qf1031-<version>`
- `dnf-shenji-overlay:<version>`
- `dnf-shenji-godofgm:<version>`

如果打的是 tag，还会自动创建 GitHub Release，并上传上面三个打包产物。

需要特别注意:

- 发布版部署应继续参考清风原有的外部 `data` 目录思路
- 镜像内置的神迹覆盖层文件只在缺失时初始化到 `./data`，不会覆盖已存在的外部文件
- `Script.pvf` 建议直接放到外部 `./data/Script.pvf`
- `gm/dist/data/data.db` 建议作为默认种子随镜像发布，首启自动初始化到外部 `./data/godofgm/data.db`
- 后续网页 GM 的状态变更始终落在外部 `./data/godofgm/data.db`
- 若希望 GitHub 发布版默认带上 `data.db`，需确保 `deploy/dnf/docker-compose/shenji_overlay/gm/dist/data/data.db` 已提交到仓库

若要直接消费 GitHub 发布的镜像，可使用:

- `deploy/dnf/docker-compose/shenji_overlay/docker-compose.release.yaml`
- `doc/DeployGitHubRelease.md`

其中 `doc/DeployGitHubRelease.md` 额外说明了:

- 发布版部署继续如何遵循清风外部 `data` 目录模式
- GitHub 发布镜像相对于清风基础镜像到底替换了哪些部分

网页 GM 默认通过主服务映射到:

```text
http://<PUBLIC_IP>:8088
```

### 3. 只在必要时启用神迹 `df_game_r`

默认策略是不替换清风的 `df_game_r`。

但默认已经启用了神迹 `run` 语义提取版 `data/run/start_game.sh`:

- `Script.pvf` 直接使用外部 `./data/Script.pvf`
- 如果存在 `data/libfd.so`，启动时会复制到 `/home/neople/game/libfd.so`
- 游戏进程会按神迹原始思路挂载 `libhook.so + libfd.so`
- 如果存在 `data/game/channel_info/*`，启动前会覆盖到 `/home/neople/game/channel_info`
- 只有在这样仍然跑不通时，才考虑继续替换 `df_game_r`

同样，频道进程也不再直接沿用清风默认脚本:

- `data/run/start_channel.sh` 会继续使用清风的动态 `channel.cfg` 生成逻辑
- 但若存在 `data/channel/channel_amd64`，实际启动的是神迹 `channel_amd64`
- `channel.cfg` 中原来写死的 `192.168.200.131` 会被 `MONITOR_PUBLIC_IP` 动态替换
- 若某次神迹更新缺失 `channel_amd64`，脚本会自动回退到清风 `df_channel_r`

如果后续验证发现:

- `Script.pvf + 神迹 dp2 + 清风 df_game_r` 仍无法启动
- 或者玩法逻辑明显缺失

再人工将 `optional/df_game_r.shenji` 替换到 `data/df_game_r` 做二次验证。

## 固定约束

神迹 DP 当前应维持以下约束:

- `SERVER_GROUP=3`
- `SERVER_GROUP_DB=cain`
- `DNF_DB_GAME_PASSWORD=uu5!^%jg`
- 建议先只开 `OPEN_CHANNEL=11`

这些约束也已经写进:

- `plugin/dp2/README.md`
- `deploy/dnf/docker-compose/shenji_overlay/docker-compose.yaml`
- `meta/recommended-env.txt`

IP 配置额外注意:

- `docker-compose.yaml` 不再默认写死 `127.0.0.1`
- 若是公网部署，建议保留 `PUBLIC_IP=` 并启用 `AUTO_PUBLIC_IP=true`
- 若是局域网部署，直接手填局域网 IP，并把 `AUTO_PUBLIC_IP=false`

## 更新流程

当清风镜像更新时:

1. 更新仓库
2. 重新执行 `plugin/dp2/sync_from_vmdk.sh`
3. 如有需要，直接替换 `deploy/dnf/docker-compose/shenji_overlay/data/Script.pvf`
4. 在 `deploy/dnf/docker-compose/shenji_overlay` 下执行 `sudo docker compose up -d --build`

当 VMDK 更新时:

1. 替换新的 `VMDK`
2. 重新执行 `plugin/dp2/sync_from_vmdk.sh`
3. 检查 `meta/checksums.txt`
4. 如有需要，替换 `deploy/dnf/docker-compose/shenji_overlay/data/Script.pvf`
5. 在 `deploy/dnf/docker-compose/shenji_overlay` 下执行 `sudo docker compose up -d --build`

## 当前已确认的差异结论

- 神迹 `Script.pvf` 与清风默认 `Script.pvf` 完全不同，而且体积明显更大
- 因为 `Script.pvf` 体积过大，不适合直接放进 GitHub 仓库，所以发布版是否内置它，要以 `shenji-overlay-summary.txt` 为准
- 无论是本地 build 还是 GitHub 发布版，运行时都统一按清风风格把 PVF 放在 `./data/Script.pvf`
- 神迹 `dp2` 与仓库自带 `plugin/dp2/dp2.tgz` 的二进制主体基本一致
- 最新神迹新生额外自带网页 GM，运行目录在 `root/dist`
- VMDK 中存在 `libfd.so` 的二进制成品 `home/neople/game/libfd.so`
- VMDK 中存在 `libfd.so` 的 C++ 源码目录 `root/server`
- VMDK 的 `run` / `run_nopvp` 明确使用 `LD_PRELOAD="/dp2/libdp2pre.so:/home/neople/game/libfd.so"`
- VMDK 的 `run` / `run_nopvp` 明确使用 `channel_amd64`
- VMDK 的 `game/channel_info.etc` 和 `channel/channel_info.etc` 都与清风默认版本不同
- 主要差异集中在:
  - `libfd.so`
  - `channel_amd64`
  - `channel_info.etc`
  - `df_game_r.lua`
  - `df_game_r.js`
  - `libdp2pre.so` 对应清风侧的 `libhook.so`

这意味着“玩法覆盖层”的主战场是 `PVF + DP 脚本 + libfd preload 语义 + channel_amd64/channel_info`，而不是整机环境。

## 数据库比对结论

当前已经对 VMDK 与清风初始化逻辑做过一轮实际比对，结论如下:

- 网页 GM 的 `root/dist/data/data.db` 与仓库内 `deploy/dnf/docker-compose/shenji_overlay/gm/dist/data/data.db` 当前是**字节级完全一致**
- VMDK 里的网页 GM 配置 `root/dist/config/server.json` 与仓库内 `gm/dist/config/server.json` 当前也是一致的
- VMDK 主业务服实际使用的 MySQL 账号密码仍然是 `game / uu5!^%jg`
- VMDK 游戏进程启动日志显示，实际连接的是 `d_taiwan`、`d_taiwan_secu`、`taiwan_cain`、`taiwan_cain_2nd`、`taiwan_cain_log`、`taiwan_login`、`taiwan_prod`、`taiwan_game_event`、`taiwan_se_event`、`taiwan_billing`、`taiwan_cain_auction_gold` 这一组库
- 这组库与清风 `init_main_db.sh + init_server_group_db.sh` 当前初始化并重写 `db_connect` 的目标集合是一致的

同时也确认了几个差异点:

- VMDK 的 MySQL 数据目录里额外有一个 `frida` 库
- 这个 `frida` 库不是靠初始化 SQL 预置的，而是神迹 DP 在运行时通过 `create database if not exists frida` 自动创建
- VMDK 的 MySQL 数据目录里也存在 `taiwan_siroco`
- 但从神迹实际配置和运行日志看，当前业务服并不是直接把 `taiwan_siroco` 当作主业务库在用，`siroco` 更像服务组/频道命名

所以当前迁移策略里“主 MySQL 初始化继续沿用清风”是成立的，不需要额外把 VMDK 的 `/opt/lampp/var/mysql` 整包搬进 Docker。

## 关于源码

当前在 VMDK 中能明确找到的源码是:

- `root/server`: `libfd.so` 的 C++ 注入源码

当前没有找到网页 GM 的 Go / Vue 源码文件，只有:

- 已编译的 `root/dist/godofgm`
- 前端静态资源 `root/dist/web`
- 配置 `root/dist/config/server.json`
- sqlite 数据 `root/dist/data/data.db`

因此网页 GM 目前按**现成二进制 sidecar**处理，而不是按源码重建处理。
