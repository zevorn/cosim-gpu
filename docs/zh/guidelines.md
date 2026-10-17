[English](../en/guidelines.md)

<!--
SPDX-License-Identifier: Apache-2.0
-->

# Rust bridge 开发规范

`crates/` 中的 Rust 代码遵守以下规则。
模拟器子模块遵守各自的开发规范。
适用的通用原则参考
[Asterinas Coding Guidelines](https://asterinas.github.io/book/to-contribute/coding-guidelines/)，
配置与生命周期规则由 cosim-gpu 的接口要求确定。

## 模块边界

- `cosim-topology` 负责解析 YAML、展开导入和模板、校验声明，并根据调用方提供的
  上下文渲染启动参数。它只读取拓扑文档，不读取环境变量、其他文件系统状态，也不调用
  操作系统接口。
- `cosim-runtime` 负责所有依赖执行系统的内容：主机事实（`ExecEnv`）、会话路径
  （`SessionLayout`）、执行计划、进程、文件、锁和清理。
- `cosim-cli` 负责命令行解析、信号、标准输入生命线和终端输出。
- 每个模块组织一个完整概念，公开调用方实际需要的操作。
- 共享依赖在 workspace 中声明，成员统一继承；内部路径依赖遵守相同规则。
- 导入其他模块的自由函数和静态变量时，保留所属模块限定。
  类型和 trait 可以直接导入。
- 显式声明导出内容，根据现有调用方选择必要的可见范围。
  只读数据类型使用公开字段并标注 `#[non_exhaustive]`。

依据 Asterinas 的
[模块与可见性规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/rust-specific/crates-and-modules.html)
和[设计规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/design.html)。

## 类型与配置边界

解码得到的输入类型（`raw`）与校验后的类型（`model`）相互独立。
数值在边界处解析一次：大小转换为 `ByteSize`，格式和总线转换为 enum，名称转换为
`Identifier`，字段组合转换为 `DiskMode`、`Option<DirectBoot>` 这类类型。
校验后的类型不包含需要后续代码强制取值的可选字段。
有限选项使用携带数据的 enum 表示，例如 `Adapter`、`CommandTemplate`、`Probe` 和
`DiskMode`；`match` 必须保持穷尽。
字节数量、区域边界、偏移和截止时间使用显式的溢出检查。
通过不同操作或 enum 表达影响行为的模式选择。
配置中的布尔属性保留其明确的数据含义。

YAML 语法使用 `serde_yaml_ng` 和 Serde 解析。
Schemars 生成配置 schema，MiniJinja 渲染适配器模板。
JSON 参数数组和持久化记录使用 Serde JSON。
成熟格式的解析使用现有库。
项目代码在解析后的数据上实现导入、模板、标识符和资源规则。
相对路径在定义它的文档中解析；`..` 保持原样，由文件系统在解析符号链接之后处理。

依据 Asterinas 的
[类型约束规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/rust-specific/types-and-traits.html)
和[输入校验规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-security/security-properties.html#validate-at-boundaries)。

## host 外部参数

host 的程序路径、机型、加速方式、CPU、内存、启动、存储、显示、监控和附加 QEMU
参数来自 YAML 或导入的模板。
示例默认值保存在 `samples/hosts/`。
ARM64 host 使用 `qemu-system-aarch64`，x86_64 host 使用 `qemu-system-x86_64`。
CPU、机型、启动镜像和客户机物理内存范围必须符合所选配置。
不同执行架构的 gem5 目标文件分别保存在独立的构建目录中。
Rust 计算会话路径、内存偏移、准备后的磁盘路径和设备端点。
host 适配器定义这些值如何组成命令行参数，并声明其 PCIe 布局可以挂载的设备数量。

适配器提供参数列表，或者提供渲染为 JSON 字符串数组的 MiniJinja 命令模板。
每个数组元素对应一个进程参数，执行过程不经过 shell 解释。
host 适配器必须绑定生成的内存池，并提供声明的 QMP 和串口端点。
`cosim run --dry-run` 会校验 payload 和所选镜像配方，并显示 `cosim run` 将使用的
程序、参数、环境、资源和缓存操作。该命令不会构建镜像或启动进程。
每个设备进程都在执行环境中以原生进程运行，执行环境是 Linux 主机或开发容器。
适配器启动的每个进程都在前台运行，把全部资源使用者保留在自己的进程组中，并保持继承
的文件描述符打开，使会话锁和镜像租约传递到其子进程。

## 错误与资源所有权

配置、文件系统和进程错误通过 `Result` 与 `?` 返回。
错误信息包含相关路径、字段、节点或操作。
用户输入导致的错误不能触发 panic。
内部约束通过构造过程建立，或者进行显式检查。
`debug_assert!` 用于不属于输入校验的内部正确性断言。

每个文件、socket、锁和子进程都只有一个所有者值，会话以树的形式持有这些值。
创建资源后，在下一个可能失败的操作之前登记它的所有者。

- 有序关闭是显式的、消费 `self` 的 `async fn shutdown(self)`：先发送 SIGTERM，
  限时等待，再发送 SIGKILL。丢弃进程组时直接发送 `killpg(SIGKILL)`，不等待；丢弃锁
  时释放锁。
- 进程使用的文件、socket 和目录只能在使用者停止后，通过显式的、消费 `self` 的
  `remove` 删除。丢弃这些所有者时保留文件，交给 `cosim clean` 处理，因为这条路径上
  无法确认进程已经终止。初始化阶段（尚未启动任何进程时）创建的目录在初始化失败时
  删除。
- 节点 future 留在会话任务内部（`FuturesUnordered`），不把资源所有者移入
  `tokio::spawn`。
- 依赖关系用租约表示：就绪的节点交给每个依赖者一个 `mpsc::Sender` 克隆，所有克隆
  释放后才停止自己。就绪状态是一个类型状态，只有就绪节点能交出租约。
- 取消通过 `CancellationToken` 传递到资源所有者。库通过事件报告进度，不注册信号
  处理器，也不向终端输出。
- 子进程由 launcher 线程通过 `setpriv --pdeathsig KILL` 启动，launcher 退出时由内核
  终止子进程。锁的文件描述符设置 close-on-exec；会话把会话锁交给自己启动的每个进程，
  把镜像租约交给使用该镜像的 host 或辅助进程。只要还有使用这些资源的进程存活，锁就一直
  有效，并且不会传到其他会话的进程。
- 共享文件和 overlay 只能在使用者停止后删除。无法确认进程已经终止时，保留资源并在
  verdict 中记录。
- 其他会话也可能创建的目录只能以完整状态出现：先以会话专用名称准备目录，再以不替换
  已有目录的方式重命名。
- 持久化的 manifest 用于 launcher 被杀死或异常退出后的 `cosim clean`；`clean` 先获取
  每个会话进程都持有的会话锁，再根据所属目录校验路径，并通过相同的所有者类型删除
  资源。
- QEMU 命令不得包含 `-daemonize` 或 `--daemonize`，生成执行计划时会拒绝这些参数。

依据 Asterinas 的
[正确性规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-development/correctness.html)
和[资源管理规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-development/resource-management.html)。

## Rust 代码约定

- 使用常规 Rust 命名，并通过 `Duration` 等类型或明确字段名表示单位。
- 保存闭包或函数指针的变量使用 `_fn` 后缀。
- 普通外部属性按字母顺序排列，`derive` 放在这些属性最后。
  派生 trait 也按字母顺序排列。
  Serde、Schemars 和 Clap 等 derive helper 属性放在对应 derive 声明之后。
- 公开流程优先于实现辅助函数，便于阅读。
  使用提前返回和命名中间值，避免深层嵌套分支。
- 为公开接口和模块职责编写简洁的 rustdoc。
  需要时说明错误、副作用和所有权。
- 注释只记录必要且符合事实的内容，并使用英文。
  完整的注释句子使用标点。
- bridge 代码使用安全 API，workspace lint 禁止本地 unsafe 代码。
  这些 API 背后的平台接口可以由依赖库实现。

来源：Asterinas
[命名规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/rust-specific/naming.html)、
[属性规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/rust-specific/attributes-and-macros.html)、
[函数规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/rust-specific/functions-and-methods.html)
和[注释规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-maintainability/rust-specific/comments.html)。
本地 unsafe 代码 lint 是 cosim-gpu 的选择；Asterinas 针对内核的限制仍只适用于其原始范围。

## 验证与文档

构建、测试和检查使用顶层 `justfile`；recipe 根据 `COSIM_ENV` 在主机或开发容器中运行。
`just check-cosim` 以检查模式运行 rustfmt，并运行 Clippy 和回归测试。
`just test-cosim-integration` 使用真实 QEMU 进程、磁盘镜像和信号运行会话。
`just test-cosim-vfio-user` 在 `just build-qemu` 之后运行带有 QEMU vfio-user 设备的 host。
gem5 修改使用 `just check-gem5-style` 和相应的模拟器构建进行检查。
文件归属使用 `just check-maintainers` 检查，补丁草稿使用 `just check-patch-file <patch>` 检查。

保留的测试必须覆盖有意义的行为，可以重复使用，并能发现可能出现的回归。
测试使用实际库、文件和进程，并报告观察到的结果。
不可用的执行环境与已经完成的验证分开记录。
运行证据需要保存命令、源码版本、完整日志和 verdict。

面向用户的文档必须与支持的接口一致。
同时更新 `docs/en/` 和 `docs/zh/`，首行包含规定的语言链接。
架构图使用 Mermaid。
适合维护文字时使用语义换行。
提交和评审要求见[贡献指南](contributing.md)。

来源：Asterinas
[测试规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-development/testing.html)
和[文档风格规范](https://asterinas.github.io/book/to-contribute/coding-guidelines/for-documentation/general-style.html)。
