import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                ForEach(ModuleKind.allCases) { module in
                    Toggle(isOn: binding(for: module)) {
                        Label(module.title, systemImage: module.symbolName)
                    }
                }
            } header: {
                Text("状态栏显示")
            } footer: {
                Text("勾选顺序即显示顺序，新勾选的排在最右。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("刷新间隔", selection: $settings.refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                }
                Toggle("显示迷你曲线", isOn: $settings.showGraphInMenuBar)
                Toggle("紧凑模式（不显示 CPU/MEM 字样）", isOn: $settings.compactMenuBar)
            } header: {
                Text("外观")
            }

            Section {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
            } header: {
                Text("启动")
            } footer: {
                Text("需要 app 已放到「应用程序」目录，开机自启才稳定生效。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
    }

    private func binding(for module: ModuleKind) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarModules.contains(module) },
            set: { isOn in
                if isOn {
                    if !settings.menuBarModules.contains(module) {
                        settings.menuBarModules.append(module)
                    }
                } else {
                    settings.menuBarModules.removeAll { $0 == module }
                }
            }
        )
    }
}
