// SPDX-License-Identifier: GPL-3.0-or-later
//
// HP Bridge — a Mac app for USB-only HP printers that HP no longer supports.

import AppKit
import HPUSBBridge
import SwiftUI


struct HPBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = PrinterModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
                .task { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Printer") {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("Scan") { Task { await model.scan() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isBusy || model.device == nil)
            }
            CommandGroup(replacing: .help) {
                Link("HP Bridge on GitHub", destination: URL(string: "https://github.com/drbayukresna/hp-usb-mac-bridge")!)
                Link("Report a problem", destination: URL(string: "https://github.com/drbayukresna/hp-usb-mac-bridge/issues/new")!)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is launched outside an .app bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Section: String, Hashable, CaseIterable, Identifiable {
    case overview, scan, print, maintenance
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Overview"
        case .scan: return "Scan"
        case .print: return "Printing"
        case .maintenance: return "Maintenance"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .scan: return "doc.viewfinder"
        case .print: return "printer"
        case .maintenance: return "wand.and.stars"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: PrinterModel
    @State private var selection: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { connectionFooter }
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    if model.device == nil {
                        NotConnectedView(searching: model.connection == .searching)
                    } else {
                        switch selection ?? .overview {
                        case .overview: OverviewView(selection: $selection)
                        case .scan: ScanView()
                        case .print: PrintSetupView()
                        case .maintenance: MaintenanceView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)

                if let banner = model.banner {
                    BannerView(banner: banner) { withAnimation { model.banner = nil } }
                        .id(banner.id)
                        .task(id: banner.id) {
                            try? await Task.sleep(for: .seconds(banner.isError ? 12 : 6))
                            withAnimation { if model.banner?.id == banner.id { model.banner = nil } }
                        }
                }
            }
            .animation(.spring(duration: 0.35), value: model.banner)
            .animation(.easeInOut(duration: 0.25), value: selection)
            .animation(.easeInOut(duration: 0.3), value: model.connection)
        }
        .navigationTitle("HP Bridge")
    }

    private var connectionFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.device == nil ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.device == nil ? "Not connected" : "Connected via USB")
                    .font(.caption.weight(.medium))
                if let d = model.device {
                    Text(d.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}
