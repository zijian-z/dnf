# 神迹 VMDK 关键 SO 分析

本文档记录的是基于当前仓库中已同步出的神迹文件、源码残留和静态分析得到的职责判断。

目标不是做完整反编译，而是回答三个问题:

1. 哪些 `.so` 是加载链路里的关键节点
2. 哪些 `.so` 是业务补丁，哪些只是运行时依赖
3. 为什么当前 overlay 要优先保留 `libfd.so + libhook.so + dp2`

## 总览

当前神迹启动链路里的关键模块可以分成四层:

### 1. 预加载引导层

- `libhook.so`

说明:

- 它在仓库侧落到 `libhook.so`
- 实际来源是神迹 VMDK 中的 `libdp2pre.so`
- 本质是一个很薄的预加载引导器

静态证据:

- 其 `SONAME` 仍然是 `libdp2pre.so`
- 字符串中直接包含 `/dp2/libdp2.so`
- 还包含 `dp2_init`

结论:

- 它的职责不是承载玩法逻辑
- 而是在 `LD_PRELOAD` 阶段把真正的 DP2 核心拉起来

### 2. DP2 核心运行层

- `libdp2.so`
- `libdp2game.so`
- `liblua53.so`
- `libuv.so`
- `luv.so`
- `luasql/mysql.so`
- `luasql/sqlite3.so`

说明:

- `libdp2.so` 是 DP2 核心装载器
- `libdp2game.so` 是游戏侧插件桥接层
- 其余 `.so` 主要是 Lua 与异步运行时依赖

静态证据:

- `libdp2.so` 导出 `dp2_init`、`dp2_frida_resolver`
- `libdp2game.so` 依赖 `liblua53.so`、`luv.so`、`libuv.so`
- `libdp2.xml` 明确声明:
  - 目标进程是 `df_game_r`
  - 主脚本是 `/dp2/df_game_r.lua`
  - 插件是 `/dp2/lib/libdp2game.so`

结论:

- 整个 DP2 其实是“预加载器 + 核心 + Lua 环境 + 游戏插件 + Lua 脚本”
- 玩法逻辑并不全写在 `.so` 里，而是大量落在 `df_game_r.lua`

## `libdp2.xml` 的含义

`libdp2.xml` 已经把 DP2 链路写得很清楚:

```xml
<a exe="df_game_r">
    <deps>
        <a><![CDATA[/dp2/lib/libuv.so]]></a>
        <a><![CDATA[/dp2/lib/libffi.so.8]]></a>
        <a><![CDATA[/dp2/lib/liblua53.so]]></a>
        <a><![CDATA[/dp2/lua/luv.so]]></a>
    </deps>
    <script><![CDATA[/dp2/df_game_r.lua]]></script>
    <plugin><![CDATA[/dp2/lib/libdp2game.so]]></plugin>
</a>
```

从这个配置可知:

- `df_game_r` 是注入目标
- `df_game_r.lua` 是主脚本
- `libdp2game.so` 是脚本可调用的游戏插件
- `libhook.so(libdp2pre.so)` 与 `libdp2.so` 负责把它们串起来

## `libfd.so` 的职责

`libfd.so` 是当前最关键的业务补丁模块。

它和上面的 DP2 不是同一层。

### 1. 它会在进程加载时自动执行

仓库里保留了对应源码:

- `optional/libfd_source/fd_wapper.cpp`

这里可以看到:

- `__attribute__((constructor))` 在加载时调用 `on_load()`
- `__attribute__((destructor))` 在卸载时调用 `on_unload()`

这说明 `libfd.so` 本质上是一个注入型补丁库，而不是普通工具库。

### 2. 它直接使用 Frida Gum 改写进程行为

源码:

- `optional/libfd_source/server.cpp`

其中可以看到大量:

- `gum_interceptor_replace_fast(...)`
- `writeCallCode(...)`
- `writeDWordCode(...)`
- `writeByteCode(...)`

这不是普通插件调用，而是直接对 `df_game_r` 进程内代码打补丁。

### 3. 它不是“只是加载 Frida”

虽然 `libfd.so` 自身依赖了 `_frida_*` 符号和 `frida-gum`，但它做的事远不只是启动一个通用 Gadget。

它里面明确写了大量业务级 hook，包括但不限于:

- 旧技能栏兼容修复
- 装备徽章/镶嵌系统扩展
- 老副本与难度开放逻辑修复
- 邮件数量与卡邮件修复
- NPC 好感与奖励逻辑
- 角色扩展数据存取
- 属性、经验、等级、任务相关补丁
- GM 指令扩展，如 `fd_mail`

结论:

- `libfd.so` 是神迹服务端的核心行为补丁
- 它不是“可有可无的附加库”
- 当前 overlay 里优先保留它是正确的

## `frida.so` 的职责

`frida.so` 不是神迹自写玩法补丁。

静态证据:

- `SONAME` 直接显示为 `_frida-gadget.so`
- 字符串中能看到大量 `re.frida.*`、`script-engine`、`gumjs`、`gadget` 相关内容

结论:

- 它是通用 Frida Gadget
- 主要用于动态插桩和脚本运行时

但当前神迹真实启动语义已经不是优先使用它，而是:

1. 优先挂 `libfd.so`
2. `libfd.so` 缺失时才回退到 `frida.so`

这也是当前 overlay 启动脚本的处理逻辑。

## `libfd.so` 与数据库的关系

`libfd.so` 还会主动访问 MySQL。

源码里可以看到:

- 初始化时打开 `taiwan_cain`
- 打开 `d_guild`
- 创建 `frida` 数据库
- 创建 `frida.charac_ex` 表

关键逻辑:

- `create database if not exists frida`
- `CREATE TABLE IF NOT EXISTS frida.charac_ex (...)`

这解释了两个事实:

1. VMDK 里会多出 `frida` 库
2. 即使清风初始化 SQL 里没有这个库，神迹运行后仍会创建它

所以:

- `frida` 库不应被误判为“初始化缺了东西”
- 它更像 `libfd.so` 运行时自建的扩展状态库

## `df_game_r.lua` 说明了什么

虽然这里分析的是 `.so`，但 `df_game_r.lua` 能帮助判断这些 `.so` 的真实用途。

当前主脚本里能明显看到:

- `require("df.frida")`
- 调用 `dpx.item`
- 调用 `dpx.quest`
- 直接执行 SQL
- 改拍卖等级限制
- 禁用回购
- 扩展传送道具

结论:

- 玩法规则大量写在 Lua 层
- `.so` 更偏向提供:
  - 注入入口
  - 运行时
  - Lua 与游戏进程的桥接

## 当前各模块角色总结

### `libhook.so`

- 神迹 `libdp2pre.so` 的落地名
- 预加载引导器
- 负责把 `libdp2.so` 拉起来

### `libdp2.so`

- DP2 核心装载器
- 负责初始化 DP2 运行环境与 resolver

### `libdp2game.so`

- 游戏侧插件桥接层
- 负责把 `df_game_r.lua` 能用到的游戏接口暴露出来

### `frida.so`

- 通用 Frida Gadget
- 不是神迹专属玩法补丁

### `libfd.so`

- 直接改写 `df_game_r` 行为的核心业务补丁
- 会打 hook、改内存、接数据库、扩展系统逻辑
- 当前神迹服务端最值得优先保留的 `.so`

## 对 overlay 方案的影响

基于这轮分析，当前 overlay 方案里以下决策是合理的:

### 1. 必须保留 `libhook.so`

因为它是 DP2 预加载入口。

### 2. 必须保留 `libdp2.so + libdp2game.so + Lua 运行时`

因为它们一起构成 DP2 执行环境。

### 3. 必须优先保留 `libfd.so`

因为它不是普通依赖库，而是神迹核心行为补丁。

### 4. `frida.so` 可以作为回退，不应误判为主逻辑本体

当前真实优先级应是:

1. `libhook.so`
2. `libfd.so`
3. `frida.so` 作为回退

## 当前分析边界

这份文档目前属于“静态分析 + 源码残留交叉验证”，还没有做:

- 完整反汇编
- 全部 hook 地址与对应原函数的逐条映射
- 运行态跟踪

但对于当前 overlay 设计、迁移判断和文件优先级排序，已经足够使用。
