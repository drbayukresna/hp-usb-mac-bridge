// SPDX-License-Identifier: GPL-3.0-or-later

import HPUSBBridge
import SwiftUI

struct PrintSetupView: View {
    @EnvironmentObject var model: PrinterModel
    @State private var makeDefault = true
    @State private var printTest = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Printing",
                           subtitle: "Print in full colour from any app, with A4, F4 and photo sizes.")

                stateCard

                Card(title: "What you get", systemImage: "sparkles") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        feature("paintpalette.fill", .pink, "Full colour", "Instead of black and white only")
                        feature("doc.plaintext", .blue, "A4, F4 (8.5×13), Letter, Legal, envelopes", "A4 is the default")
                        feature("photo", .orange, "Photo paper and 4×6 / 5×7 photos", "Choose “Photo Paper” in the Print dialog")
                        feature("dial.high", .green, "Draft to Best quality, up to 1200 dpi", "Draft saves ink for everyday pages")
                    }
                }

                Card(title: "How it works", systemImage: "questionmark.circle") {
                    Text("HP no longer ships a Mac driver for this printer. HP Bridge sets it up with a compatible HP colour driver that macOS already has (HP DeskJet 2640 series), which speaks the printer's native language. Nothing is installed in the background.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
        }
        .onAppear { model.refreshPrintSetup() }
    }

    @ViewBuilder
    private var stateCard: some View {
        switch model.printSetup {
        case .unknown:
            Card { HStack { ProgressView().controlSize(.small); Text("Checking print settings…") } }

        case let .ready(queue, isDefault):
            Card {
                HStack(alignment: .top, spacing: 16) {
                    statusIcon("checkmark.circle.fill", .green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Printing is set up").font(.title3.weight(.semibold))
                        Text("Printer name in the Print dialog: \(queue)")
                            .foregroundStyle(.secondary)
                        if isDefault {
                            Label("This is your default printer", systemImage: "star.fill")
                                .font(.callout).foregroundStyle(.yellow)
                        }
                        HStack {
                            Button { model.printTestPage(queue: queue) } label: {
                                Label("Print a test page", systemImage: "doc.richtext")
                            }
                            Button { model.setUpPrinting(makeDefault: true, printTest: false) } label: {
                                Label("Repair", systemImage: "wrench.and.screwdriver")
                            }
                            .help(Text("Recreate the print queue with the recommended settings"))
                            Button { model.openPrintersSettings() } label: {
                                Label("Printers & Scanners", systemImage: "gearshape")
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }

        case let .limited(queue, driver):
            Card {
                HStack(alignment: .top, spacing: 16) {
                    statusIcon("exclamationmark.triangle.fill", .orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your printer only prints in black and white").font(.title3.weight(.semibold))
                        Text("“\(queue)” uses the “\(driver)” driver: monochrome, 300 dpi, Letter paper.")
                            .foregroundStyle(.secondary)
                        setupControls(primaryTitle: "Switch to colour printing")
                    }
                }
            }

        case .missing:
            Card {
                HStack(alignment: .top, spacing: 16) {
                    statusIcon("printer.fill", .blue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Printing isn't set up yet").font(.title3.weight(.semibold))
                        Text("One click and you can print in colour from any app.")
                            .foregroundStyle(.secondary)
                        setupControls(primaryTitle: "Set up printing")
                    }
                }
            }
        }
    }

    private func setupControls(primaryTitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Make it my default printer", isOn: $makeDefault)
            Toggle("Print a colour test page", isOn: $printTest)
            Button {
                model.setUpPrinting(makeDefault: makeDefault, printTest: printTest)
            } label: {
                HStack {
                    if model.isSettingUpPrint { ProgressView().controlSize(.small) }
                    Text(primaryTitle)
                }
                .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSettingUpPrint || model.device == nil)
        }
        .padding(.top, 6)
    }

    private func statusIcon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 34))
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
    }

    @ViewBuilder
    private func feature(_ icon: String, _ tint: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        GridRow {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
