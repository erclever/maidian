# 脉点 · Maidian

脉点是一款原生 macOS 菜单栏监控工具。菜单栏常驻显示上传、下载速度；点击后可以查看 CPU、温度、内存、磁盘及应用资源排行。

## 功能

- 菜单栏固定宽度显示双向网速：上行为上传，下行为下载。
- 悬浮面板展示 CPU 使用率和温度、估算内存、压缩内存、交换空间及启动磁盘空间。
- 应用排行默认按驻留内存排序，可切换到网络排行，并按上传或下载速度排序。
- 深浅色适配、系统菜单磨砂材质、登录启动开关和退出按钮。
- 按需采集排行，采样命令有超时与取消机制；数据仅在本机处理，不包含数据上传功能。

## 环境与兼容性

- 声明最低系统版本为 macOS 13；提供 Apple Silicon 和 Intel 两种架构。
- 当前实机验证范围：Apple M1 Pro、macOS 27。Intel 架构仅在该机器的 Rosetta 下运行过基础自检；其他 macOS 版本和 Intel 真机尚未验收。
- 本机工具链构建 Intel 版本时出现 Swift 兼容库缺少 x86_64 的链接警告；尤其不应将 macOS 13–26 的兼容性视为已验证。
- CPU 温度依赖非公开 SMC 接口及固定传感器键。不同机型、权限或系统版本可能无法读取，界面会显示“不可用”。

## 构建与运行

需要 macOS、Apple Command Line Tools（或相应 Xcode 工具链）、Swift 和系统 SDK；没有第三方运行依赖。命令在仓库目录执行：

```sh
git clone https://github.com/Hyperion424/maidian.git
cd maidian
./build.sh
open build/MacLiteMonitor.app
```

构建脚本生成本地 ad hoc 签名的通用应用，所有构建产物位于 `build/`。应用只显示在菜单栏，点击网速打开面板。登录启动默认由系统状态决定，可在面板中开关；建议先将应用放在稳定位置。

本项目没有在 GitHub 提供经过公证的安装包。自行构建的应用未使用 Developer ID 签名，也未经过 Apple 公证；传给其他人后，Gatekeeper 可能阻止启动。参见 [Apple 的分发说明](https://developer.apple.com/macos/distribution/)和[安全打开应用的说明](https://support.apple.com/zh-cn/102445)。

## 使用与指标口径

菜单栏统计启用的 `en*` 接口流量，不计 `utun`，但可能包括局域网流量或多个启用接口。应用排行来自系统 `nettop`，按进程采样并尽量合并应用辅助进程；因此排行与接口总量口径不同。内存排行是各进程驻留内存之和，可能重复计算共享内存；系统内存是估算值，不保证与活动监视器一致。磁盘显示 `/` 所在文件系统的可用和总空间。温度显示传感器均值，颜色仅表示区间，并非健康诊断。

更多实现、测试和分发细节见 [技术说明](docs/architecture.md)、[开发与测试](docs/development.md)和[隐私与安全](docs/privacy.md)。

## 来源与许可

基于 [jodacame/NetSpeed](https://github.com/jodacame/NetSpeed) 的 MIT 许可代码开发，参考基线为 `fc15e8e01eeaa0f3649d1bd07d222d0563a6274f`。保留上游版权和 [MIT 许可证](LICENSE)。SMC 消息布局参考 [macos-smc-fan 研究记录](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md)。
