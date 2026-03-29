# 神迹 DP

狗哥神迹·因果专用DP插件 

## 版本信息
dp2.9.0+frida_240418

## 镜像版本要求

* dp2插件需要docker镜像版本>=2.1.9.fix1
* game密码必须为默认密码
* 需要配置环境变量SERVER_GROUP_DB=cain
* 只支持希洛克大区

## 如何使用
将本目录下的dp2.tgz复制到/data/data/dp目录下,然后手动解压dp2.tgz。
解压后目录结构如下:
请务必删除原有的libhook.so文件！！！！！！！
```shell
dp
├── df_game_r.js
├── df_game_r.lua
├── dp2.tgz
├── frida
├── lib
├── libdp2.so
├── libdp2.xml
├── libGeoIP.so.1
├── libhook.so
├── lua
├── lua2
├── README.md
└── script
```

## 从神迹 VMDK 同步到清风覆盖层

如果你手上只有神迹虚拟机磁盘，而目标是继续使用清风镜像运行时，请不要整机迁移。

推荐直接使用仓库内置的同步脚本:

```bash
chmod +x plugin/dp2/sync_from_vmdk.sh
plugin/dp2/sync_from_vmdk.sh /path/to/DNFServer.vmdk
```

默认会生成一套可直接给清风 compose 使用的覆盖层:

- `deploy/dnf/docker-compose/shenji_overlay/data/Script.pvf`
- `deploy/dnf/docker-compose/shenji_overlay/data/channel`
- `deploy/dnf/docker-compose/shenji_overlay/data/game`
- `deploy/dnf/docker-compose/shenji_overlay/data/libfd.so`
- `deploy/dnf/docker-compose/shenji_overlay/data/run/start_game.sh`
- `deploy/dnf/docker-compose/shenji_overlay/data/run/start_channel.sh`
- `deploy/dnf/docker-compose/shenji_overlay/data/dp`
- `deploy/dnf/docker-compose/shenji_overlay/optional/df_game_r.shenji`

其中:

- `libfd.so` 和 `start_game.sh` 是从神迹 `run` 语义里抽出来的必要部分
- `channel_amd64`、双份 `channel_info` 和 `start_channel.sh` 也是必要运行时
- `Script.pvf` 会在本地同步出来做校验，但 `.gitignore` 已忽略该文件，不建议提交到 GitHub
- GitHub 或本地部署时，`Script.pvf` 都应按清风风格直接放到 `./data/Script.pvf`
- 不是只替换 `PVF + dp2` 就结束

如果要把这套覆盖层直接做成可发布镜像:

```bash
chmod +x plugin/dp2/package_shenji_overlay.sh
plugin/dp2/package_shenji_overlay.sh
```

默认会在仓库根目录生成:

- `.artifacts/shenji-overlay-dnf.tar.gz`
- `.artifacts/shenji-overlay-gm.tar.gz`
- `.artifacts/shenji-overlay-summary.txt`

随后可通过 `.github/workflows/publish-images.yml` 发布到 GitHub Container Registry。

详细说明见:

- `doc/ShenjiOverlay.md`

## 重启容器
```shell
docker stop dnf
docker start dnf
```
