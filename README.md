# hp-usb-mac-bridge

Use **USB-only HP inkjet printers on modern macOS** — without HP software.

HP no longer provides macOS drivers for several USB-only models such as the
**HP Smart Tank 500 series**. HP Smart can't see them, HP Easy Start finds no
software, and macOS falls back to a black-and-white "Generic PCL" driver.

**HP Bridge** (a Mac app) and `hpbridge` (its command-line twin) give these
printers their features back:

| Feature | How | Status |
|---------|-----|--------|
| 🖨️ Colour printing, A4/F4/photo sizes, up to 1200 dpi | Configures CUPS with a compatible PCL3GUI driver | ✅ Verified on Smart Tank 500 |
| 📄 Flatbed scanning to PDF / JPEG, 75–1200 dpi | HP LEDM protocol over USB | ✅ Verified on Smart Tank 500 |
| 🔋 Printer status, ink tanks and printheads | HP LEDM | ✅ Verified on Smart Tank 500 |
| 🧽 Printhead cleaning (3 levels), quality / diagnostics reports | HP LEDM internal print jobs | ✅ Cleaning verified on Smart Tank 500 |

Read [docs/FINDINGS.md](docs/FINDINGS.md) for the full investigation: why
AirPrint over USB is impossible on this printer, what failed, and what works.

## The gap it fills in the ecosystem

**Working printers, no supported way to use them from a Mac.** Low-cost
USB-only inkjets such as the HP Smart Tank 500 series are common in homes,
schools and small offices. On current macOS every official path is closed:

* **HP Smart** only discovers networked/AirPrint printers, so a USB-only
  model never appears.
* **HP Easy Start** reports that no software is available for the product.
* **Apple's "HP Printer Drivers" package** refuses to install on macOS newer
  than 15, and never included these models anyway.

**AirPrint is not a fallback here.** Driverless printing over USB needs an
IPP-over-USB interface, which these printers don't have. macOS therefore
falls back to *Generic PCL Laser Printer*: black and white, 300 dpi, Letter
paper, no scanning, no ink status, no maintenance.

**Linux solved this years ago; macOS never got an equivalent.** On Linux,
HP's open-source HPLIP drives these printers natively: printing through
`hpcups`, and scanning and status over HP's LEDM web services on the USB
cable. HPLIP is Linux-only, and nothing on macOS speaks LEDM over USB. Mac
owners are left choosing between a crippled black-and-white printer, keeping
a Windows PC around, or replacing hardware that still works.

**What this project adds:**

* **Colour printing** by pairing the printer with a PCL3GUI renderer macOS
  already ships, instead of inventing a new driver.
* **Scanning, ink and printhead status, and cleaning** by speaking LEDM
  directly over USB from an ordinary app — no kernel extension, no root, no
  HP software, no background daemon.
* **A plain Mac app** for people who never want to open Terminal, plus a CLI
  and a Swift library for scripts and other projects.
* **Documented findings** ([docs/FINDINGS.md](docs/FINDINGS.md)) — device
  IDs, USB interfaces, LEDM endpoints, and the approaches that do *not* work —
  so support for more models can be added by others.

**What it is not:** an HP product, a replacement for HP's software on printers
HP still supports, or a way around anything HP or Apple restricts. It uses
public interfaces the printer itself advertises.

## Download the app (no coding needed)

1. Download **HP-Bridge-x.y.z.dmg** from the
   [Releases](https://github.com/drbayukresna/hp-usb-mac-bridge/releases) page.
2. Open it and drag **HP Bridge** into **Applications**.
3. The first time, right-click **HP Bridge** → **Open** → **Open**. (The app
   isn't notarized by Apple yet, so macOS asks once.)
4. Plug in the printer. HP Bridge finds it automatically.

| Section | What you can do |
|---------|-----------------|
| **Overview** | Live printer state, animated ink-tank levels, printhead health, model and firmware |
| **Scan** | Document / Photo / Small-file presets, colour or B&W, A4–photo sizes, 150–1200 dpi; scan several pages, reorder or remove them, save as one PDF or as JPEGs, drag pages into other apps |
| **Printing** | Detects a black-and-white "Generic" setup and switches it to colour in one click, prints a test page |
| **Maintenance** | Guided steps, three cleaning levels with confirmation, quality and diagnostics reports, live progress |

The app is available in English and Bahasa Indonesia and follows your Mac's
language. It needs macOS 14 Sonoma or newer on an Apple Silicon Mac (an Intel
build is planned).

## Requirements (command line / building from source)

* macOS 14 or newer
* Swift 5.9+ (Xcode or the Command Line Tools: `xcode-select --install`)
* For printing: Rosetta 2 on Apple Silicon and HP's PPD files in
  `/Library/Printers/PPDs/Contents/Resources` (from Apple's HP Printer Drivers
  package — see [Installing the print driver](#installing-the-print-driver))

## Installing the print driver

Colour printing uses HP's PCL3GUI driver from Apple's **HP Printer Drivers
5.1.1** package. It is needed once per Mac, together with Rosetta 2 on Apple
Silicon (HP's print filters are Intel-only):

```sh
softwareupdate --install-rosetta --agree-to-license   # Apple Silicon only
```

Download `HewlettPackardPrinterDrivers.dmg` from
[Apple's support page](https://support.apple.com/en-us/106385).

**macOS 15 and older:** open the DMG and run the installer.

**macOS newer than 15:** the installer stops with *"This update requires
macOS version 15.0 or earlier."* That is only a version check in the package;
the driver itself still works (verified printing in colour on macOS 27.2).
Copy the print-driver part of the package by hand:

```sh
hdiutil attach -nobrowse ~/Downloads/HewlettPackardPrinterDrivers.dmg
pkgutil --check-signature /Volumes/HP_PrinterSupportManual/HewlettPackardPrinterDrivers.pkg   # expect "signed Apple Software"
pkgutil --expand-full /Volumes/HP_PrinterSupportManual/HewlettPackardPrinterDrivers.pkg /tmp/hpdrivers
sudo ditto /tmp/hpdrivers/HewlettPackardPrinterDrivers.pkg/Payload/Library/Printers/PPDs /Library/Printers/PPDs
sudo ditto /tmp/hpdrivers/HewlettPackardPrinterDrivers.pkg/Payload/Library/Printers/hp /Library/Printers/hp
sudo chown -R root:wheel /Library/Printers/PPDs /Library/Printers/hp
hdiutil detach /Volumes/HP_PrinterSupportManual && rm -rf /tmp/hpdrivers
```

This copies only the printer drivers. The package's kernel extension, Image
Capture plug-ins and `/usr/libexec` files are not installed and are not
needed. To remove the driver later, delete `/Library/Printers/hp`.

Then run `hpbridge setup-print --test`, or use **Printing** in the app.

## Install the command-line tool

```sh
git clone https://github.com/drbayukresna/hp-usb-mac-bridge.git
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
scripts/build-app.sh         # dist/HP Bridge.app + dist/HP-Bridge-<version>.dmg
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
Sources/HPBridgeApp/    the SwiftUI Mac app
AppBundle/              app icon and translations (en, id)
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
`hpbridge setup-print --test` untuk mulai mencetak. Di macOS di atas 15,
installer driver HP dari Apple menolak dipasang; ikuti langkah salin manual di
[Installing the print driver](#installing-the-print-driver).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by HP Inc. "HP" and "Smart
Tank" are trademarks of HP Inc., used here only to identify compatible
hardware.
