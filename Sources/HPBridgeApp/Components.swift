// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared visual building blocks.

import HPUSBBridge
import SwiftUI

// MARK: - Card

struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }
}

// MARK: - Page header

struct PageHeader: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    var text: String
    var color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(pulsing && pulse ? 1.5 : 1)
                .opacity(pulsing && pulse ? 0.5 : 1)
                .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
        .onAppear { pulse = true }
    }
}

extension PrinterStatus {
    var displayText: String {
        switch category.lowercased() {
        case "ready": return String(localized: "Ready")
        case "processing": return String(localized: "Working…")
        case "scanprocessing", "scanning": return String(localized: "Scanning…")
        case "inpowersave", "powersave": return String(localized: "Sleeping")
        case "inkSystemFailure".lowercased(): return String(localized: "Ink system problem")
        default: return category
        }
    }

    var color: Color {
        switch category.lowercased() {
        case "ready", "inpowersave", "powersave": return .green
        case "processing", "scanprocessing", "scanning": return .blue
        default: return alerts.isEmpty ? .orange : .red
        }
    }
}

// MARK: - Ink tank gauge

extension Consumable {
    var tint: Color {
        switch label.uppercased() {
        case "C": return Color(red: 0.0, green: 0.68, blue: 0.94)
        case "M": return Color(red: 0.93, green: 0.0, blue: 0.55)
        case "Y": return Color(red: 1.0, green: 0.84, blue: 0.0)
        case "K": return Color(white: 0.15)
        default: return .gray
        }
    }

    var localizedColor: String {
        switch label.uppercased() {
        case "C": return String(localized: "Cyan")
        case "M": return String(localized: "Magenta")
        case "Y": return String(localized: "Yellow")
        case "K": return String(localized: "Black")
        case "CMY": return String(localized: "Tri-color")
        default: return color
        }
    }
}

struct InkTankGauge: View {
    var consumable: Consumable
    @State private var shown = false

    private var fraction: Double { Double(consumable.percentRemaining ?? 0) / 100 }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(colors: [consumable.tint.opacity(0.75), consumable.tint],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: shown ? max(6, 120 * fraction) : 0)
                // Glass highlight
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                // Level ticks
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in
                        Spacer()
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1).padding(.horizontal, 10)
                    }
                    Spacer()
                }
            }
            .frame(width: 54, height: 120)
            .shadow(color: consumable.tint.opacity(0.25), radius: 8, y: 4)
            .animation(.spring(duration: 1.0, bounce: 0.25), value: shown)
            .onAppear { shown = true }
            .help(Text("Estimated level. Check the tank window for the real level."))

            VStack(spacing: 2) {
                Text(consumable.localizedColor).font(.callout.weight(.medium))
                Text(consumable.percentRemaining.map { "\($0)%" } ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(consumable.localizedColor) ink, about \(consumable.percentRemaining ?? 0) percent"))
    }
}

// MARK: - Banner (toast)

struct BannerView: View {
    var banner: PrinterModel.Banner
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(banner.isError ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.headline)
                Text(banner.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .help(Text("Dismiss"))
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Not connected

struct NotConnectedView: View {
    var searching: Bool
    @State private var bob = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "printer.dotmatrix")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
                .offset(y: bob ? -4 : 4)
                .animation(.easeInOut(duration: 1.6).repeatForever(), value: bob)
                .onAppear { bob = true }
            Text(searching ? "Looking for your printer…" : "No printer connected")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label("Switch the printer on", systemImage: "power")
                Label("Connect it to this Mac with a USB cable", systemImage: "cable.connector")
                Label("Wait a few seconds — it appears here automatically", systemImage: "sparkles")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
