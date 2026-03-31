# 神迹 Overlay 方案

这份文档已经合并到主入口:

- [deploy/dnf/docker-compose/shenji_overlay/README.md](../deploy/dnf/docker-compose/shenji_overlay/README.md)

当前以该 README 作为唯一主说明，里面已经收敛了:

- overlay 核心流程
- VMDK 同步与数据库 overlay 生成流程
- Release 部署方式
- 运行时外部卷覆盖规则
- 关键 `.so` / `dp` 模块职责摘要

如果只想快速看神迹 overlay 的当前做法，直接进入 `deploy/dnf/docker-compose/shenji_overlay/` 即可。
