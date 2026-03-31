# 准备部署环境

本指南包含 Docker 安装、交换空间配置和防火墙关闭三个部分。如果已完成这些配置，可以跳过。

## 安装 Docker

升级系统

```shell
yum update -y
```

或

```shell
apt-get update && apt-get upgrade -y
```

下载并运行 Docker 安装脚本

```shell
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

启动 Docker

```shell
systemctl enable docker
systemctl restart docker
```

关闭防火墙

```shell
systemctl disable firewalld
systemctl stop firewalld
```

关闭 SELinux

```shell
setenforce 0
sed -i "s/^SELINUX=.*$/SELINUX=disabled/" /etc/selinux/config
```

## 配置交换空间

当物理内存不足 8GB 时，需要配置交换空间。

创建 Swap 文件

```shell
which /usr/bin/fallocate && /usr/bin/fallocate --length 8GiB /var/swap.1 || /bin/dd if=/dev/zero of=/var/swap.1 bs=1M count=8000
mkswap /var/swap.1
swapon /var/swap.1
sed -i '$a /var/swap.1 swap swap default 0 0' /etc/fstab
```

查看 Swap 是否已启用

```shell
sysctl vm.swappiness
```

如果输出的数字不为 0，说明 Swap 已启用，无需额外操作。

如果输出为 0，执行以下命令启用 Swap。值为 100 表示优先使用虚拟内存，值为 0 表示优先使用物理内存。少量玩家场景下体感差异不大。

```shell
sed -i '$a vm.swappiness = 100' /etc/sysctl.conf
```

重启服务器，或执行以下命令使配置生效

```shell
sysctl -p
```

## 拉取镜像

镜像同时发布到以下仓库，内容完全一致，选择速度最快的即可。

### Tag 说明

| 类型 | 格式 | 示例 |
|------|------|------|
| Release Latest | `<os>-qf1031-latest` | `debian13-qf1031-latest` |
| Release | `<os>-qf1031-<日期>` | `debian13-qf1031-20260331` |
| Dev Latest | `<os>-qf1031-dev-latest` | `debian13-qf1031-dev-latest` |
| Dev | `<os>-qf1031-dev-<commit id>` | `debian13-qf1031-dev-a1b2c3d` |

其中 `<os>` 为 `debian13`、`alma9`、`ubuntu26`、`centos7` 之一。`latest` 始终指向最新的 Release 镜像，`dev-latest` 始终指向最新的开发版镜像。开发版镜像在每次 push 到 main 分支时生成。

### 阿里云 ACR (国内拉取加速)

```shell
docker pull crpi-0ghho6wxim378ik8.cn-hangzhou.personal.cr.aliyuncs.com/llnut/dnf:debian13-qf1031-latest
docker pull crpi-0ghho6wxim378ik8.cn-hangzhou.personal.cr.aliyuncs.com/llnut/dnf:alma9-qf1031-latest
docker pull crpi-0ghho6wxim378ik8.cn-hangzhou.personal.cr.aliyuncs.com/llnut/dnf:ubuntu26-qf1031-latest
docker pull crpi-0ghho6wxim378ik8.cn-hangzhou.personal.cr.aliyuncs.com/llnut/dnf:centos7-qf1031-latest
```

### Docker Hub

```shell
docker pull llnut/dnf:debian13-qf1031-latest
docker pull llnut/dnf:alma9-qf1031-latest
docker pull llnut/dnf:ubuntu26-qf1031-latest
docker pull llnut/dnf:centos7-qf1031-latest
```

### ghcr.io

```shell
docker pull ghcr.io/llnut/dnf:debian13-qf1031-latest
docker pull ghcr.io/llnut/dnf:alma9-qf1031-latest
docker pull ghcr.io/llnut/dnf:ubuntu26-qf1031-latest
docker pull ghcr.io/llnut/dnf:centos7-qf1031-latest
```

### quay.io

```shell
docker pull quay.io/llnut/dnf:debian13-qf1031-latest
docker pull quay.io/llnut/dnf:alma9-qf1031-latest
docker pull quay.io/llnut/dnf:ubuntu26-qf1031-latest
docker pull quay.io/llnut/dnf:centos7-qf1031-latest
```
