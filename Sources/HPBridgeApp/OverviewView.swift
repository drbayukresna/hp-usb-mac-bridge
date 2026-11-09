// SPDX-License-Identifier: GPL-3.0-or-later

import HPUSBBridge
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: PrinterModel
    @Binding var selection: Section?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                Card(title: "Ink", systemImage: "drop.fill") {
                    if model.inks.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        HStack(alignment: .bottom, spacing: 26) {
                            ForEach(model.inks, id: \.label) { InkTankGauge(consumable: $0) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        Text("Ink-tank printers can't measure the tanks; levels are estimates reset at each refill. The tank windows show the real level.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 20) {
                    Card(title: "Printheads", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                        ForEach(model.printheads, id: \.label) { head in
                            HStack {
                                Circle()
                                    .fill(head.label == "K"
                                          ? AnyShapeStyle(Color(white: 0.15))
                                          : AnyShapeStyle(AngularGradient(colors: [.cyan, .pink, .yellow, .cyan], center: .center)))
                                    .frame(width: 14, height: 14)
                                Text(head.localizedColor)
                                Spacer()
                                Text(head.stateDescription.map { LocalizedStringKey($0) } ?? "Unknown")
                                    .foregroundStyle(.secondary)
                                if let part = head.partNumber {
                                    Text(part).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if model.printheads.isEmpty { Text("—").foregroundStyle(.secondary) }
                    }

                    Card(title: "Quick actions", systemImage: "bolt.fill") {
                        QuickAction(title: "Scan a document", icon: "doc.viewfinder", tint: .blue) {
                            selection = .scan
                        }
                        QuickAction(title: "Set up printing", icon: "printer.fill", tint: .indigo) {
                            selection = .print
                        }
                        QuickAction(title: "Fix faded or streaky prints", icon: "wand.and.stars", tint: .orange) {
                            selection = .maintenance
                        }
                    }
                }

                if let info = model.info {
                    Card(title: "About this printer", systemImage: "info.circle") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            row("Model", info.makeAndModel)
                            row("Product number", info.productNumber)
                            row("Firmware", [info.firmware, info.firmwareDate.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                            row("Serial number", info.serialNumber)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(28)
        }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.blue.opacity(0.85), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "printer.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: model.lastUpdated)
            }
            .frame(width: 76, height: 76)
            .shadow(color: .indigo.opacity(0.35), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.info?.makeAndModel.map { "HP \($0)" } ?? model.device?.name ?? "HP")
                    .font(.title.weight(.semibold))
                HStack(spacing: 10) {
                    if let status = model.status {
                        StatusPill(text: status.displayText, color: status.color,
                                   pulsing: !status.isReady)
                    } else {
                        StatusPill(text: String(localized: "Connecting…"), color: .gray, pulsing: true)
                    }
                    Label("USB", systemImage: "cable.connector").font(.callout).foregroundStyle(.secondary)
                }
                if let alerts = model.status?.alerts, !alerts.isEmpty {
                    ForEach(alerts, id: \.id) { alert in
                        Label(alert.id, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                    .animation(model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: model.isRefreshing)
            }
            .controlSize(.large)
            .disabled(model.isRefreshing)
            .keyboardShortcut("r")
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").textSelection(.enabled)
        }
    }
}

struct QuickAction: View {
    var title: LocalizedStringKey
    var icon: String
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: hovering ? 3 : 0)
            }
            .padding(8)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
