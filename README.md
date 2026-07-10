# 1132 Fixer

## [Download the latest release here](https://github.com/PrimeUpYourLife/1132-fixer/releases/latest)

## [Discuss on Telegram](https://t.me/Team1132Fixer)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/PrimeUpYourLife/1132-fixer?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/PrimeUpYourLife/1132-fixer/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)

## Minimal macOS app with two actions

- `Start Zoom`: closes Zoom if it is running, stops immediately if a VPN interface is active, checks the active network, clears Zoom local data/cache/preferences/log state, requests admin access to flush system DNS caches, then launches Zoom in the required sandbox mode with camera/video access preserved. On macOS 13, the app may also spoof and reconnect the active Wi-Fi/Ethernet interface; on macOS 14 and later, MAC spoofing is disabled because that legacy method no longer works reliably.
- `Report a Bug`: opens a small form for optional email + message, then sends metadata plus an attached diagnostics file to the bug report API

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available.

## License and Risk

This project is licensed under the terms in `LICENSE`.

Attribution is required: any copy, fork, or derivative of this project must
give clear and prominent credit to the original project, **1132 Fixer**, with
a working link to <https://github.com/PrimeUpYourLife/1132-fixer>. You may
not claim the original work as your own. See `LICENSE` for the full terms.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
