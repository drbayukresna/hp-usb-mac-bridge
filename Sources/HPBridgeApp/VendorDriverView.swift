// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shown for printers whose maker still ships a macOS driver (Epson): HP Bridge
// reads their status, and points to the maker's own tools for everything else.

import AppKit
import SwiftUI

struct VendorDriverView: View {
    @EnvironmentObject var model: PrinterModel
    var section: Section

    private var hasEpsonScan: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Epson Software/Epson Scan 2.app")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: section.title,
                           subtitle: "This printer works with Epson's own Mac driver.")
                Card {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(headline).font(.title3.weight(.semibold))
                            Text(detail).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                switch section {
                                case .scan:
                                    if hasEpsonScan {
                                        Button { model.openApp(at: "/Applications/Epson Software/Epson Scan 2.app") } label: {
                                            Label("Open Epson Scan 2", systemImage: "doc.viewfinder")
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    Button { model.openApp(at: "/System/Applications/Image Capture.app") } label: {
                                        Label("Open Image Capture", systemImage: "camera.viewfinder")
                                    }
                                default:
                                    Button { model.openPrintersSettings() } label: {
                                        Label("Printers & Scanners", systemImage: "gearshape")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .controlSize(.large)
                            .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var headline: LocalizedStringKey {
        switch section {
        case .scan: return "Scan with Epson Scan 2 or Image Capture"
        case .maintenance: return "Nozzle check and head cleaning are in Printers & Scanners"
        default: return "Print from any app"
        }
    }

    private var detail: LocalizedStringKey {
        switch section {
        case .scan: return "Epson still supports this printer on macOS, so HP Bridge doesn't replace its scanner software."
        case .maintenance: return "Open Printers & Scanners, choose the printer, then Options & Supplies → Utility → Open Printer Utility."
        default: return "macOS sets this printer up automatically when it is plugged in. If it is missing, add it in Printers & Scanners."
        }
    }
}
