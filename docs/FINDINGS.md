# Findings: HP Smart Tank 500 series on macOS

This is the investigation that led to this project, written down so that
others can repeat it for their own USB-only HP printer.

Test machine: Apple Silicon Mac, macOS 27.2, CUPS 2.3.4.
Printer: HP Smart Tank 500 All-in-One (4SR29A), USB only, USB ID `03f0:2b54`.

## 1. HP no longer ships a macOS driver for it

* **HP Smart** (Mac App Store) only lists network/AirPrint printers; the USB
  Smart Tank 500 never appears.
* **HP Easy Start 2.16.7** (signed, notarized, from `ftp.hp.com`) reports
  *"We were not able to automatically locate any software options for this
  product."*
* Apple's **HP Printer Drivers 5.1.1** package refuses to install on macOS
  newer than 15.0 (`InstallationCheck` in its Distribution script), and has no
  Smart Tank PPD anyway.
* macOS's fallback, **Generic PCL Laser Printer**, prints monochrome only at
  300 dpi with Letter as default paper.

## 2. What the printer says about itself

IEEE-1284 device ID (`lpinfo -l -v`):

```
MFG:HP;MDL:Smart Tank 500 series;
CMD:PCL3GUI,PCL3,PJL,Automatic,JPEG,AppleRaster,PWGRaster,PCLM,DW-PCL,DESKJET,DYN;
CLS:PRINTER;DES:4SR29A;CID:HPIJVIPAV7;
LEDMDIS:USB#FF#04#01,USB#FF#CC#00;
```

USB interfaces (`ioreg`):

| # | Class/Sub/Proto | Meaning |
|---|-----------------|---------|
| 0 | FF/CC/00 | Vendor specific — LEDM (listed in `LEDMDIS`) |
| 1 | 07/01/02 | USB printer class, bidirectional — used by CUPS `usb://` |
| 2 | FF/04/01 | Vendor specific — LEDM (listed in `LEDMDIS`) |
| 3 | FF/04/01 | Vendor specific — LEDM, second channel |

There is **no 07/01/04 (IPP-over-USB) interface**, so AirPrint over USB is
impossible, even though `CMD` lists `AppleRaster` and `PWGRaster`.

## 3. What did not work

| Attempt | Result |
|---------|--------|
| Custom PPD → `rastertopwg` → PWG Raster over `usb://` | `rastertopwg` rejects full-page rasters with *"Bad bottom/left/top margin"* unless the imageable area is the full page and page heights are multiples of 3 pt (A4 842 pt fails by one pixel at 600 dpi). After fixing that, the job is delivered but **the printer prints nothing**. |
| Custom PPD → `cgpdftoraster` → URF (AppleRaster) over `usb://` | Job delivered without errors, **printer prints nothing**. URF/PWG are only accepted through IPP, not on the legacy printer-class interface. |

## 4. What works: PCL3GUI via the DeskJet 2640 PPD

The Smart Tank 500 belongs to HP's "VIP" PCL3GUI inkjet family (`CID:HPIJVIPAV7`).
The PPD `HP Deskjet 2640 series.ppd.gz` from Apple's HP driver package uses
the `Inkjet9` renderer (x86_64, runs under Rosetta 2) and produces PCL3GUI
the printer accepts:

* full colour, plus grayscale (high-quality or black-only)
* 300 / 600×300 / 600 / 1200 dpi, draft → highest quality
* A4, F4 (8.5×13), Letter, Legal, B5, A6, 4×6, 5×7, envelopes
* plain and photo-glossy media types

`hpbridge setup-print` automates exactly this. Requirements: Rosetta 2 and the
HP driver PPDs under `/Library/Printers/PPDs/Contents/Resources` (present on
Macs that ever had Apple's HP driver package installed).

## 5. Scanning, status, ink and maintenance: LEDM

`LEDMDIS` tells us the printer serves HP's *Low End Data Model* web services
over its vendor interfaces. LEDM is plain HTTP/1.1 written to the bulk OUT
endpoint and read from the bulk IN endpoint. Useful resources:

| Resource | Purpose |
|----------|---------|
| `/DevMgmt/DiscoveryTree.xml` | Index of everything the firmware supports |
| `/DevMgmt/ProductConfigDyn.xml` | Model, serial, firmware |
| `/DevMgmt/ProductStatusDyn.xml` | State + alerts |
| `/DevMgmt/ConsumableConfigDyn.xml` | Ink levels |
| `/DevMgmt/InternalPrintDyn.xml` | Cleaning / alignment / report pages (PUT) |
| `/Scan/ScanCaps.xml`, `/Scan/Status.xml`, `/Scan/Jobs` | Flatbed scanning |

> **Status:** the LEDM code paths are implemented and unit-tested against
> representative documents, but **have not yet been verified on real
> hardware**. Please run `hpbridge -v discover` and `hpbridge -v status` on
> your printer and report the output (see CONTRIBUTING.md).
