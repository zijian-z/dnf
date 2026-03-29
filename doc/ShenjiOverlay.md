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

- `data/Script.pvf` 只建议本地保留做 diff 和校验
- 该文件已经被 `.gitignore` 忽略，不建议提交到 GitHub
- 真正部署时，应把 `Script.pvf` 上传到外部 Docker volume `shenji_overlay_pvf`

### 2. 启动清风容器

先准备外部 PVF 卷:

```bash
docker volume create shenji_overlay_pvf
docker run --rm \
  -v shenji_overlay_pvf:/pvf \
  -v /绝对路径/Script.pvf:/tmp/Script.pvf:ro \
  alpine sh -c 'cp /tmp/Script.pvf /pvf/Script.pvf'
```

容器启动时会自动检查 `/data/pvf_external/Script.pvf`，并同步到容器内部实际使用的 `/data/Script.pvf`。

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

网页 GM 默认通过主服务映射到:

```text
http://<PUBLIC_IP>:8088
```

### 3. 只在必要时启用神迹 `df_game_r`

默认策略是不替换清风的 `df_game_r`。

但默认已经启用了神迹 `run` 语义提取版 `data/run/start_game.sh`:

- `Script.pvf` 若存在于外部卷 `shenji_overlay_pvf`，启动时会先自动同步到 `/data/Script.pvf`
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
3. 如有需要，重新上传最新 `Script.pvf` 到 `shenji_overlay_pvf`
4. 在 `deploy/dnf/docker-compose/shenji_overlay` 下执行 `sudo docker compose up -d --build`

当 VMDK 更新时:

1. 替换新的 `VMDK`
2. 重新执行 `plugin/dp2/sync_from_vmdk.sh`
3. 检查 `meta/checksums.txt`
4. 将新的 `Script.pvf` 上传到 `shenji_overlay_pvf`
5. 在 `deploy/dnf/docker-compose/shenji_overlay` 下执行 `sudo docker compose up -d --build`

## 当前已确认的差异结论

- 神迹 `Script.pvf` 与清风默认 `Script.pvf` 完全不同，而且体积明显更大
- 因为 `Script.pvf` 体积过大，不适合直接放进 GitHub 仓库，部署时应改走外部 Docker volume
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

## 关于源码

当前在 VMDK 中能明确找到的源码是:

- `root/server`: `libfd.so` 的 C++ 注入源码

当前没有找到网页 GM 的 Go / Vue 源码文件，只有:

- 已编译的 `root/dist/godofgm`
- 前端静态资源 `root/dist/web`
- 配置 `root/dist/config/server.json`
- sqlite 数据 `root/dist/data/data.db`

因此网页 GM 目前按**现成二进制 sidecar**处理，而不是按源码重建处理。
