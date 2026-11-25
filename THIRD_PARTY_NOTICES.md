# Third-party notices

Macap's own code is MIT-licensed (see `LICENSE`). The directory `ThirdParty/RifeMetal` is not
Macap's work. It is redistributed unchanged from the form in which OpenDuckFrame prepares it.

## rife-metal

- Source: https://github.com/cinemore/rife-metal, version 0.1.8, commit `ac6408022eb6bc1a53181f5b2716a9f5ded507c2`
- License: Apache License 2.0, full text in `ThirdParty/RifeMetal/LICENSE`
- A Metal implementation of RIFE inference for Apple Silicon. The upstream command-line tool, tests and
  `swift-argument-parser` dependency are not included.

## OpenDuckFrame modifications to rife-metal

- Source: https://github.com/Jun-bao/OpenDuckFrame (directory `ThirdParty/rife-metal`)
- License: MIT, Copyright (c) 2026 OpenDuckFrame contributors, Copyright (c) 2026 Khua contributors
- Changes carried here: the stream I/O patch, the experiment-options patch, the runtime-support patch, the
  `PaddedFrameConvert` helpers, and the four-stage model derivation. Each file's origin and hash is recorded in
  `ThirdParty/RifeMetal/source-origin.json`.
- Macap is a separate program. It is not an OpenDuckFrame release and is not endorsed by its maintainers.

## Practical-RIFE model weights

- Source: https://github.com/hzwer/Practical-RIFE, version 4.25
- License: MIT, Copyright (c) 2021 hzwer, full text in `ThirdParty/RifeMetal/THIRD-PARTY.md`
- `ThirdParty/RifeMetal/Sources/RifeMetal/Resources/rife-v4.25.rmw` is the four-stage graph that OpenDuckFrame
  derives from the v4.25 weights by removing the last block (no retraining). The file keeps the name
  `rife-v4.25` for compatibility.

## Apple frameworks

Modes 2 and 3 use the system's `VTLowLatencyFrameInterpolation` (VideoToolbox), which ships with macOS.
