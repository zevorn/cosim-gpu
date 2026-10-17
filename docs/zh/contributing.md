[English](../en/contributing.md)

# 贡献指南

本文规定 cosim-gpu 顶层仓库的补丁要求。`third_party/gem5` 和
`third_party/gem5-resources` 子模块中的修改遵守对应仓库的规则。

justfile 使用 `dev-`、`build-`、`run-`、`test-`、`check-`、`ci-` 和 `maint-` 前缀区分命令用途。运行 `just` 可以查看可用命令。

## 补丁检查要求

提交到 cosim-gpu 的每个非合并提交都必须通过 `scripts/checkpatch.pl` 检查，且不能出现错误。该脚本来自 QEMU 的 `scripts/checkpatch.pl`，cosim-gpu 采用它所检查的 QEMU 补丁风格：

- 每个提交都带有 `Signed-off-by:` 行，格式必须为 `Signed-off-by: Name <email>`，姓名和电子邮件地址取自 `git config user.name` 和 `git config user.email`。
- 提交信息中不能出现标注 AI 的附加字段，例如标注 AI 工具的 `Co-authored-by:` 行、`Assisted-by:`、`Generated-by:` 或 `🤖` 标记。
- 新增的行不能包含行尾空白、DOS 换行符或无效的 UTF-8 字符。文件以换行符结尾。
- 源文件（`.c`、`.h`、`.cpp`、`.py`、`.sh`、`.pl` 等）使用空格缩进。超过 80 列的行产生警告，超过 90 列的行产生错误。
- 声明解释器的 Python 脚本使用 `python3`。
- C 和 C++ 代码（`.c`、`.h`、`.cpp`）遵守 QEMU 编码风格：使用 `/* */` 注释，`if`/`else` 的所有分支都加花括号，指针写作 `type *name`，函数的左花括号单独占一行。
- 新增源文件以 `SPDX-License-Identifier:` 行开头，不能复制许可证模板文本。项目许可证为 `Apache-2.0`；来自 `MIT`、`BSD-2-Clause`、`BSD-3-Clause` 许可证源码的代码可以使用这些许可证，并在提交信息中说明原因。

错误会使检查失败。警告会被报告，但不会使检查失败；提交前需要逐条确认警告。

检查范围是提交新增或修改的行。提交修改已有代码时，被修改的部分同样接受检查。

## 在本地运行检查

检查当前分支上尚未进入 `origin/main` 的全部提交：

```bash
git fetch origin
just check-patch
```

检查指定版本之后的提交：

```bash
just check-patch <base-commit>
```

`just check-patch` 运行 `scripts/check_patch.sh`。该脚本只输出存在问题的提交，每条报告以提交哈希和补丁行号开头；任一提交出现错误时，脚本以非零状态退出。

`just check` 会同时运行 `just check-patch`、ShellCheck 和下文介绍的 `MAINTAINERS.yml` 检查。

其他输入可以直接使用 `scripts/checkpatch.pl` 检查：

```bash
# 单个提交或提交范围
./scripts/checkpatch.pl HEAD
./scripts/checkpatch.pl origin/main..HEAD

# git format-patch 生成的补丁文件
./scripts/checkpatch.pl 0001-example.patch

# 检查整个文件（不检查 Signed-off-by）
./scripts/checkpatch.pl -f scripts/cosim_launch.sh
```

`scripts/checkpatch.pl` 需要 Perl 5，并且必须在 cosim-gpu 源码树中运行。

## 持续集成

`.github/workflows/ci.yml` 中的 `Checkpatch` 任务在每个指向 `main` 的拉取请求和每次推送到 `main` 时运行 `just check-patch`：

| 事件 | 检查的提交 |
|------|------------|
| 拉取请求 | `<PR 基准提交>..<PR 头部提交>` |
| 推送到 `main` | `<推送前的 main 提交>..<推送后的 main 提交>` |
| 推送时没有之前的提交 | 推送的最新提交 |

任务失败时会阻止拉取请求合并。修正报告中的行，修改或变基相关提交，然后强制推送分支。

### ROCm 回归

`Build` 在指向 `main` 的每个拉取请求、每次推送到 `main` 和手动触发时运行。
gem5 任务只编译一次 `VEGA_X86`，上传压缩后的二进制文件、模型测试需要的
`libvfio-user.a`、开发容器镜像和 SHA-256 清单。
依赖它的 `Integration` 工作流下载同一次运行的产物，核对主仓库
与 gem5 的版本、host 架构、运行标识及文件摘要，然后加载构建时使用的容器镜像，
运行恢复后的 MI300X 模型测试，并在该环境中编译 QEMU 和 Rust launcher。
单独重跑失败的回归任务时，使用构建任务返回的固定 artifact ID，复用成功的构建。
不同运行之间，输入标识匹配时可以一起恢复 gem5、静态库和原构建容器镜像。
清单同时保留最初的编译来源和本轮产物发布标识。

独立的镜像任务并行构建 x86 `m5` 工具，并使用仓库维护的 Packer/Ansible 配方：
`resources/images/profiles/guest/ubuntu/24.04/x86_64/rocm7_0`。任务从校验值固定的
Ubuntu cloud 磁盘镜像开始，安装 ROCm 7.0、AMDGPU DKMS、PyTorch 和 GPU 初始化服务，
再导出配套的 Linux 6.8.0-124-generic 内核。QCOW2 磁盘、内核、软件包清单和文件摘要
组成可复用产物。ROM、discovery 固件和 WMI 源码仍从 `third_party/gem5-resources`
读取。

镜像缓存标识包含基础镜像摘要、profile 与 Ansible 输入、外部文件摘要、`m5` 二进制、
QEMU、Packer、Ansible 和磁盘格式。复用时校验输入标识和产物摘要。
将 `COSIM_ROCM_IMAGE_EPOCH` 从默认值 `1` 改为新值可以请求重新构建。回归任务使用固定
artifact ID 下载两份构建产物，检查镜像结构，并在独立的 Ubuntu 24.04 x86_64/KVM runner
中执行测试。本地入口和构建输入见 [ROCm 镜像配方](rocm-image.md)。

`just test-rocm-regression <output> <assets>` 使用 Rust launcher 和示例 host、device
模板。`vector_add`、`gemm`、`reduction`、`transpose`、`prefix_scan` 和
`histogram` 分别使用新启动的虚拟机和独立的磁盘 overlay。默认使用 4 GiB Linux
内存、4 GiB VRAM 和两个虚拟 CPU。8 GiB 共享内存池能够放入托管 runner 的共享
内存容量，并为模拟器保留内存。通过命令的 `--memory`、`--vram`、`--cpus` 参数
可以修改这些设置。每个虚拟机检查初始化
服务、amdgpu、KFD、render 设备以及 `rocminfo` 报告的 gfx942 agent，然后在
`HSA_ENABLE_INTERRUPT=0` 环境下编译并执行指定的 HIP 程序。通过条件包括数值
校验输出 PASS、程序以零状态退出、launcher 成功清理资源。程序打印 PASS 后发生
超时仍然判定失败。遇到首个失败时停止执行，全部指定程序通过后，整体结果才为 PASS。

`ROCm regression gate` 要求 gem5 构建、镜像构建和虚拟机测试都成功；在分支保护中将它设置为必需
检查。`rocm-regression-*` 产物保留完整串口和模型日志、拓扑与命令清单、源码版本、
二进制文件摘要、各程序结果以及 `matrix.tsv`。`gem5-runtime-*` 和 `rocm-guest-*`
构建产物保留两天，
执行证据保留十四天。手动触发 `Build` 可以再次运行完整流程。

`just test-ci` 使用真实 shell 进程检查命令完成和错误处理。
`just test-legacy-build-image` 使用主机实际运行的 Docker，检查所选构建镜像，
确认镜像检查在创建构建产物之前完成。
`just test-cosim-memory` 使用独立的 96 MiB 容器 tmpfs 和真实 QEMU 会话，检查容量
预留、拒绝竞争会话以及容量释放。该命令使用已有的开发镜像。
`just test-ci-integration` 使用 Rust launcher 和 QEMU 检查信号取消、容器输入
关闭、进程清理及日志保留。
`just check-ci` 使用 actionlint 检查工作流的依赖关系。

## 与 QEMU checkpatch.pl 的差异

`scripts/checkpatch.pl` 复制自 QEMU 提交 `615ece3c406b262996e569f29ea6eed0d81c4d8d`，并包含以下 cosim-gpu 修改：

| 方面 | cosim-gpu 行为 |
|------|----------------|
| 源码树识别 | 识别 cosim-gpu 根目录（`LICENSE`、`README.md`、`agents.md`、`.gitmodules`、`docs`、`scripts`、`tests`） |
| SPDX 许可证 | 首选 `Apache-2.0`；同时接受 `MIT`、`BSD-2-Clause`、`BSD-3-Clause` |
| SPDX 要求 | 新增的 `.cpp` 和 `.hpp` 文件同样必须包含 `SPDX-License-Identifier` |
| 许可证模板 | 新文件中出现 Apache License 模板文本时报告错误 |
| 消息文本 | 错误信息指向 cosim-gpu |

其他检查与 QEMU 保持一致。针对 QEMU 专有路径的检查（例如 `linux-headers/`、ACPI 测试数据和 `trace-events` 文件）不会匹配 cosim-gpu 的路径。

该脚本保留上游的 GPL-2.0 许可证。它是开发工具，不会编译进联合仿真程序，也不会随联合仿真程序分发。

从 QEMU 更新该脚本时，复制新的上游 `scripts/checkpatch.pl`，重新应用上表中的修改，并更新本节记录的 QEMU 提交。

## 维护者与审查分配

`MAINTAINERS.yml` 把仓库划分为多个领域，例如 QEMU 前端、各个加速器后端、Guest 镜像和构建系统。每个领域列出所属文件以及维护者和协作者的 GitHub ID。文件格式沿用 Zephyr 的 `MAINTAINERS.yml`，格式说明位于文件开头的注释中。

### 查询维护者

`scripts/get_maintainer.py`（来自 Zephyr）读取 `MAINTAINERS.yml`。先安装一次 Python 依赖：

```bash
pip install -r scripts/ci/requirements.txt
```

然后通过 just 查询：

```bash
just maint-paths scripts/cosim_launch.sh tests/   # 查询路径所属领域
just maint-commits origin/main..                  # 查询提交涉及的领域
just maint-areas                                  # 列出全部领域和维护者
```

`python3 scripts/get_maintainer.py --help` 列出其他子命令，例如 `orphaned` 和 `count`。

### 检查

| 检查 | 位置 | 失败条件 |
|------|------|----------|
| `just check-maintainers` | `ci.yml` 中的 `Maintainers` 任务 | `MAINTAINERS.yml` 出现未知字段、错误的状态值、格式错误的列表、不匹配任何文件的通配模式、缺少结尾 `/` 的目录通配模式、无效的正则表达式，或者处于 maintained 状态却没有维护者的领域；或者某个受版本控制的文件不属于任何领域 |
| `scripts/ci/check_maintainer_changes.py` | `assigner.yml` | 拉取请求新增的维护者或协作者在仓库中没有 triage 及以上权限 |

每个受版本控制的文件都必须属于某个领域。提交在现有领域之外新增文件时，在同一个提交中更新 `MAINTAINERS.yml`。

### 自动分配

指向 `main` 的拉取请求被创建、更新、重新打开或标记为可审查时，`.github/workflows/assigner.yml` 运行 `scripts/ci/set_assignees.py`（来自 Zephyr）：

- 为拉取请求添加所有受影响领域的标签。
- 请求所有受影响领域的维护者和协作者审查，拉取请求作者和主动退出审查的人除外。
- 把修改文件最多的领域的维护者设为负责人。作者是该领域唯一的维护者时，改用下一个领域。只有在没有其他领域受影响时，才把 `Documentation` 的维护者设为负责人。
- `MAINTAINERS.yml` 发生变化时，同时请求所有变化领域的维护者审查。

问题被添加标签时，把拥有这些标签的领域的维护者设为负责人。

该工作流使用 `pull_request_target`，运行 `main` 分支上的脚本。它只把拉取请求中的 `MAINTAINERS.yml` 当作数据读取，因此来自派生仓库的拉取请求无法改变工作流执行的内容。

### 添加维护者

1. 在 GitHub 仓库中为该用户授予 triage 及以上权限。
2. 在 `MAINTAINERS.yml` 对应领域的 `maintainers` 或 `collaborators` 下添加该用户的 GitHub ID。
3. 提交拉取请求。系统会请求该领域现有维护者审查；如果跳过了第 1 步，权限检查会失败。

## 误报

`scripts/checkpatch.pl` 对正确代码报告错误时，在 cosim-gpu 仓库提交问题，附上对应提交和完整报告。
