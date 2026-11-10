# Matrix

[![build](https://github.com/Matrix-dk/Matrix/actions/workflows/build.yml/badge.svg)](https://github.com/Matrix-dk/Matrix/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/Matrix-dk/Matrix)](https://github.com/Matrix-dk/Matrix/releases/latest)
[![license](https://img.shields.io/github/license/Matrix-dk/Matrix)](LICENSE)

macOS 菜单栏系统监视器，类似 iStat Menus 的轻量实现。纯 Swift + SwiftUI + AppKit，没有第三方依赖，不需要 Xcode 工程文件，`swift build` 就能出包。

## 直接下载

不想自己编译就去 [Releases](https://github.com/Matrix-dk/Matrix/releases/latest) 下 `Matrix.zip`（约 310 KB，通用二进制 arm64 + x86_64）：

```bash
unzip Matrix.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/Matrix.app   # 绕过 ad-hoc 签名的「无法验证开发者」
open /Applications/Matrix.app
```


## 功能

每个模块是**独立的状态栏条目**，可以只留一个，也可以全开。显示样式可在设置里切换：标签+数值 / 只显示数值 / 只显示图标 / 圆环进度。

| 模块 | 状态栏 | 弹窗面板 |
| --- | --- | --- |
| CPU | 占用百分比 + 迷你曲线 / 圆环 | 每核柱状图、用户·系统占比、1/5/15 分钟负载、开机时长 |
| GPU | 占用百分比 | 渲染器占用、显存占用、GPU 核心数（Apple Silicon / Intel 通用） |
| 内存 | 占用百分比 | App/联动/压缩/缓存/交换空间、**内存压力**、页面换入换出 |
| 网络 | ↓下行 ↑上行实时速率 | 每接口分别统计、主接口标记、累计流量（可重置）、公网 IP、Wi-Fi 信号/信道/速率/协议 |
| 磁盘 | 根分区占用 | 读写速率、全部本地卷的可用空间 |
| 电池 | 电量百分比 | 充放电状态、剩余时间、循环次数、健康度、温度、功率 |
| 传感器 | CPU 温度 | 全量 SMC 传感器：温度（含详细 key）、风扇、电压、电流、功率 |
| 时间 | 时区时钟 | 本地时间 + 自定义额外时区 |

另外：

- **历史曲线**：1 小时 / 24 小时 / 7 天三档，按分钟聚合落盘，重启后仍在
- **阈值告警**：CPU / GPU / 内存 / 磁盘 / 温度 / 电量 / 下行速率，可设阈值、持续秒数、冷却时间，走系统通知
- **进程排行**：按 CPU 或内存排序，受挂起（SIGSTOP）的进程标红
- **暂停监视**：右键菜单可暂停，暂停时状态栏变灰
- 左键点状态栏 → 打开面板；右键 / Control + 左键 → 菜单（暂停、模块勾选、重置流量、设置、关于、退出）
- 支持开机自启、1~10 秒采样间隔、紧凑模式、深色/浅色菜单栏自适应


## 系统要求

- macOS 13 Ventura 及以上
- 构建需要 Xcode 15+ / Swift 5.9+（只在 macOS 上构建，Linux 不行）

## 构建

```bash
git clone https://github.com/Matrix-dk/Matrix.git
cd Matrix

# 方式一：直接跑（开发时最快）
swift run

# 方式二：打成 .app 再运行
make app
open dist/Matrix.app

# 通用二进制（Apple Silicon + Intel）
make universal
```

打包脚本做的事：`swift build -c release` → 组装 `Matrix.app/Contents/{MacOS,Resources}` → 写入 `Info.plist`（`LSUIElement=true`，不进 Dock）→ ad-hoc 签名。

装到「应用程序」：

```bash
make install
```

> **首次打开提示「无法验证开发者」**：右键 → 打开，或执行
> `xattr -dr com.apple.quarantine /Applications/Matrix.app`。
> 开机自启需要 app 在 `/Applications` 下才稳定。

## 目录结构

```
Sources/Matrix/
├── main.swift                    # 入口，NSApplication + accessory 模式
├── AppDelegate.swift
├── Core/
│   ├── Metrics.swift             # 采样数据结构、历史曲线、格式化
│   ├── Sampler.swift             # 采样调度（统一 tick，重活降频）
│   ├── Settings.swift            # 配置项、告警规则，落 UserDefaults
│   ├── HistoryStore.swift        # 分钟级历史落盘 / 1h·24h·7d 序列
│   ├── AlertEngine.swift         # 阈值告警 + 系统通知
│   ├── PublicIPResolver.swift    # 公网 IP（默认关闭）
│   └── LaunchAtLogin.swift       # SMAppService 开机自启
├── Readers/                      # 数据采集，每个模块一个 Reader
│   ├── CPUReader.swift           # host_processor_info + 每核 tick 差值
│   ├── MemoryReader.swift        # vm_statistics64 + 内存压力 + 页面换入换出
│   ├── NetworkReader.swift       # getifaddrs + if_data，按接口分别统计
│   ├── DiskReader.swift          # statfs + 挂载卷枚举 + IOBlockStorageDriver
│   ├── BatteryReader.swift       # IOKit AppleSmartBattery
│   ├── ProcessReader.swift       # ps -Ao pid,pcpu,rss,state,comm
│   ├── GPUReader.swift           # IOAccelerator PerformanceStatistics
│   ├── WiFiReader.swift          # CoreWLAN
│   └── SMCReader.swift           # AppleSMC 全量枚举 + 分类
├── MenuBar/
│   ├── StatusItemController.swift # 每模块一个 status item
│   └── MenuBarRenderer.swift     # Core Graphics 现画状态栏图片
└── UI/
    ├── DashboardView.swift       # 弹窗面板
    ├── SettingsView.swift        # 设置（常规/状态栏/告警/历史）
    └── Components.swift          # 卡片、曲线、圆环、信号条
```

## 实现上几个关键点

1. **CPU 占用必须自己算差值**。`host_processor_info` 返回的是每核累计 tick，不是百分比。Reader 里保存上一次的 `[UInt32]`，用 `&-`（回绕减法）算 delta；计数器是 32 位、长跑会溢出，普通减法会算出负数。
2. **网络计数器是 32 位**。`if_data.ifi_ibytes` 超过 4GB 会回绕，同样用 `&-` 做差值，秒级采样下增量远小于 2^32，结果精确。没用 `NET_RT_IFLIST2` 是为了避免依赖 `if_data64` 的私有布局。
3. **SMC 不碰 Swift struct 内存布局**。直接按 `smc.h` 里 `SMCKeyData_t` 的已知偏移（key@0、keyInfo@28、data8@42、bytes@48）拼 80 字节 buffer，再用 `IOConnectCallStructMethod` 调用。布局一旦对不上就是脏读，这样至少可控。
4. **温度 key 各机型不同**。Intel 是 `TC0P/TC0D`，Apple Silicon 是 `Tp0x` 系列，代码里是一个候选列表，取第一个落在合理区间（15~125°C）的值。
5. **进程排行用 `ps`**。算真实 CPU% 要按 pid 存两次 `rusage` 差值，`ps` 已经做完了；代价是每 3 个采样周期 fork 一次。
6. **状态栏图片非 template**。要显示彩色数值和曲线，所以关掉 template 模式，自己按菜单栏深浅色决定标签颜色，并监听 `AppleInterfaceThemeChangedThemeNotification` 重绘。
7. **CI 用 `macos-latest`**。`macos-14` / `macos-13` 的 runner 镜像已被 GitHub 退役，用它会出现「任务排队即被 cancelled、一个 step 都没跑」的假故障。


## 已知限制

- 传感器覆盖取决于机型：SMC 是**全量枚举**后按 key 前缀和取值范围归类，个别机型可能列出几个无意义的 key（值不像物理量）。CPU 温度按已知 key 优先级挑，挑不到就取最高温。
- Wi-Fi 的 SSID 在 macOS 14+ 需要定位权限，拿不到时显示「需定位权限」而不是瞎填一个；RSSI、信道、协商速率不受影响。
- **没有风扇手动调速**。写 SMC 调风扇有把转速设到 0 的风险，不值得。
- **没有蓝牙/AirPods 电量、天气、日历**。前者依赖 `system_profiler` / 私有 IOBluetooth 属性，输出结构跨版本不稳定；后两者要定位或日历权限，还得接外部服务，跟「本机监视」的定位也不太一致。
- **没有通知中心小部件**。WidgetKit 需要 Xcode 工程和 app extension，SwiftPM 构建不出这个形态。
- 只有 ad-hoc 签名，没有 notarize；分发给别人需要自己的 Developer ID。

## Roadmap

- [ ] 每个模块独立的图标/字体/单位设置（现在样式是全局的）
- [ ] 传感器 key 手动隐藏
- [ ] 磁盘 SMART 健康状态
- [ ] 下拉图配色自定义
- [ ] Sparkle 自动更新

## License

MIT
