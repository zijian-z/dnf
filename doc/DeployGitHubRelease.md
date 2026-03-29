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

## 二、再看 GitHub Release 里的三个附件是什么

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

## 三、先确认这次发布缺了什么

你这次工作流摘要里明确写的是:

```text
included_script_pvf=no
included_gm_data_db=no
```

这代表:

1. 主服务镜像里**没有** `Script.pvf`
2. GM 镜像里**没有** `data.db`

因此部署时必须额外处理这两项:

1. `Script.pvf`
   必须通过外部卷 `shenji_overlay_pvf` 提供

2. `gm/dist/data/data.db`
   必须手工放到宿主机 `./gm-data/data.db`
   如果你没有这个文件，建议先不要启动 `godofgm`，只起主服务

## 四、部署目录准备

在服务器上准备一个单独目录，例如:

```bash
mkdir -p /srv/dnf-shenji
cd /srv/dnf-shenji
mkdir -p data mysql log gm-data gm-log
```

然后从仓库复制下面两个文件到当前目录:

- `deploy/dnf/docker-compose/shenji_overlay/docker-compose.release.yaml`
- `deploy/dnf/docker-compose/shenji_overlay/.env.release.example`

复制后改名:

```bash
cp docker-compose.release.yaml docker-compose.yaml
cp .env.release.example .env.release
```

## 五、填写 `.env.release`

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

## 六、准备 `Script.pvf`

因为这次发布摘要里是 `included_script_pvf=no`，所以必须把 `Script.pvf` 放到外部 Docker volume。

先创建 volume:

```bash
docker volume create shenji_overlay_pvf
```

然后把本地 `Script.pvf` 导入进去:

```bash
docker run --rm \
  -v shenji_overlay_pvf:/pvf \
  -v /绝对路径/Script.pvf:/tmp/Script.pvf:ro \
  alpine sh -c 'cp /tmp/Script.pvf /pvf/Script.pvf'
```

导入完成后，主服务启动时会自动把它同步到容器实际使用的 `/data/Script.pvf`。

## 七、准备 `gm-data/data.db`

因为这次发布摘要里是 `included_gm_data_db=no`，所以网页 GM 镜像内没有预置数据库。

你需要把现成的 `data.db` 放到宿主机目录:

```bash
cp /你的来源/data.db ./gm-data/data.db
```

`data.db` 的来源可以是:

- 之前可用部署里的 `gm/dist/data/data.db`
- 从神迹 VMDK 提取出的 `root/dist/data/data.db`
- 你本地保存的 `shenji-dist/data/data.db`

如果你暂时没有 `data.db`:

- 建议先只启动 `dnf-1`
- 把 `docker-compose.yaml` 里的 `godofgm` 服务先注释掉
- 等拿到 `data.db` 后再启用 GM

## 八、拉取并启动

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

## 九、启动后如何确认成功

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
2. `./gm-data/data.db` 是否存在
3. 容器日志里是否报 sqlite 或权限错误

## 十、常见问题

### 1. 为什么我只需要两个镜像，却看到了三个？

因为 `dnf:debian13-qf1031-*` 是构建基底。
真正运行的是:

- `dnf-shenji-overlay`
- `dnf-shenji-godofgm`

### 2. 为什么主服务起来了，但进游戏失败？

优先检查:

1. `Script.pvf` 是否已经导入到 `shenji_overlay_pvf`
2. `.env.release` 里的 `PUBLIC_IP` 是否填对
3. `GATE_AES_KEY` 是否和登录器保持一致
4. 相关端口是否已放行

### 3. 为什么网页 GM 起不来？

优先检查:

1. `./gm-data/data.db` 是否存在
2. `GM_IMAGE` 是否填对
3. `godofgm` 日志是否报 sqlite 或配置错误

### 4. 我能不能直接运行基础镜像 `dnf:debian13-qf1031-*`？

可以，但那只是清风基础镜像。
如果你的目标是运行“神迹新生 VMDK 迁移到清风 Docker”的版本，应该使用:

- `dnf-shenji-overlay`

## 十一、推荐部署顺序

建议按这个顺序做:

1. 先准备好 `.env.release`
2. 先导入 `Script.pvf`
3. 如果有 `data.db`，提前放好 `./gm-data/data.db`
4. 先启动 `dnf-1`
5. 确认游戏主服务正常
6. 再确认 `godofgm` 正常

如果你手头暂时没有 `data.db`，推荐顺序改为:

1. 先只启动 `dnf-1`
2. 验证服务端和登录器可用
3. 拿到 `data.db` 后再补启 `godofgm`
