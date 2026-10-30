# 开发、测试与分发

## 工程文件

- `main.swift`：AppKit 界面、网络与系统统计、应用排行和内置自检。
- `temperature.c`、`bridging.h`：SMC 只读接口及 Swift 桥接。
- `Info.plist`、`build.sh`：应用元数据与通用二进制构建。
- `assets/AppIcon.icns`、`assets/draw-icon.swift`：图标及绘制源码。
- `LICENSE`：上游 MIT 许可和版权声明。

## 构建

安装 Apple Command Line Tools，并在 macOS 仓库根目录运行：

```sh
./build.sh
codesign --verify --deep --strict build/MacLiteMonitor.app
lipo -archs build/MacLiteMonitor.app/Contents/MacOS/MacLiteMonitor
```

脚本使用 `clang` 和 `swiftc` 分别构建 `arm64` 和 `x86_64`，用 `lipo` 合并，再写入图标和许可证并执行 ad hoc 签名。构建需要支持两个架构的 macOS SDK 和 Swift 工具链；编译成功不等同于不同机器的运行验收。若运行中的应用位于同一构建路径，更新后需重启应用。`build/` 为可再生的本机输出，不应提交其中的采样结果、测试截图、安装包或个人文件。

## 自动检查

```sh
build/MacLiteMonitor.app/Contents/MacOS/MacLiteMonitor --self-test
build/MacLiteMonitor.app/Contents/MacOS/MacLiteMonitor --runner-test
```

`--self-test` 覆盖部分速率格式化、进程解析与排序、温度颜色和真实本机读取。`--runner-test` 使用子进程检查正常输出、5 秒超时、取消回收、过期任务阻止和后续恢复。测试会在本机启动短暂进程；温度打印结果依赖当前硬件。测试属于冒烟与组件检查，不替代完整验收。

`--smoke` 是有界的交互式诊断：在图形会话中短暂打开面板、切换排行、进行断言并退出，也会在当前目录的 `build/` 写入视图截图。测试时若有人点击窗口外部，面板可能正常关闭，导致诊断断言失败；截图可能包含本机应用名称，不要提交或公开。该模式不等同于鼠标、键盘和可访问性实测。

## 验证状态与待验证范围

截至 2026-10-30：M1 Pro / macOS 27 上做过构建、签名、采集、排行排序、进程超时与取消、模拟失败恢复，以及约两分钟的常驻资源采样。Intel 架构在该 Mac 的 Rosetta 下通过基础自检，但 Intel 真机、macOS 13–26、30 分钟运行、真实注销登录、睡眠唤醒、VPN/网卡切换、多显示器、完整键鼠交互及深色内存面板的实际窗口效果尚未完成验收。

## 资源占用观测

2026-10-30，在 M1 Pro、macOS 27 上对包含采样超时修复的版本进行了约 120 秒观察。通过 `footprint --noCategories -p <PID>` 在起点、中点、终点检查：物理占用约 21–22 MB，系统记录峰值约 22 MB；主进程 CPU 时间增加约 0.34 秒，平均约 0.28%。CPU 数字不含短暂子进程，观察期间面板实际状态未确认。

这是单台机器、当时版本与负载下的短时结果。后续版本、不同机型、面板持续打开以及更长运行时间的占用可能不同；没有完成 30 分钟长测，也没有与其他应用做同条件对比，因此不能据此保证占用上限或声称优于特定产品。

## 分发

保留 `LICENSE` 及其版权声明。当前 `build.sh` 只进行 ad hoc 签名，不产生 Apple 公证结果，也不发布或上传。对外提供可安装版本前，应由具备权限的维护者使用有效 Developer ID、签名和公证流程，并在目标设备与系统版本上验收；未经这些步骤不要声称安装包经过 Apple 验证或保证兼容。
