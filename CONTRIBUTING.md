# Contributing

Thanks for helping! Bahasa Indonesia and English are both welcome in issues
and pull requests.

## Most wanted: hardware reports

Everything is verified on the HP Smart Tank 500. Reports from **other**
USB-only HP inkjets are what we need most. If you own one, please open an
issue with:

1. `hpbridge devices`
2. `lpinfo -l -v | grep -A4 usb://HP` (the device ID line)
3. `hpbridge -v discover`
4. `hpbridge -v status` and `hpbridge -v ink`
5. Optionally `hpbridge -v scan -o test.pdf`
6. macOS version and Mac model

**Remove your printer's serial number** from the output before posting.

## Adding support for a new model

* Printing: find an HP PPD under `/Library/Printers/PPDs/Contents/Resources`
  for a PCL3GUI printer of the same generation, test it with
  `hpbridge setup-print --ppd "<path>" --test`, and add a
  `PrinterModelProfile` entry in `Sources/HPUSBBridge/PrintSetup.swift`.
* LEDM: capture the XML your printer returns (`hpbridge raw GET <path>`),
  strip serial numbers, add it under `Tests/HPUSBBridgeTests/Fixtures/`, and
  add a test.

## Code guidelines

* Swift 5.9, no third-party dependencies.
* Keep protocol parsing in pure functions so it can be unit-tested without a
  printer.
* Every source file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.
* Run `scripts/test.sh` before opening a pull request.

By contributing you agree that your contributions are licensed under the
GPL-3.0-or-later.
