// SPDX-License-Identifier: GPL-3.0-or-later

import HPUSBBridge
import SwiftUI
import UniformTypeIdentifiers

struct ScanView: View {
    @EnvironmentObject var model: PrinterModel

    var body: some View {
        HStack(spacing: 0) {
            settings
                .frame(width: 290)
                .background(.background.secondary)
            Divider()
            pagesArea
        }
    }

    // MARK: Settings column

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan").font(.largeTitle.weight(.semibold))
                    Text("Place the page face down on the glass, top edge at the arrow.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                SettingGroup(title: "Purpose") {
                    Picker("", selection: preset) {
                        Text("Document").tag(Preset.document)
                        Text("Photo").tag(Preset.photo)
                        Text("Small file").tag(Preset.small)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingGroup(title: "Colour") {
                    Picker("", selection: $model.scanOptions.colorMode) {
                        Label("Colour", systemImage: "paintpalette").tag(ScanColorMode.color)
                        Label("Black & white", systemImage: "circle.lefthalf.filled").tag(ScanColorMode.gray)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                SettingGroup(title: "Paper size") {
                    Picker("", selection: $model.scanOptions.paper) {
                        Text("A4").tag(ScanPaper.a4)
                        Text("Letter").tag(ScanPaper.letter)
                        Text("A5").tag(ScanPaper.a5)
                        Text("Photo 4×6 in").tag(ScanPaper.photo4x6)
                        Text("Photo 5×7 in").tag(ScanPaper.photo5x7)
                        Text("Whole glass").tag(ScanPaper.max)
                    }
                    .labelsHidden()
                }

                SettingGroup(title: "Quality") {
                    Picker("", selection: $model.scanOptions.resolution) {
                        Text("Draft · 150 dpi").tag(150)
                        Text("Standard · 300 dpi").tag(300)
                        Text("High · 600 dpi").tag(600)
                        Text("Maximum · 1200 dpi").tag(1200)
                    }
                    .labelsHidden()
                    if model.scanOptions.resolution >= 600 {
                        Label("Higher quality takes longer and makes bigger files.", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    Task { await model.scan() }
                } label: {
                    HStack {
                        if model.isScanning {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "doc.viewfinder")
                        }
                        Text(model.isScanning ? LocalizedStringKey(model.scanStep ?? "Scanning…")
                                              : (model.pages.isEmpty ? "Scan" : "Scan another page"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy || model.device == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(22)
            .animation(.easeInOut, value: model.scanOptions.resolution)
        }
    }

    // MARK: Pages

    private var pagesArea: some View {
        VStack(spacing: 0) {
            if model.pages.isEmpty && !model.isScanning {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 22)], spacing: 22) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                            PageThumb(page: page, number: index + 1, count: model.pages.count)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        if model.isScanning {
                            ScanningPlaceholder(step: model.scanStep)
                                .transition(.opacity)
                        }
                    }
                    .padding(26)
                }
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Your scanned pages appear here").font(.title3.weight(.medium))
            Text("Scan several pages and save them together as one PDF.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(model.pages.count) page(s)").foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                withAnimation { model.pages.removeAll() }
            } label: { Label("Clear", systemImage: "trash") }
                .disabled(model.isScanning)
            Button { model.saveImages() } label: { Label("Save as JPEG", systemImage: "photo") }
            Button { model.savePDF() } label: { Label("Save as PDF", systemImage: "doc.richtext") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Presets

    private enum Preset: Hashable { case document, photo, small, custom }

    private var preset: Binding<Preset> {
        Binding {
            let o = model.scanOptions
            switch (o.contentType, o.resolution) {
            case ("Photo", 600): return .photo
            case ("Document", 150): return .small
            case ("Document", 300): return .document
            default: return .custom
            }
        } set: { p in
            withAnimation {
                switch p {
                case .document: model.scanOptions.contentType = "Document"; model.scanOptions.resolution = 300
                case .photo:
                    model.scanOptions.contentType = "Photo"; model.scanOptions.resolution = 600
                    model.scanOptions.colorMode = .color
                case .small: model.scanOptions.contentType = "Document"; model.scanOptions.resolution = 150
                case .custom: break
                }
            }
        }
    }
}

private struct SettingGroup<Content: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct PageThumb: View {
    @EnvironmentObject var model: PrinterModel
    var page: ScannedPage
    var number: Int
    var count: Int
    @State private var hovering = false
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: page.image)
                .resizable()
                .scaledToFit()
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.03 : 1)
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        HStack(spacing: 4) {
                            iconButton("chevron.left", help: "Move earlier") { model.movePage(page, by: -1) }
                                .disabled(number == 1)
                            iconButton("chevron.right", help: "Move later") { model.movePage(page, by: 1) }
                                .disabled(number == count)
                            iconButton("trash", help: "Remove page") { model.removePage(page) }
                        }
                        .padding(6)
                        .transition(.opacity)
                    }
                }
                .onTapGesture(count: 2) { showPreview = true }
                .onDrag { NSItemProvider(item: page.jpeg as NSData, typeIdentifier: UTType.jpeg.identifier) }
                .help(Text("Double-click to enlarge. Drag to put the image in another app."))
            Text("Page \(number)").font(.callout).foregroundStyle(.secondary)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
        .sheet(isPresented: $showPreview) {
            VStack(spacing: 0) {
                Image(nsImage: page.image).resizable().scaledToFit().padding()
                Divider()
                HStack {
                    Text("Page \(number) · \(page.dpi) dpi").foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { showPreview = false }.keyboardShortcut(.cancelAction)
                }
                .padding()
            }
            .frame(minWidth: 560, minHeight: 720)
        }
    }

    private func iconButton(_ name: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }
}

private struct ScanningPlaceholder: View {
    var step: String?
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white)
                    .aspectRatio(210 / 297, contentMode: .fit)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .blue.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 26)
                        .offset(y: sweep ? geo.size.height - 26 : 0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(), value: sweep)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .onAppear { sweep = true }
            Text(LocalizedStringKey(step ?? "Scanning…")).font(.callout).foregroundStyle(.secondary)
        }
    }
}
