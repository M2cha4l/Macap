# Macap

**English** · [简体中文](README.zh-CN.md)

Macap turns a PS5's 30 fps picture into 60 fps in real time on an Apple Silicon Mac. It reads the picture from an HDMI capture card. It does not stream over the network and does not record the screen. The interface is in English, Simplified Chinese, Hindi, Spanish, Arabic, French and Japanese.

https://github.com/user-attachments/assets/f1690237-433f-407e-ae71-cc448c58586e

## What you need

1. A Mac with Apple Silicon (M1 to M5) and macOS 14 or later.
2. PS5 settings (set them once):
   - Turn off HDCP (Settings › System › HDMI). If it is on, the picture is black.
   - Turn off HDR, VRR and 120 Hz output.
   - Set the resolution to 2160p or 1080p at 60 Hz. Macap can scale 4K down to 2K itself.
   - Set the audio output to Linear PCM.
3. A driver-free UVC capture card:
   - For 4K or 2K: a USB 3.0 (5 Gbps) or USB 3.2 (10 Gbps) card with uncompressed NV12.
   - For 1080p: any USB 3.0 1080p60 card.
4. Wiring: PS5 → capture card HDMI IN; capture card USB-C → Mac (directly, not through a hub); Mac HDMI → TV or monitor.

## Install

1. Open the `.dmg` and drag Macap.app to Applications.
2. If macOS cannot verify the developer, Control-click Macap.app and choose Open.
3. Allow camera and microphone access.
4. Press `B` to benchmark. After about 3 s, a window shows the settings this Mac can hold, and you can apply them.

## Modes

A steady 60 fps needs ≤ 25.5 ms per frame (a 30 fps picture arrives every 33.3 ms, minus time to reach the screen).

| Mode | Key | How |
|---|---|---|
| Passthrough | `1` | No interpolation, no added delay. Use it for 60 fps games. |
| Fast | `2` | Estimates motion at 1/4 size. |
| Balanced | `3` | Estimates motion at 1/3 size. The default. |
| Quality | `4` | Estimates motion at 1/2 size. |
| System (720p / tiled) | `5` / `6` | macOS's own interpolation. Needs macOS 26. Keys only; not in the menus. |

Measured on an M5 Max (40-core GPU), time per frame:

| Resolution | Fast | Balanced | Quality |
|---|---|---|---|
| 4K | 6.0 ms | 11.1 ms | 23.3 ms |
| 2K | 2.9 ms | 4.2 ms | 10.3 ms |
| 1080p | 2.2 ms | 2.6 ms | 5.2 ms |

Suggested settings by Mac. Except for the M5 Max, these are estimates from GPU size; trust your own `B` benchmark:

| Mac | Suggested setting |
|---|---|
| M4 Max / M5 Max / Ultra | 4K + Quality; for lower delay, 4K + Balanced |
| M1 Max / M2 Max / M3 Max | 4K + Balanced |
| M4 Pro / M5 Pro | 4K + Fast, or 2K + Balanced |
| M1 Pro / M2 Pro / M3 Pro | 2K + Balanced; at 4K only Fast barely keeps up |
| M3 / M4 / M5 (with a fan) | 2K + Fast, or 1080p + Balanced |
| M1 / M2 base, every MacBook Air | 1080p + Balanced or Fast; on fanless Macs, go one step lower when they get hot |

## Keys

| Key | Action |
|---|---|
| `P` | Show or hide Settings. Settings stay open while there is no picture. `←` `→` select, `↑` `↓` change, `Return` OK, `Esc` back |
| `F` / `⌘F` / double-click | Fullscreen or window |
| Right-click / `M` | Pop-up menu |
| `B` | Benchmark |
| `1`–`4` | Passthrough, Fast, Balanced, Quality |
| `X` | MetalFX on or off |
| `K` | Sharpen: Off / Normal / Strong |
| `U` | Raw USB on or off (10 Gbps cards; install the helper from the menu first) |
| `H` | Stats: fps, delay, drops |
| `S` | Save the last second |
| `Esc` | Close Settings first, then leave fullscreen |
| `Q` / `⌘Q` | Quit |

Move the mouse over the picture to show the Settings button in the lower-right corner.

Change the language in the menu bar under Macap › Language. By default Macap follows the system language. Languages other than Chinese and English were translated by AI; native speakers are welcome to fix them in `Resources/<language>.lproj/Localizable.strings` and check with `tools/i18n_check.py`.

## Build from source

You need the Xcode Command Line Tools. Shaders compile at run time, so Xcode itself is not needed.

```sh
./build.sh                  # build Macap.app
./tools/package_dmg.sh      # clean build, self-test, package a .dmg
```

## Known limits

- Made for 30 fps games. For 60 fps games, press `1` for Passthrough.
- Interpolation adds about 70–90 ms of delay. A wired controller on the PS5 helps.
- When the camera turns fast and far, character edges sometimes show a faint outline.
- A background task that fills the GPU (a local LLM, rendering) makes frames late and drops them.

## Support Macap

Macap is free and open source. If it helps you, you can buy me a coffee:

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Buy%20me%20a%20coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/m2cha4l) [![Afdian](https://img.shields.io/badge/%E7%88%B1%E5%8F%91%E7%94%B5-Afdian-946CE6?style=for-the-badge)](https://afdian.com/item/7710bd38e87e11f1b59e5254001e7c00)

Ko-fi takes cards and PayPal. 爱发电 (Afdian) takes WeChat Pay and Alipay.

## Credits

Macap is built on CaptureInterp v1.0.0 by GD古仔 (MIT). Capture, frame scheduling and raw USB reading come from CaptureInterp; the interface, the modes, the languages and several fixes are new in Macap.

## License

The code in this repository is MIT-licensed (`LICENSE`). `ThirdParty/RifeMetal` is based on rife-metal (Apache-2.0), OpenDuckFrame (MIT) and the Practical-RIFE model weights (MIT); see `THIRD_PARTY_NOTICES.md`.
