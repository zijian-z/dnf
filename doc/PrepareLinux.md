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

所有镜像版本请查看 [Docker Hub](https://hub.docker.com/repository/docker/llnut/dnf)。

可用的镜像版本

```shell
llnut/dnf:debian13-qf1031-latest
llnut/dnf:ubuntu26-qf1031-latest
llnut/dnf:alma9-qf1031-latest
llnut/dnf:centos7-qf1031-latest
```

拉取示例

```shell
docker pull llnut/dnf:debian13-qf1031-latest
```
