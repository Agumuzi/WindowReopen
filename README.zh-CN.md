# WindowReopen

[English](README.md) · 简体中文

一个极简的 macOS 窗口激活增强工具，使用原生 Swift 和 launchd 恢复最小化窗口、请求重新打开窗口，并在需要时自动转移焦点。

WindowReopen 是免费的 MIT 开源用户级 LaunchAgent。macOS 继续提供原生 **Command–Tab** 界面、快捷键、图标和切换动画。

## 使用场景

- **切到只有最小化窗口的应用。** 服务发出原生 reopen 请求，支持此行为的应用自行选择恢复哪个窗口。
- **切到窗口已全部关闭的应用。** 如果进程仍在运行，应用可以按自身规则打开窗口或显示选择界面。
- **关闭或最小化前台应用的最后一个可见窗口。** 焦点交给当前可见窗口中排在最前面的其他普通应用。当前应用仍有可见窗口时，焦点由 macOS 照常处理。
- **没有其他可见窗口。** 仅激活访达，让桌面保持为空。

## 工作原理

服务通过 `NSWorkspace` 接收应用激活通知，使用公开的 Core Graphics 窗口元数据确认目标应用是否有屏幕上的普通窗口。短暂等待后仍无可见窗口时，服务再次核对前台应用，再请求系统重新打开已运行的实例。

焦点接力每 150 毫秒检查符合条件的前台应用。连续两次确认最后一个可见窗口消失后，按屏幕窗口的堆叠顺序选取下一个应用。切换 Space 时会清除旧的观察记录，接力自身产生的激活会跳过一次 reopen 检查。

访达保留原生桌面、Dock 及 Command–Tab 行为。激活访达不会触发 WindowReopen 自动复开，失去最后一个访达窗口也不会触发接力。访达仍可接收焦点，包括在空桌面时。

## 系统要求与实测范围

- 需要 **Apple Silicon（arm64）** 和原生 arm64 终端环境。Intel Mac 暂不支持，也未验证。
- Swift 的部署目标为 **macOS 13.0 或更高**。实际运行测试在 **Apple M1 Pro、macOS 27.2.1** 上完成。
- 需要 Xcode 或 Xcode 命令行工具中的 Swift 工具链，可用 `xcrun --find swiftc` 检查。
- 以普通用户身份在当前已登录的 macOS 图形会话中执行安装。

在该环境下，v1.1.1 使用 AppKit 测试窗口验证了恢复、复开、快速程序化切换和多窗口，也实测了访达窗口关闭与最小化、访达接力、空桌面兜底，以及普通桌面与词典全屏桌面的往返。空白桌面和 Dock 的点击、物理 Command–Tab 操作，以及两个普通 Space 之间的切换尚未验证。登录启动已核对 LaunchAgent 配置和注册状态。

## 从源码安装

在 [Releases 页面](https://github.com/Agumuzi/WindowReopen/releases) 下载 **Source code (zip)** 或 **Source code (tar.gz)**。解压后，在该目录打开终端并运行 `/bin/bash ./install.sh`。

也可以克隆仓库：

~~~sh
git clone https://github.com/Agumuzi/WindowReopen.git
cd WindowReopen
/bin/bash ./install.sh
~~~

如果已使用 Command Reopen，请先退出并关闭原版的登录启动。安装器会检查正在运行的 Command Reopen 进程。

安装器将在本机编译可执行文件，检查架构和 LaunchAgent 配置，然后在当前 GUI 会话加载服务。可执行文件和源码安装在 `~/Library/Application Support/WindowReopen/`，用户登录启动文件为 `~/Library/LaunchAgents/local.windowreopen.plist`。Release 仅分发源码。

## 查看状态、暂停和恢复

~~~sh
domain="gui/$(id -u)"
job="$domain/local.windowreopen"
agent="$HOME/Library/LaunchAgents/local.windowreopen.plist"

# 查看状态与进程
launchctl print "$job"
pgrep -lx window-reopen

# 在当前图形会话暂停
launchctl bootout "$job"

# 恢复已暂停的服务
launchctl bootstrap "$domain" "$agent"

# 重启已加载的服务
launchctl kickstart -k "$job"
~~~

如需禁用下次登录启动，运行 `launchctl disable "$job"`，并暂停已加载的服务。恢复前先运行 `launchctl enable "$job"`。

## 更新与卸载

解压新版 Release 并运行其中的 `/bin/bash ./install.sh`。如果使用克隆仓库的 `main` 分支，先执行 `git pull --ff-only`。安装脚本会将上一版备份到同级的 `WindowReopen-backup.*` 目录。如果安装时服务启动失败，脚本会尝试恢复旧文件并重新加载原服务。

~~~sh
/bin/bash "$HOME/Library/Application Support/WindowReopen/uninstall.sh"
~~~

卸载会卸载服务并移除本项目的安装文件，保留旧备份、源码副本及手动放入的额外文件。如果安装目录中留有额外文件，重新安装前请先将其移出该目录。

## 权限和隐私

服务没有图形界面、Dock 或菜单栏图标，没有遥测、运行时网络通信或第三方运行时依赖。无需申请辅助功能、屏幕录制、输入监控、自动化或完全磁盘访问权限。无需管理员权限，不修改系统文件。

服务读取窗口归属、边界、可见性和排列顺序等元数据。诊断使用 macOS 统一日志，可包含进程号或错误码，无窗口标题或文档内容。

## 已知限制

- 系统应用激活通知不带来源字段，Dock、Spotlight 或程序化激活也可能触发。
- 自动复开排除访达，包括通过 Command–Tab 切到无窗口的访达。
- 当前屏幕或 Space 之外的窗口与最小化窗口不总能可靠区分。应用布局、全屏切换和辅助窗口可能影响判断。
- 应用自行决定如何处理原生 reopen 请求，也可以忽略请求。焦点接力激活目标应用，具体哪个窗口获得焦点由 macOS 和应用决定。
- 应用自己关闭最后一个窗口，或通过快捷键操作时，也可能触发接力。实际切换前台会自然更新 macOS 应用切换器的最近使用顺序。

## 致谢和许可证

原生 reopen 机制和窗口判断方法参考了 [Command Reopen](https://github.com/Feng6611/mac-command-reopen) 1.5.5 的[提交 `011eba15`](https://github.com/Feng6611/mac-command-reopen/commit/011eba15baf6cd0ff5c9245aa96431701f90a602)。感谢 Chen 公开上游实现。

项目采用 [MIT 许可证](LICENSE)，保留上游版权声明 **Copyright (c) 2025 Chen**。
