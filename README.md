# NetSpeed

常驻 macOS 状态栏的实时网速显示工具，无 Dock 图标，无第三方依赖。

- 显示格式：`↓下载 ↑上传`，每秒刷新（B/K/M/G 自动换挡）
- 只统计物理网卡（en*：Wi-Fi / 有线 / iPhone USB 共享），排除 VPN（utun）、回环、虚拟网桥，不会造成 VPN 场景下的重复计算
- 点击状态栏文字：查看总计速率（圆角卡片样式）与 Top 5 进程排行（等宽数字、进程名固定宽度超长截断）、切换开机自启动、退出
- 进程排行基于系统 `nettop`（无需 root），每 2 秒后台采样一次，静默进程（< 1K/s）自动隐藏；代理进程（mihomo）因与其他 App 重复统计被排除

## 构建

需要 Swift 命令行工具（Xcode CLT）：

```bash
./build.sh        # 产出 NetSpeed.app
```

## 安装 / 卸载

```bash
cp -R NetSpeed.app ~/Applications/
open ~/Applications/NetSpeed.app   # 首次启动后自动加入登录项
```

卸载：状态栏菜单退出后删除 `~/Applications/NetSpeed.app`，
并在 系统设置 → 通用 → 登录项 中移除 NetSpeed。

## 调试

```bash
./NetSpeed.app/Contents/MacOS/NetSpeed --once   # 终端采样 1 秒后打印速率
./NetSpeed.app/Contents/MacOS/NetSpeed --apps   # 打印 Top 5 进程网速排行
```
