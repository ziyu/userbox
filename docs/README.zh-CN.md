# UserBox：macOS 原生桌面 Demo

目标不降级：在同一台 Mac 上用专用系统账号运行真正的独立桌面，打开 Finder 和宿主安装的原生 App，在当前桌面的 UserBox 窗口中显示，Agent 不抢物理用户的鼠标、键盘和焦点。

代码包含原生查看器、会话内服务、系统账号准备脚本、CLI、权限/会话/输入接管保护和真实文件保存验收。不是浏览器仿桌面，也不是 Linux 容器。

## 启动

在 Mac 上构建和准备一次：

```sh
swift test
bash scripts/build.sh
sudo bash scripts/prepare.sh demo
open /Applications/UserBox.app
```

也可使用成功的 GitHub Actions 构建中的 `UserBox-macOS-demo`，解开内层 ZIP，运行 `Start UserBox.command`。这是开发签名版本，不是已公证的发行版。

准备脚本创建 `ub_demo` 标准账号，由 macOS 工具交互询问该账号密码；不保存密码，不修改 SIP、FileVault、TCC 或防火墙，也不会偷偷开启远程控制。

在系统设置开启屏幕共享，并仅授权专用账号。UserBox 的 **Start desktop** 通过仅监听本机回环的中继打开 Apple 自带登录窗口。使用 `ub_demo` 登录并选择该账号自己的桌面，不选择共享当前用户屏幕。保留此登录连接。首次在专用账号里向 **UserBoxSession** 授予屏幕录制和辅助功能权限，必要时点击 **Restart helper**。

随后 UserBox 从专用账号内的服务直接接收真实桌面画面。默认只观察，点击 **Take over** 后，只有图片区域里的输入被转发。**Observe** 归还控制权，CLI/Agent 可以独占接管。

点击 **Open Finder** 或选择已安装应用；导入文件后，在 Box 的 `Documents/UserBox/Imports` 中打开编辑，再显式导出。不同账号不共用钥匙串、浏览器配置和密码。

## 真实验收

**Run native isolation test** 会在 Box 内打开 Finder 与 TextEdit，使用键盘输入替换文件内容并保存，再读取实际文件确认结果。宿主同时检查焦点、前台应用和鼠标是否变化，报告写入宿主 `~/Library/Logs/UserBox`。测试时可在左侧宿主输入框持续打字；不要主动移动鼠标或切换焦点，否则宿主隔离阶段应当判失败。

已在 Linux 云端通过的是 **35 项协议、系统凭据和隔离策略测试**。macOS 构建以对应 Actions 结果为准；第二个真实 Aqua 会话及输入隔离必须由实机验收证明，当前没有伪造为已跑通。完整需求是验收目标，不满足时就是尚未完成。

详细说明：[启动与排查](macos-demo.md) · [实机验收](acceptance.md) · [设计](design.md)。
