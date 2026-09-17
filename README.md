# LidAwake（合盖守护）

LidAwake 是一个原生 macOS 菜单栏工具：接通电源时保持 Mac 合盖运行，切换到电池后恢复正常睡眠，同时替代系统电池图标显示电量、充放电状态和功率信息。

> [!IMPORTANT]
> LidAwake 会安装一个 root LaunchDaemon，并在接通电源时执行 `pmset disablesleep 1`。这是一项系统级设置，不只影响合盖睡眠。请先阅读“工作方式”和“卸载”部分。

## 功能

- 监听 IOKit 电源变化事件，插电时保持运行，拔电时恢复正常睡眠。
- 每 10 秒重新核对一次，修正漏掉的事件或外部状态漂移。
- 后台服务在系统启动时运行，不依赖用户登录或桌面会话。
- 菜单栏电池图标区分充电、接通电源但未充电、使用电池等状态。
- 显示电量、预计充电/续航时间、整机负载、外部输入、电池净功率和适配器能力。
- 在支持的系统上直接读写 macOS 原生 80%–100% 充电上限。
- 提供“插电时合盖保持运行”开关；关闭后仅保留电池显示。
- 提供“电池下也保持运行”限时会话（30 分钟 / 1 小时 / 2 小时），到期、电量低于 20% 或手动停止后自动结束。

## 系统要求

- macOS 13 或更高版本。
- 从源码构建需要 Xcode 16.4 或兼容 Swift 6 的工具链。
- 合盖策略可在 Intel 和 Apple Silicon Mac 上构建运行。
- 原生充电上限仅在 Apple Silicon 和 macOS Tahoe 26.4 或更高版本显示。

充电上限通过运行时检测系统 `PowerUI` 客户端实现。它不是公开开发者 API，因此未来 macOS 更新可能使此区域暂时不可用；失败时应用会隐藏该控件，不会自行模拟断充。有关系统原生充电上限的行为，请参阅 [Apple 支持文档](https://support.apple.com/102338)。

## 工作方式

应用由两部分组成：

1. `LidAwakeHelper` 是 root LaunchDaemon。它在开机阶段监听电源事件并控制 `SleepDisabled`。
2. `LidAwake` 是登录后的菜单栏应用。它显示状态、保存开关设置，并在首次运行时注册系统登录项、安装后台服务。

策略如下：

| 状态 | `SleepDisabled` | 行为 |
| --- | ---: | --- |
| 接通电源且开关开启 | `1` | 保持运行 |
| 使用电池 | `0` | 正常睡眠 |
| 电池会话生效（到期/低于 20% 自动结束） | `1` | 保持运行 |
| 开关关闭 | `0` | 正常睡眠 |
| 无法判断电源 | `0` | 安全回退 |

> [!WARNING]
> 电池供电时合盖运行会让机器散热受阻、温度升高，并快速消耗电量。因此“电池下也保持运行”只提供限时会话，不提供常开模式：会话到期、电量降到 20% 或手动停止后立即恢复正常睡眠，且低电量结束的会话不会因为重新充电而自动恢复。

配置保存在当前安装用户的 `~/Library/Application Support/LidAwake/config.json`。后台状态保存在 `/Library/Application Support/LidAwake/status.json`。一台 Mac 同时只应由一个用户管理这项系统级策略；后安装的用户会成为控制用户。

## 功率数据

- `电源`：标题显示适配器能力，例如 `电源 100W`；下方显示 SMC `PDTR` 实时 DC 输入。
- `电脑`：Apple SMC `PSTR`（System Total）整机功率传感器。
- `电池`：优先使用 SMC `PPBR` 电池电源轨的实时读数；无法读取时才回退到电池包电流或功率平衡估算。

同一份遥测快照中近似满足：

```text
电脑与电源功率直接读取 SMC 传感器，不由其他栏位计算。
```

电脑功率来自 SMC `PSTR`，电源输入来自 SMC `PDTR`，电池功率来自 SMC `PPBR`；这些传感器和菜单通常约每秒更新。由于 macOS 只向 `AppleSmartBattery` 暴露聚合缓存，`BatteryPower` 只作为回退，不作为实时主数据源。这些数值适合观察功率方向和量级，不应当作精密功率计。

充电时间使用 macOS 提供的估算，再按当前充电上限对剩余百分比做近似换算。电池充电并非严格线性，显示值仅供参考。

## 安装发布版

1. 解压发布包。
2. **先**把 `LidAwake.app` 移到 `/Applications` 或 `~/Applications`，再首次打开。
3. 按提示授权安装后台服务。

应用会为当前用户注册登录时启动；root 后台服务安装完成后会在系统启动阶段运行，不需要用户进入桌面。后续若移动应用，请先卸载再从新位置安装，避免登录项仍指向旧路径。

## 从源码安装

```sh
git clone https://github.com/kafeifei/LidAwake.git
cd LidAwake
./Scripts/install-app.sh
```

脚本会构建应用，将其安装到 `~/Applications/LidAwake.app` 并打开。应用通过 macOS `SMAppService` 注册登录时启动；如果用户曾在系统设置中禁止该登录项，菜单中会显示“允许登录时启动…”。首次运行还会请求一次管理员授权，用于把后台服务安装到：

- `/Library/PrivilegedHelperTools/com.kafeifei.LidAwake.helper`
- `/Library/LaunchDaemons/com.kafeifei.LidAwake.helper.plist`

安装完成后可检查：

```sh
pmset -g | grep SleepDisabled
cat '/Library/Application Support/LidAwake/status.json'
```

合盖行为仍应现场 A/B 验证：不连接外接显示器和输入设备，插电合盖确认任务继续运行；保持合盖并拔电，确认系统恢复睡眠。

## 卸载

不要只删除 `.app`，否则系统后台服务仍可能继续运行。请执行：

```sh
./Scripts/uninstall.sh
```

如果只保留了发布版应用，也可以执行应用包中附带的脚本：

```sh
"$HOME/Applications/LidAwake.app/Contents/Resources/uninstall.sh"
```

卸载会先执行 `pmset disablesleep 0`，再移除 LaunchDaemon、系统登录项、旧版 LaunchAgent、配置、状态和应用本体。应用从任意目录运行时，包内卸载脚本都会验证 bundle identifier 后再删除对应的 `LidAwake.app`。

## 开发与验证

运行完整检查：

```sh
./Scripts/check.sh
```

它会执行警告即错误的单元测试、脚本和 plist 校验、Release 构建以及代码签名结构验证。GitHub Actions 使用同一入口。

## 正式发布包

普通源码构建使用 ad-hoc 签名，只适合在本机运行。公开分发 `.app` 需要 Developer ID、Hardened Runtime 和 Apple notarization。准备好证书和 `notarytool` 钥匙串配置后运行：

```sh
LIDAWAKE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
LIDAWAKE_NOTARY_PROFILE='LidAwake-notary' \
./Scripts/release.sh
```

发布脚本会生成 arm64 + x86_64 Universal Binary，签名所有可执行文件，提交公证、装订 ticket、通过 Gatekeeper 检查，并在 `dist/` 生成 ZIP 和 SHA-256 文件。Apple 的要求见 [Distributing software on macOS](https://developer.apple.com/macos/distribution/) 和 [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 隐私与网络

LidAwake 不包含网络请求、遥测、分析、更新检查或用户账号。所有状态都保存在本机。

## 许可证

项目使用 [MIT License](LICENSE)。电池图标部分改编自 MIT 许可的 [Stats](https://github.com/exelban/stats)，详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
