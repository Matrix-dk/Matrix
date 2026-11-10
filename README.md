# Matrix

macOS 菜单栏系统监视器，类似 iStat Menus 的轻量实现。纯 Swift + SwiftUI + AppKit，没有第三方依赖，不需要 Xcode 工程文件，`swift build` 就能出包。

## 功能

菜单栏常驻，可选显示：

| 模块 | 状态栏显示 | 弹窗面板 |
| --- | --- | --- |
| CPU | 总占用百分比 + 迷你曲线 | 每核占用柱状图、用户/系统占比、1/5/15 分钟负载、开机时长 |
| 内存 | 占用百分比 + 迷你曲线 | App/联动/压缩/缓存/交换空间明细 |
| 网络 | ↓下行 ↑上行实时速率 + 曲线 | 上下行速率、本次开机累计流量、主接口与 IP |
| 磁盘 | 根分区占用百分比 | 容量、实时读写速率 |
| 电池 | 电量百分比 | 充放电状态、剩余时间、循环次数、健康度、温度 |
| 传感器 | CPU 温度 | 温度、风扇转速（走 SMC，部分机型不支持） |

另外面板底部有「占用最高的进程」列表（CPU 排序前 6）。

- 左键点状态栏 → 打开面板；右键 / Control + 左键 → 菜单（设置、关于、退出）
- 支持开机自启、1~5 秒采样间隔、紧凑模式、深色/浅色菜单栏自适应

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
│   ├── Settings.swift            # 配置项，落 UserDefaults
│   └── LaunchAtLogin.swift       # SMAppService 开机自启
├── Readers/                      # 数据采集，每个模块一个 Reader
│   ├── CPUReader.swift           # host_processor_info + 每核 tick 差值
│   ├── MemoryReader.swift        # host_statistics64 / vm_statistics64
│   ├── NetworkReader.swift       # getifaddrs + if_data 计数器
│   ├── DiskReader.swift          # statfs + IOKit IOBlockStorageDriver
│   ├── BatteryReader.swift       # IOPowerSources + AppleSmartBattery
│   ├── ProcessReader.swift       # ps -Ao pid,pcpu,rss,comm
│   └── SMCReader.swift           # IOKit AppleSMC 读温度/风扇
├── MenuBar/
│   ├── StatusItemController.swift
│   └── MenuBarRenderer.swift     # 用 Core Graphics 现画状态栏图片
└── UI/
    ├── DashboardView.swift       # 弹窗面板
    ├── SettingsView.swift
    └── Components.swift          # 卡片、曲线、进度条、每核柱状图
```

## 实现上几个关键点

1. **CPU 占用必须自己算差值**。`host_processor_info` 返回的是每核累计 tick，不是百分比。Reader 里保存上一次的 `[UInt32]`，用 `&-`（回绕减法）算 delta；计数器是 32 位、长跑会溢出，普通减法会算出负数。
2. **网络计数器是 32 位**。`if_data.ifi_ibytes` 超过 4GB 会回绕，同样用 `&-` 做差值，秒级采样下增量远小于 2^32，结果精确。没用 `NET_RT_IFLIST2` 是为了避免依赖 `if_data64` 的私有布局。
3. **SMC 不碰 Swift struct 内存布局**。直接按 `smc.h` 里 `SMCKeyData_t` 的已知偏移（key@0、keyInfo@28、data8@42、bytes@48）拼 80 字节 buffer，再用 `IOConnectCallStructMethod` 调用。布局一旦对不上就是脏读，这样至少可控。
4. **温度 key 各机型不同**。Intel 是 `TC0P/TC0D`，Apple Silicon 是 `Tp0x` 系列，代码里是一个候选列表，取第一个落在合理区间（15~125°C）的值。
5. **进程排行用 `ps`**。算真实 CPU% 要按 pid 存两次 `rusage` 差值，`ps` 已经做完了；代价是每 3 个采样周期 fork 一次。
6. **状态栏图片非 template**。要显示彩色数值和曲线，所以关掉 template 模式，自己按菜单栏深浅色决定标签颜色，并监听 `AppleInterfaceThemeChangedThemeNotification` 重绘。

## 已知限制

- Apple Silicon 上部分机型的 CPU 温度 key 与 Intel 完全不同，SMC 可能读不到温度（会显示「—」而不是瞎报一个值）。
- 状态栏是单一 item，所有模块拼在一条里，不支持每个模块独立成项。
- 没有 GPU、风扇手动控制、天气日历这类 iStat 的扩展功能。
- 只有 ad-hoc 签名，没有 notarize；分发给别人需要自己的 Developer ID。

## Roadmap

- [ ] 每个模块独立状态栏 item + 拖拽排序
- [ ] GPU 占用（IOAccelerator）
- [ ] 传感器 key 按机型自适应（M 系列补全）
- [ ] 历史数据落盘 + 长周期图表
- [ ] Sparkle 自动更新

## License

MIT
