# hp-usb-mac-bridge

Use **USB-only HP inkjet printers on modern macOS** — without HP software.

HP no longer provides macOS drivers for several USB-only models such as the
**HP Smart Tank 500 series**. HP Smart can't see them, HP Easy Start finds no
software, and macOS falls back to a black-and-white "Generic PCL" driver.

`hpbridge` gives these printers their features back:

| Feature | How | Status |
|---------|-----|--------|
| 🖨️ Colour printing, A4/F4/photo sizes, up to 1200 dpi | Configures CUPS with a compatible PCL3GUI driver | ✅ Verified on Smart Tank 500 |
| 📄 Flatbed scanning to PDF / JPEG, 75–1200 dpi | HP LEDM protocol over USB | ✅ Verified on Smart Tank 500 |
| 🔋 Printer status, ink tanks and printheads | HP LEDM | ✅ Verified on Smart Tank 500 |
| 🧽 Printhead cleaning (3 levels), quality / diagnostics reports | HP LEDM internal print jobs | ✅ Cleaning verified on Smart Tank 500 |

Read [docs/FINDINGS.md](docs/FINDINGS.md) for the full investigation: why
AirPrint over USB is impossible on this printer, what failed, and what works.

## Requirements

* macOS 13 or newer (Apple Silicon or Intel)
* Swift 5.9+ (Xcode or the Command Line Tools: `xcode-select --install`)
* For printing: Rosetta 2 on Apple Silicon and HP's PPD files in
  `/Library/Printers/PPDs/Contents/Resources` (from Apple's HP Printer Drivers
  package)

## Install

```sh
git clone https://github.com/<owner>/hp-usb-mac-bridge.git
cd hp-usb-mac-bridge
scripts/install.sh          # installs to ~/.local/bin/hpbridge
```

## Usage

```sh
hpbridge devices                       # is the printer visible?
hpbridge setup-print --test            # create a colour print queue + test page
hpbridge status                        # ready? paper jam? ink alerts?
hpbridge ink                           # estimated ink levels
hpbridge scan                          # A4 colour 300 dpi -> ~/Desktop/Scan <date>.pdf
hpbridge scan --gray --dpi 200 --pages 5 -o contract.pdf
hpbridge scan --paper 4x6 --dpi 600 --photo -o photo.jpg
hpbridge info                          # model, product number, firmware
hpbridge clean                         # printhead cleaning, level 1 (2 and 3 are deeper)
hpbridge maintenance pq-report         # print-quality diagnostics page
hpbridge maintenance verify-clean      # cleaning verification page
```

Add `-v` to any command to see the USB/HTTP conversation.

### Tips for ink-tank printers

* Run one cleaning, then print `maintenance pq-report`. Repeat at most 2–3
  times; every cycle uses ink.
* Print one colour page a week to keep the nozzles from drying out.
* Ink percentages are estimates — the tank windows show the real level.

## Supported printers

| Printer | USB ID | Print | Scan / status / maintenance |
|---------|--------|-------|-----------------------------|
| HP Smart Tank 500 series | 03f0:2b54 | ✅ | ✅ |

Other HP inkjets whose device ID lists `PCL3GUI` and `LEDMDIS:USB#...` are
likely to work. `hpbridge setup-print --ppd <file>` lets you try another PPD.
Please report results!

## Development

```sh
swift build
scripts/test.sh              # unit tests, no printer needed
.build/debug/hpbridge -v discover
```

Project layout:

```
Sources/HPUSBBridge/
  USBTransport.swift    bulk I/O on a vendor USB interface (IOUSBHost)
  HTTPOverUSB.swift     HTTP/1.1 client + incremental response parser
  LEDMClient.swift      status, ink, product info, maintenance jobs
  Scan.swift            LEDM scan jobs
  PDFWriter.swift       JPEG pages -> PDF
  PrintSetup.swift      CUPS queue creation
Sources/hpbridge/       command line tool
Tests/                  unit tests with representative LEDM documents
docs/FINDINGS.md        protocol and driver research
```

See [CONTRIBUTING.md](CONTRIBUTING.md) — testing on real printers is the most
valuable contribution right now.

## Ringkasan (Bahasa Indonesia)

`hpbridge` membuat printer HP yang hanya punya koneksi USB, seperti **HP Smart
Tank 500**, bisa dipakai penuh di macOS tanpa software HP: cetak berwarna
, scan ke PDF/JPEG, serta status printer dan tinta (semuanya sudah diuji di
printer asli). Pembersihan printhead juga sudah teruji. Jalankan
`hpbridge setup-print --test` untuk mulai mencetak.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by HP Inc. "HP" and "Smart
Tank" are trademarks of HP Inc., used here only to identify compatible
hardware.
