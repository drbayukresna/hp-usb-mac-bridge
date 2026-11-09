// SPDX-License-Identifier: GPL-3.0-or-later

import HPUSBBridge
import SwiftUI

struct MaintenanceView: View {
    @EnvironmentObject var model: PrinterModel
    @State private var confirm: InternalPrintJob?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Maintenance",
                           subtitle: "Fix faded colours, streaks or missing dots.")

                if let running = model.maintenanceRunning {
                    RunningCard(job: running, status: model.status)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Card(title: "Recommended steps", systemImage: "list.number") {
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "Print a quality report to see which colours have gaps.")
                        step(2, "Run a standard cleaning, then print the report again.")
                        step(3, "Still gaps? Try a deep cleaning. Stop after 2–3 cleanings in a row and let the printer rest for a few hours.")
                    }
                    .font(.callout)
                }

                Text("Cleaning").font(.title2.weight(.semibold))
                HStack(spacing: 16) {
                    JobTile(job: .cleaning, icon: "drop", tint: .blue,
                            detail: "About 1½ minutes · uses a little ink", confirm: $confirm)
                    JobTile(job: .cleaningLevel2, icon: "drop.halffull", tint: .indigo,
                            detail: "Use if the standard cleaning wasn't enough · uses more ink", confirm: $confirm)
                    JobTile(job: .cleaningLevel3, icon: "drop.fill", tint: .purple,
                            detail: "Last resort · uses the most ink", confirm: $confirm)
                }

                Text("Reports").font(.title2.weight(.semibold))
                HStack(spacing: 16) {
                    JobTile(job: .printQualityDiagnostics, icon: "chart.bar.doc.horizontal", tint: .teal,
                            detail: "Colour blocks that show nozzle gaps", confirm: $confirm)
                    JobTile(job: .cleaningVerification, icon: "checklist", tint: .green,
                            detail: "Check the result of a cleaning", confirm: $confirm)
                    JobTile(job: .diagnostics, icon: "stethoscope", tint: .orange,
                            detail: "Detailed printer health", confirm: $confirm)
                }
            }
            .padding(28)
            .animation(.spring(duration: 0.4), value: model.maintenanceRunning)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let job = confirm {
                Button(job.isCleaning ? "Start cleaning" : "Print") {
                    Task { await model.run(job) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(confirm?.isCleaning == true
                 ? "Make sure the printer is on and has plain paper loaded. The printer is busy until it finishes."
                 : "Load plain A4 or Letter paper.")
        }
    }

    private var confirmTitle: Text {
        Text(confirm?.localizedName ?? "")
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(.tint.opacity(0.18), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension InternalPrintJob {
    var isCleaning: Bool {
        self == .cleaning || self == .cleaningLevel2 || self == .cleaningLevel3
    }
}

private struct JobTile: View {
    @EnvironmentObject var model: PrinterModel
    var job: InternalPrintJob
    var icon: String
    var tint: Color
    var detail: LocalizedStringKey
    @Binding var confirm: InternalPrintJob?
    @State private var hovering = false

    private var supported: Bool { model.supportedJobs.isEmpty || model.supportedJobs.contains(job.rawValue) }

    var body: some View {
        Button { confirm = job } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(job.localizedName).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.7) : Color.secondary.opacity(0.2), lineWidth: hovering ? 1.5 : 0.5)
            )
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || model.device == nil || !supported)
        .opacity(supported ? 1 : 0.4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(supported ? Text(job.localizedName) : Text("This printer doesn't offer this over USB"))
    }
}

private struct RunningCard: View {
    var job: InternalPrintJob
    var status: PrinterStatus?
    @State private var start = Date()

    var body: some View {
        Card {
            HStack(spacing: 16) {
                ProgressView().controlSize(.large)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.localizedName).font(.title3.weight(.semibold))
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        let s = Int(context.date.timeIntervalSince(start))
                        let state = status?.displayText ?? String(localized: "Working…")
                        let clock = String(format: "%d:%02d", s / 60, s % 60)
                        Text(verbatim: "\(state) · \(clock)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Keep the printer on and the cable connected.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
