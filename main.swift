import Accelerate
// CaptureInterp: capture device (UVC capture card / camera) -> Apple low-latency
// frame interpolation (X2) -> fixed-cadence presentation. No screen capture.
//
// Usage (inside the .app bundle):
//   CaptureInterp --list
//   CaptureInterp [--device <name substring>] [--screen <index>] [--offset <ms>]
//                 [--no-interp] [--audio <name substring>] [--log <path>] [--seconds <n>]
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import RifeMetal
import CoreImage
import Darwin.Mach
import IOSurface
import Metal
import MetalFX

// MARK: - Arguments

struct Options {
    var list = false
    var device = ""
    var deviceExplicit = false
    var screen = 0
    var screenExplicit = false   // --screen <index> was given
    var screenNameExplicit = false
    var offsetMs = 0.0       // capture PTS -> interpolated frame on screen; 0 = adaptive
    var followArrival = true // hold = this frame's own delivery delay + processing time (false: fixed hold sized for the slowest recent delivery)
    var leadMs = -1.0        // hand a frame to the display layer this long before the refresh it is meant for; <0 = automatic
    var gpuPhaseMs = -1.0    // GPU mode: start each interpolation this long after a screen refresh (<0 = start at once)
    var votePick = false     // second version of the choice (switch halves by vote)
    var exactRepeat = false  // repeats must be bit-identical (the rule before cards with noisy repeats)
    var legacyPick = false   // old per-frame choice of which 60 fps capture frames carry a new 30 fps picture
    var multiMid = true      // GPU modes: two in-between pictures when the game held a picture for three refreshes
    var protectOnCPU = false // still-pixel protection on the CPU (the first version) instead of the GPU pass
    var gpuAwake = false     // experiment: keep handing the GPU a trivial job so it never idles between two pictures (idle GPU = slower next job)
    var protectStill = true  // GPU modes: keep pixels that are identical in both originals (subtitles, HUD) out of the motion warp
    var holdBandMs = -1.0    // slack beyond one refresh that is tolerated before the hold comes down; <0 = automatic (12 was the old steady value)
    var steady = true        // once the hold had to go up a step it stays there: every step change cost ~6 misplaced frames on the glass (--stepping: lower average delay, a blip every ~8 s)
    var marginMs = -1.0      // <0 = automatic; was 2.0:      // adaptive mode: headroom above the observed ready time
    var interpolate = true
    var modeExplicit = false
    var initialModeOverride = 0
    var dump = ""            // directory: write a few consecutive original/generated frames as PNG (diagnosis)
    var dumpAfter = 150      // frames to wait before dumping
    var collect = true       // background sample collector: auto-saves tricky motion clips + key S saves last ~1 s
    var sampleDir = NSHomeDirectory() + "/Library/Application Support/CaptureInterp/samples"
    var rife = ""            // "fast" / "medium" / "balanced": start in the GPU (RIFE) mode
    var audio = ""
    var audioExplicit = false
    var log = NSHomeDirectory() + "/Library/Logs/CaptureInterp/stats.log"
    var seconds = 0.0
    var maxWidth = 0         // 0 = highest available
    var maxWidthExplicit = false
    var preferCompressed = false // same size: take the format with the highest top frame rate (the MJPEG one on UVC cards)
    var rawUSB = false       // read UVC Bulk frames via root-owned helper in /usr/local/libexec + shared IOSurface ring
    var rawUSBExplicit = false
    var selftest = false     // offline self-test of raw-USB IPC, IOSurface lease, and helper ownership checks
    var file = ""            // simulate a device: play this video file in real time at ~30 fps
    var fileExplicit = false
    var tiles = 1            // 4 = 2x2 -> ~2K (2496x1404); 9 = 3x3 -> ~3K (3200x1800)
    var grid: Grid? = nil    // --grid cols rows tileW tileH overlapX overlapY (experiments)
    var origNative = false   // show originals at capture size instead of the working size
    var screenName = ""      // pick the output screen by name, e.g. "Studio Display"
    var vsync = true         // place frames on the display's refresh grid
    var audioGainDb = 20.0   // extra loudness in dB (capture card HDMI sound arrives very quiet)
    var audioGainExplicit = false
    var autoPass = false     // 60 fps capture: show a 60 fps game as is instead of interpolating (off: keys 2/3 always interpolate)
    var fps = 30.0           // capture frame rate to lock (60 = take the source as is, no interpolation needed)
    var fpsExplicit = false
    var audioVolume = 1.0    // 0 = process audio silently (testing)
    var audioVolumeExplicit = false
    var sharpness = 0.55     // Contrast-Adaptive Sharpening (0 = off, 0.55 = standard 5K crisp, 0.90 = strong; key K toggles)
    var sharpnessExplicit = false
    var fullscreen = false   // --fullscreen: start directly in borderless fullscreen mode
    var upscale = UpscaleMode.off
    var openMenu = false     // --open-menu: open the card-row menu right after launch (screenshots, timing)
}

enum UpscaleMode: String { case off, metalfx }

enum Prefs {
    static let enabled: Bool = {
        let args = CommandLine.arguments
        if args.contains("--selftest") || args.contains("--list") || args.contains("--file") { return false }
        if ProcessInfo.processInfo.environment["CI_HEADLESS"] == "1" { return false }
        return true
    }()
    private static var ud: UserDefaults { .standard }
    static func saveMode(_ raw: Int) { guard enabled else { return }; ud.set(raw, forKey: "pref.mode") }
    static func saveSharpness(_ v: Float) { guard enabled else { return }; ud.set(Double(v), forKey: "pref.sharpness") }
    static func saveMaxWidth(_ w: Int) { guard enabled else { return }; ud.set(w, forKey: "pref.maxWidth") }
    static func saveDevice(_ name: String) { guard enabled else { return }; ud.set(name, forKey: "pref.device") }
    static func saveScreenName(_ name: String) { guard enabled else { return }; ud.set(name, forKey: "pref.screenName") }
    static func saveRawUSB(_ on: Bool) { guard enabled else { return }; ud.set(on, forKey: "pref.rawUSB") }
    static func saveAudioEnabled(_ on: Bool) { guard enabled else { return }; ud.set(on ? "auto" : "", forKey: "pref.audio") }
    static func saveAudioGainDb(_ db: Double) { guard enabled else { return }; ud.set(db, forKey: "pref.audioGainDb") }
    static func saveHudPinned(_ on: Bool) { guard enabled else { return }; ud.set(on, forKey: "pref.hudPinned") }
    static func loadHudPinned() -> Bool { enabled ? ud.bool(forKey: "pref.hudPinned") : false }
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--list": o.list = true
        case "--device": o.device = it.next() ?? ""; o.deviceExplicit = true
        case "--screen": o.screen = Int(it.next() ?? "") ?? 0; o.screenExplicit = true
        case "--offset": o.offsetMs = Double(it.next() ?? "") ?? o.offsetMs
        case "--steady-offset": o.followArrival = false
        case "--lead-ms": o.leadMs = Double(it.next() ?? "") ?? o.leadMs
        case "--gpu-phase-ms": o.gpuPhaseMs = Double(it.next() ?? "") ?? o.gpuPhaseMs
        case "--steady": o.steady = true
        case "--no-protect": o.protectStill = false
        case "--gpu-awake": o.gpuAwake = true
        case "--protect-cpu": o.protectOnCPU = true
        case "--single-mid": o.multiMid = false
        case "--legacy-pick": o.legacyPick = true
        case "--exact-repeat": o.exactRepeat = true
        case "--vote-pick": o.votePick = true
        case "--stepping": o.steady = false
        case "--hold-band": o.holdBandMs = Double(it.next() ?? "") ?? o.holdBandMs
        case "--margin": o.marginMs = Double(it.next() ?? "") ?? o.marginMs
        case "--no-interp": o.interpolate = false; o.modeExplicit = true
        case "--dump": o.dump = it.next() ?? ""
        case "--dump-after": o.dumpAfter = Int(it.next() ?? "") ?? 150
        case "--no-collect": o.collect = false
        case "--samples": o.sampleDir = it.next() ?? o.sampleDir
        case "--rife": o.rife = it.next() ?? "fast"; o.modeExplicit = true
        case "--audio": o.audio = it.next() ?? ""; o.audioExplicit = true
        case "--log": o.log = it.next() ?? o.log
        case "--seconds": o.seconds = Double(it.next() ?? "") ?? 0
        case "--max-width": o.maxWidth = Int(it.next() ?? "") ?? 0; o.maxWidthExplicit = true
        case "--compressed": o.preferCompressed = true
        case "--raw-usb": o.rawUSB = true; o.rawUSBExplicit = true
        case "--no-raw-usb": o.rawUSB = false; o.rawUSBExplicit = true
        case "--selftest": o.selftest = true
        case "--file": o.file = it.next() ?? ""; o.fileExplicit = true
        case "--tiles": o.tiles = Int(it.next() ?? "") ?? 1; o.modeExplicit = true
        case "--orig-native": o.origNative = true
        case "--screen-name": o.screenName = it.next() ?? ""; o.screenNameExplicit = true
        case "--no-vsync": o.vsync = false
        case "--audio-volume": o.audioVolume = Double(it.next() ?? "") ?? 1.0; o.audioVolumeExplicit = true
        case "--auto-pass": o.autoPass = true
        case "--fps": o.fps = Double(it.next() ?? "") ?? 30; o.fpsExplicit = true
        case "--audio-gain": o.audioGainDb = Double(it.next() ?? "") ?? 0; o.audioGainExplicit = true
        case "--sharpness": o.sharpness = min(1.0, max(0.0, Double(it.next() ?? "") ?? 0.55)); o.sharpnessExplicit = true
        case "--fullscreen": o.fullscreen = true
        case "--open-menu": o.openMenu = true
        case "--upscale": o.upscale = UpscaleMode(rawValue: it.next() ?? "") ?? .off
        case "--grid":
            let v = (0..<6).map { _ in Int(it.next() ?? "") ?? 0 }
            if v.allSatisfy({ $0 > 0 }) { o.grid = Grid(cols: v[0], rows: v[1], tileW: v[2], tileH: v[3], overlapX: v[4], overlapY: v[5]); o.tiles = v[0] * v[1]; o.modeExplicit = true }
        default: break
        }
    }
    if Prefs.enabled && !o.list && !o.selftest && !o.fileExplicit {
        let ud = UserDefaults.standard
        if !o.fpsExplicit {
            let savedFps = ud.double(forKey: "pref.fps")
            o.fps = savedFps > 0 ? savedFps : 60.0
        }
        if !o.modeExplicit {
            let savedMode = ud.integer(forKey: "pref.mode")
            o.initialModeOverride = (1...6).contains(savedMode) ? savedMode : 6 // Mode.rifeMedium (4.5 tier) out of the box
        }
        if !o.audioExplicit {
            o.audio = (ud.object(forKey: "pref.audio") as? String) ?? "auto"
        }
        if !o.audioGainExplicit, ud.object(forKey: "pref.audioGainDb") != nil {
            o.audioGainDb = ud.double(forKey: "pref.audioGainDb")
        }
        if !o.sharpnessExplicit, ud.object(forKey: "pref.sharpness") != nil {
            o.sharpness = min(1.0, max(0.0, ud.double(forKey: "pref.sharpness")))
        }
        if !o.maxWidthExplicit, ud.object(forKey: "pref.maxWidth") != nil {
            o.maxWidth = max(0, ud.integer(forKey: "pref.maxWidth"))
        }
        if !o.deviceExplicit, let dev = ud.string(forKey: "pref.device") {
            o.device = dev
        }
        if !o.screenExplicit && !o.screenNameExplicit, let scr = ud.string(forKey: "pref.screenName") {
            o.screenName = scr
        }
        if !o.rawUSBExplicit {
            if ud.object(forKey: "pref.rawUSB") != nil {
                o.rawUSB = ud.bool(forKey: "pref.rawUSB")
            } else {
                o.rawUSB = RawUVCCapture.verifyHelperBinary(RawUVCCapture.installedHelperPath).ok
            }
        }
    }
    // --raw-usb exists specifically for full 60 fps uncompressed capture; default to 60 unless --fps was given.
    if o.rawUSB && !o.fpsExplicit { o.fps = 60 }
    return o
}

let opts = parseOptions()

let noDisplayDebug = ProcessInfo.processInfo.environment["CI_NO_DISPLAY"] == "1"

final class Log {
    static let shared = Log()
    private var handle: FileHandle?
    func open(_ path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Keep every earlier session: the previous log moves to logs/<name>_<when it was last written>.log
        // instead of being overwritten (a whole evening of play used to be lost at the next start).
        if let attrs = try? fm.attributesOfItem(atPath: path), (attrs[.size] as? Int ?? 0) > 0, let when = attrs[.modificationDate] as? Date {
            let keep = dir + "/logs"
            try? fm.createDirectory(atPath: keep, withIntermediateDirectories: true)
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            try? fm.moveItem(atPath: path, toPath: "\(keep)/\(base)_\(f.string(from: when)).log")
        }
        fm.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        line("started: \(Log.clock(full: true))")
        atexit { Log.shared.flush() }
    }
    // Writing can stall for a second or more (seen with the log on a slow volume), so it must
    // never happen on the capture or processing threads: lines are handed to a background queue.
    private let writer = DispatchQueue(label: "log.writer", qos: .utility)
    func line(_ s: String) {
        writer.async {
            print(s)
            self.handle?.write((s + "\n").data(using: .utf8)!)
        }
    }
    /// Wall-clock time for log lines, so a stutter the player remembers can be found again.
    static func clock(full: Bool = false) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = full ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    /// Blocks until everything logged so far is on disk (used before exiting).
    func flush() { writer.sync {} }
}

func audioDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
}

/// Capture cards show up as external devices; in auto mode, ONLY select genuine external capture cards
/// and never surprise-open the user's built-in FaceTime or Continuity iPhone selfie camera.
func preferredVideoDevice(_ name: String) -> AVCaptureDevice? {
    let devs = videoDevices()
    if !name.isEmpty { return devs.first { $0.localizedName.localizedCaseInsensitiveContains(name) } }
    func isBuiltInOrVirtualOrPhone(_ d: AVCaptureDevice) -> Bool {
        ["OBS", "iPhone", "iPad", "Virtual", "MacBook", "FaceTime", "Continuity", "Desk View"].contains {
            d.localizedName.localizedCaseInsensitiveContains($0)
        }
    }
    return devs.first { $0.deviceType == .external && !isBuiltInOrVirtualOrPhone($0) }
}

func videoDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                     mediaType: .video, position: .unspecified).devices
}

func fourCC(_ v: OSType) -> String {
    let b = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}

if !opts.list && !opts.selftest { Log.shared.open(opts.log) }

// Experiment (--gpu-awake). Measured outside the app: with the GPU idle ~25 ms between pictures the motion
// network takes 7-8 ms and wobbles; with the GPU kept busy by a trivial copy it takes 3-5 ms and is steady.
if opts.gpuAwake, !opts.list, !opts.selftest, let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
    if let a = dev.makeTexture(descriptor: d), let b = dev.makeTexture(descriptor: d) {
        let t = Thread {
            while true {
                guard let cb = q.makeCommandBuffer(), let e = cb.makeBlitCommandEncoder() else { usleep(1000); continue }
                e.copy(from: a, to: b); e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            }
        }
        t.qualityOfService = .utility; t.start()
        Log.shared.line("gpu-awake: on")
    }
}

if opts.list {
    for d in videoDevices() {
        Log.shared.line("VIDEO DEVICE \(d.localizedName)\(d.deviceType == .external ? "  [external]" : "")")
        var seen = Set<String>()
        for f in d.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))
            let fps = f.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate.rounded()) }.max() ?? 0
            let key = "  \(dim.width)x\(dim.height) \(sub) up to \(fps) fps"
            if seen.insert(key).inserted { Log.shared.line(key) }
        }
    }
    for d in audioDevices() { Log.shared.line("AUDIO DEVICE \(d.localizedName)") }
    Log.shared.flush(); exit(0)
}

// MARK: - Helpers

let hostClock = CMClockGetHostTimeClock()
func hostNow() -> CMTime { CMClockGetTime(hostClock) }
func ms(_ t: CMTime) -> Double { CMTimeGetSeconds(t) * 1000.0 }

func makeSample(_ pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
    var fmt: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr,
          let fmt else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                             sampleTiming: &timing, sampleBufferOut: &sb)
    return sb
}

/// Generated frames must carry the same colour tags as the originals, or the display
/// treats alternate frames differently and the picture flickers.
func copyColor(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
    if let att = CVBufferCopyAttachments(src, .shouldPropagate) { CVBufferSetAttachments(dst, att, .shouldPropagate) }
}

/// Mean of each byte channel of a BGRA buffer (sparse sample): B, G, R, A.
func meanBGRA(_ pb: CVPixelBuffer) -> [Double] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let b = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return [-1, -1, -1, -1] }
    let bpr = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var s = [0, 0, 0, 0], n = 0
    for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: w, by: 16) { for c in 0..<4 { s[c] += Int(b[y * bpr + x * 4 + c]) }; n += 1 } }
    return s.map { Double($0) / Double(max(1, n)) }
}

/// Sparse comparison of two same-size BGRA buffers (green channel): mean |a-b|, and each one's mean horizontal gradient.
func compareBGRA(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (diff: Double, gradA: Double, gradB: Double) {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self), let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return (-1, -1, -1) }
    let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b), w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
    var d = 0, ga = 0, gb = 0, n = 0
    for y in stride(from: 8, to: h - 8, by: 9) { for x in stride(from: 8, to: w - 8, by: 7) {
        let va = Int(pa[y * ra + x * 4 + 1]), vb = Int(pb[y * rb + x * 4 + 1])
        d += abs(va - vb); ga += abs(va - Int(pa[y * ra + (x + 1) * 4 + 1])); gb += abs(vb - Int(pb[y * rb + (x + 1) * 4 + 1])); n += 1 } }
    return (Double(d) / Double(n), Double(ga) / Double(n), Double(gb) / Double(n))
}

let dumpContext = CIContext()
let dumpQueue = DispatchQueue(label: "dump", qos: .utility)
func savePNG(_ pb: CVPixelBuffer, _ path: String) {
    let img = CIImage(cvPixelBuffer: pb)
    try? dumpContext.writePNGRepresentation(of: img, to: URL(fileURLWithPath: path), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}

func meanLuma(_ pb: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let b = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    var sum = 0, n = 0
    for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: w, by: 16) { sum += Int(b[y * bpr + x]); n += 1 } }
    return Double(sum) / Double(max(1, n))
}

/// Reuses IOSurface-backed buffers instead of allocating new ones for every frame.
final class BufferPool {
    private var pool: CVPixelBufferPool?
    init(width: Int, height: Int, format: OSType, attrs: [String: Any]) {
        var a = attrs
        a[kCVPixelBufferWidthKey as String] = width
        a[kCVPixelBufferHeightKey as String] = height
        a[kCVPixelBufferPixelFormatTypeKey as String] = format
        a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &pool)
    }
    func get() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}

func pixelFormat(of attrs: [String: Any]) -> OSType {
    let raw = attrs[kCVPixelBufferPixelFormatTypeKey as String]
    return (raw as? OSType) ?? (raw as? [OSType])?.first ?? (raw as? NSNumber)?.uint32Value
        ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
}

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return -1 }
    let s = v.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded(.up)))]
}

/// MetalFX spatial upscale of a displayed BGRA frame to the display's pixel size, in place of the display layer's plain stretch.
final class SpatialUpscaler {
    private let lock = NSLock()
    private var _mode: UpscaleMode
    var mode: UpscaleMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var cache: CVMetalTextureCache?
    private var scaler: MTLFXSpatialScaler?
    private var scaled: MTLTexture?   // the scaler only writes private-storage textures, so it scales here and blits into the IOSurface
    private var pool: BufferPool?
    private(set) var key = (inW: 0, inH: 0, outW: 0, outH: 0)
    private var failed = false
    private(set) var lastSkip = "no frame yet"
    var gpuMs: [Double] = [], wallMs: [Double] = []

    init(mode: UpscaleMode) {
        _mode = mode
        if let device { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        Log.shared.line("upscale: \(mode.rawValue)")
    }

    /// nil = show the source unchanged (off, not BGRA, not smaller than the target, or a Metal failure).
    func upscale(_ src: CVPixelBuffer, to target: (w: Int, h: Int)) -> CVPixelBuffer? {
        guard mode == .metalfx else { return nil }
        let inW = CVPixelBufferGetWidth(src), inH = CVPixelBufferGetHeight(src)
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA else { lastSkip = "source not 32BGRA"; return nil }
        guard target.w > inW && target.h > inH else { lastSkip = "target \(target.w)x\(target.h) not larger than \(inW)x\(inH)"; return nil }
        let t0 = CACurrentMediaTime()
        guard let device, let queue, let cache else { return fail("no Metal device") }
        if key != (inW, inH, target.w, target.h) {
            key = (inW, inH, target.w, target.h); scaler = nil; scaled = nil; pool = nil
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = inW; d.inputHeight = inH; d.outputWidth = target.w; d.outputHeight = target.h
            d.colorTextureFormat = .bgra8Unorm; d.outputTextureFormat = .bgra8Unorm
            d.colorProcessingMode = .perceptual   // frames hold sRGB-encoded values
            guard let s = d.makeSpatialScaler(device: device) else { return fail("makeSpatialScaler \(inW)x\(inH)->\(target.w)x\(target.h)") }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: target.w, height: target.h, mipmapped: false)
            td.storageMode = .private; td.usage = s.outputTextureUsage
            guard let tex = device.makeTexture(descriptor: td) else { return fail("output texture") }
            scaler = s; scaled = tex
            pool = BufferPool(width: target.w, height: target.h, format: kCVPixelFormatType_32BGRA, attrs: [kCVPixelBufferMetalCompatibilityKey as String: true])
            Log.shared.line("upscale: metalfx scaler \(inW)x\(inH)->\(target.w)x\(target.h)")
        }
        guard let scaler, let scaled, let pool else { return nil }   // this size already failed and was logged
        guard let out = pool.get() else { return fail("output buffer") }
        guard let inT = texture(src, cache, scaler.colorTextureUsage), let outT = texture(out, cache, [.shaderRead]),
              let inTex = CVMetalTextureGetTexture(inT), let outTex = CVMetalTextureGetTexture(outT),
              let cb = queue.makeCommandBuffer() else { return fail("textures") }
        scaler.colorTexture = inTex; scaler.outputTexture = scaled
        scaler.inputContentWidth = inW; scaler.inputContentHeight = inH
        scaler.encode(commandBuffer: cb)
        guard let blit = cb.makeBlitCommandEncoder() else { return fail("blit encoder") }
        blit.copy(from: scaled, to: outTex); blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        guard cb.status == .completed else { return fail("command buffer \(cb.error.map { "\($0)" } ?? "status \(cb.status.rawValue)")") }
        gpuMs.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        wallMs.append((CACurrentMediaTime() - t0) * 1000)
        copyColor(from: src, to: out)
        return out
    }

    private func texture(_ pb: CVPixelBuffer, _ cache: CVMetalTextureCache, _ usage: MTLTextureUsage) -> CVMetalTexture? {
        var t: CVMetalTexture?
        let attrs = [kCVMetalTextureUsage as String: NSNumber(value: usage.rawValue)] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, attrs, .bgra8Unorm, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t) == kCVReturnSuccess else { return nil }
        return t
    }

    private func fail(_ why: String) -> CVPixelBuffer? {
        lastSkip = why
        if !failed { failed = true; Log.shared.line("upscale failed: \(why); showing frames unscaled") }
        return nil
    }
}

// MARK: - Interpolator (Apple low-latency frame interpolation at <= 1280x720)

@available(macOS 26.0, *)
final class Interpolator {
    let width: Int, height: Int
    private let config: VTLowLatencyFrameInterpolationConfiguration
    private let processor = VTFrameProcessor()
    private var transfer: VTPixelTransferSession?
    private let srcAttrs: [String: Any]
    private let dstAttrs: [String: Any]

    init?(sourceWidth: Int, sourceHeight: Int) {
        // macOS 26 accepts 16:9 up to 1280x720; keep inside that box, even dimensions.
        let scale = min(1.0, min(1280.0 / Double(sourceWidth), 720.0 / Double(sourceHeight)))
        width = max(2, Int(Double(sourceWidth) * scale) & ~1)
        height = max(2, Int(Double(sourceHeight) * scale) & ~1)
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let c = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height,
                                                                   numberOfInterpolatedFrames: 1) else { return nil }
        config = c
        srcAttrs = c.sourcePixelBufferAttributes
        dstAttrs = c.destinationPixelBufferAttributes
        do { try processor.startSession(configuration: c) } catch {
            Log.shared.line("interp session failed: \(error.localizedDescription)")
            return nil
        }
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    private lazy var srcPool = BufferPool(width: width, height: height, format: pixelFormat(of: srcAttrs), attrs: srcAttrs)
    private lazy var dstPool = BufferPool(width: width, height: height, format: pixelFormat(of: dstAttrs), attrs: dstAttrs)

    /// Scale a captured frame into the interpolation input size.
    func prepare(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let dst = srcPool.get() else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: dst) == noErr else { return nil }
        copyColor(from: source, to: dst)
        return dst
    }

    /// Blocking: returns the midpoint frame between previous and current.
    func midpoint(previous: CVPixelBuffer, current: CVPixelBuffer, previousPTS: CMTime, currentPTS: CMTime) -> CVPixelBuffer? {
        guard let dst = dstPool.get(),
              let fa = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousPTS),
              let fb = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currentPTS) else { return nil }
        let mid = CMTimeAdd(previousPTS, CMTimeMultiplyByFloat64(CMTimeSubtract(currentPTS, previousPTS), multiplier: 0.5))
        guard let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: mid),
              let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: fb, previousFrame: fa,
                                                                    interpolationPhase: [0.5], destinationFrames: [fd]) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        processor.process(parameters: params) { _, error in
            ok = error == nil
            if let error { Log.shared.line("interp error: \(error.localizedDescription)") }
            sem.signal()
        }
        sem.wait()
        copyColor(from: current, to: dst)
        return ok ? dst : nil
    }
}

// MARK: - Tiled interpolator (grid of overlapping tiles, cross-faded)

struct Grid {
    var cols = 2, rows = 2, tileW = 1280, tileH = 720, overlapX = 64, overlapY = 36
    var workW: Int { cols * tileW - (cols - 1) * overlapX }
    var workH: Int { rows * tileH - (rows - 1) * overlapY }
    static let k2 = Grid()                                                              // 2496 x 1404
    static let k3 = Grid(cols: 3, rows: 3, tileW: 1120, tileH: 632, overlapX: 80, overlapY: 48)   // 3200 x 1800
}

/// The system engine accepts about 1280x720 per pass on macOS 26. Overlapping tiles
/// cover a larger working frame; overlaps are cross-faded to hide seams.
@available(macOS 26.0, *)
final class TiledInterpolator {
    let g: Grid
    private var configs: [VTLowLatencyFrameInterpolationConfiguration] = []
    private var processors: [VTFrameProcessor] = []
    private var transfer: VTPixelTransferSession?
    private var format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private var srcAttrs: [String: Any] = [:]
    private var dstAttrs: [String: Any] = [:]
    private var rowA: [UInt8], rowB: [UInt8]
    /// Mean absolute luma difference between neighbouring tiles inside the overlaps (0-255); for comparison,
    /// `lastTextureDiff` is the same measure between adjacent pixel columns of one tile (natural detail level).
    private(set) var lastSeamDiff = 0.0, lastTextureDiff = 0.0

    init?(_ grid: Grid) {
        g = grid
        rowA = [UInt8](repeating: 0, count: max(2, grid.workW))
        rowB = [UInt8](repeating: 0, count: max(2, grid.workW))
        // NV12 chroma is interleaved at half size: everything must be even, and overlaps must leave a body.
        guard g.cols >= 1, g.rows >= 1, g.tileW % 2 == 0, g.tileH % 2 == 0, g.overlapX % 4 == 0, g.overlapY % 4 == 0,
              g.overlapX >= 4, g.overlapY >= 4, g.overlapX * 2 <= g.tileW, g.overlapY * 2 <= g.tileH else {
            Log.shared.line("invalid grid: sizes must be even, overlaps multiples of 4 and at most half a tile"); return nil
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { return nil }
        for _ in 0..<(g.cols * g.rows) {
            guard let c = VTLowLatencyFrameInterpolationConfiguration(frameWidth: g.tileW, frameHeight: g.tileH,
                                                                      numberOfInterpolatedFrames: 1) else { return nil }
            let p = VTFrameProcessor()
            do { try p.startSession(configuration: c) } catch {
                Log.shared.line("tile session failed: \(error.localizedDescription)")
                for started in processors { started.endSession() }
                return nil
            }
            configs.append(c); processors.append(p)
        }
        srcAttrs = configs[0].sourcePixelBufferAttributes
        dstAttrs = configs[0].destinationPixelBufferAttributes
        let raw = srcAttrs[kCVPixelBufferPixelFormatTypeKey as String]
        format = (raw as? OSType) ?? (raw as? [OSType])?.first ?? (raw as? NSNumber)?.uint32Value ?? format
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            Log.shared.line("tile mode needs 8-bit NV12, engine wants \(fourCC(format))"); return nil
        }
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    private lazy var workPool = BufferPool(width: g.workW, height: g.workH, format: format, attrs: [:])
    private lazy var tileSrcPool = BufferPool(width: g.tileW, height: g.tileH, format: format, attrs: srcAttrs)
    private lazy var tileDstPool = BufferPool(width: g.tileW, height: g.tileH, format: format, attrs: dstAttrs)

    /// Where the time of the last frame went, ms: scale, cut into tiles, engine, stitch.
    private(set) var lastScaleMs = 0.0, lastCropMs = 0.0, lastEngineMs = 0.0, lastStitchMs = 0.0

    /// Scale the captured frame to the working size.
    func work(from source: CVPixelBuffer) -> CVPixelBuffer? {
        let t0 = CACurrentMediaTime(); defer { lastScaleMs = (CACurrentMediaTime() - t0) * 1000 }
        guard let transfer, let dst = workPool.get() else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: dst) == noErr else { return nil }
        copyColor(from: source, to: dst)
        return dst
    }

    /// Cut the working frame into overlapping tiles, row-major.
    func crop(_ work: CVPixelBuffer) -> [CVPixelBuffer]? {
        let t0 = CACurrentMediaTime(); defer { lastCropMs = (CACurrentMediaTime() - t0) * 1000 }
        var tiles: [CVPixelBuffer] = []
        CVPixelBufferLockBaseAddress(work, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(work, .readOnly) }
        for _ in 0..<(g.rows * g.cols) { guard let t = tileSrcPool.get() else { return nil }; tiles.append(t) }
        let all = tiles, g = self.g
        // Plain memory copies: one tile per core.
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            do {
                let ty = i / g.cols, tx = i % g.cols, t = all[i]
                CVPixelBufferLockBaseAddress(t, [])
                for plane in 0..<2 {
                    let div = plane == 0 ? 1 : 2
                    guard let sb = CVPixelBufferGetBaseAddressOfPlane(work, plane), let db = CVPixelBufferGetBaseAddressOfPlane(t, plane) else { continue }
                    let sbpr = CVPixelBufferGetBytesPerRowOfPlane(work, plane), dbpr = CVPixelBufferGetBytesPerRowOfPlane(t, plane)
                    let x0 = tx * (g.tileW - g.overlapX)             // bytes: luma 1 per px, chroma 2 per half px
                    let y0 = ty * (g.tileH - g.overlapY) / div
                    for y in 0..<(g.tileH / div) { memcpy(db + y * dbpr, sb + (y0 + y) * sbpr + x0, g.tileW) }
                }
                CVPixelBufferUnlockBaseAddress(t, [])
            }
        }
        return tiles
    }

    /// Blocking: interpolate all tiles at once and stitch the midpoint frame.
    func midpoint(previous: [CVPixelBuffer], current: [CVPixelBuffer], previousPTS: CMTime, currentPTS: CMTime, like: CVPixelBuffer) -> CVPixelBuffer? {
        let mid = CMTimeAdd(previousPTS, CMTimeMultiplyByFloat64(CMTimeSubtract(currentPTS, previousPTS), multiplier: 0.5))
        var outs: [CVPixelBuffer] = []
        let group = DispatchGroup()
        let lock = NSLock()
        var failed = false
        for i in 0..<processors.count {
            guard let dst = tileDstPool.get(),
                  let fa = VTFrameProcessorFrame(buffer: previous[i], presentationTimeStamp: previousPTS),
                  let fb = VTFrameProcessorFrame(buffer: current[i], presentationTimeStamp: currentPTS),
                  let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: mid),
                  let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: fb, previousFrame: fa,
                                                                        interpolationPhase: [0.5], destinationFrames: [fd]) else { return nil }
            outs.append(dst)
            group.enter()
            processors[i].process(parameters: params) { _, error in
                if let error { lock.lock(); failed = true; lock.unlock(); Log.shared.line("tile error: \(error.localizedDescription)") }
                group.leave()
            }
        }
        let tEngine = CACurrentMediaTime()
        group.wait()
        let tStitch = CACurrentMediaTime()
        lastEngineMs = (tStitch - tEngine) * 1000
        guard !failed, let out = stitch(outs) else { return nil }
        lastStitchMs = (CACurrentMediaTime() - tStitch) * 1000
        copyColor(from: like, to: out)
        return out
    }

    /// Reassemble the tiles; cross-fade linearly across the overlaps.
    private func stitch(_ t: [CVPixelBuffer]) -> CVPixelBuffer? {
        guard let out = workPool.get() else { return nil }
        for b in t { CVPixelBufferLockBaseAddress(b, .readOnly) }
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            for b in t { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        }
        let cols = g.cols, tileRows = g.rows
        for plane in 0..<2 {
            let div = plane == 0 ? 1 : 2
            let step = plane == 0 ? 1 : 2                      // bytes per horizontal sample
            let rows = g.tileH / div, ovY = g.overlapY / div, outRows = g.workH / div, pitchY = rows - ovY
            let tw = g.tileW, ovBytes = g.overlapX, pitchX = tw - ovBytes, ovSamples = ovBytes / step
            guard let ob = CVPixelBufferGetBaseAddressOfPlane(out, plane)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let obpr = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            var base0: [UnsafeMutablePointer<UInt8>] = [], bpr0: [Int] = []
            for b in t {
                guard let p = CVPixelBufferGetBaseAddressOfPlane(b, plane)?.assumingMemoryBound(to: UInt8.self) else { return nil }
                base0.append(p); bpr0.append(CVPixelBufferGetBytesPerRowOfPlane(b, plane))
            }
            let base = base0, bpr = bpr0
            if plane == 0 {   // how much do neighbouring tiles disagree where they overlap?
                var seam = 0, tex = 0, n = 0
                if cols > 1 {
                    for y in stride(from: 0, to: rows, by: 6) {
                        let l = base[0] + y * bpr[0], r = base[1] + y * bpr[1]
                        for i in stride(from: 0, to: ovBytes, by: 2) {
                            seam += abs(Int(l[pitchX + i]) - Int(r[i])); tex += abs(Int(l[pitchX + i]) - Int(l[pitchX + i - 1])); n += 1
                        }
                    }
                }
                if tileRows > 1 {
                    for x in stride(from: 0, to: tw, by: 6) {
                        for j in stride(from: 0, to: ovY, by: 2) {
                            let a = Int(base[0][(pitchY + j) * bpr[0] + x])
                            seam += abs(a - Int(base[cols][j * bpr[cols] + x])); tex += abs(a - Int(base[0][(pitchY + j - 1) * bpr[0] + x])); n += 1
                        }
                    }
                }
                lastSeamDiff = Double(seam) / Double(max(1, n)); lastTextureDiff = Double(tex) / Double(max(1, n))
            }
            // One full-width output row from tile row `tr`, local row `ly`.
            func hrow(_ dst: UnsafeMutablePointer<UInt8>, _ tr: Int, _ ly: Int) {
                for c in 0..<cols {
                    let src = base[tr * cols + c] + ly * bpr[tr * cols + c]
                    let from = c == 0 ? 0 : ovBytes, to = c == cols - 1 ? tw : pitchX
                    memcpy(dst + c * pitchX + from, src + from, to - from)
                    if c < cols - 1 {
                        let r = base[tr * cols + c + 1] + ly * bpr[tr * cols + c + 1]
                        for i in 0..<ovSamples {
                            let wr = 2 * i + 1, wl = 2 * ovSamples - wr
                            for k in (i * step)..<(i * step + step) {
                                dst[(c + 1) * pitchX + k] = UInt8((Int(src[pitchX + k]) * wl + Int(r[k]) * wr + ovSamples) / (2 * ovSamples))
                            }
                        }
                    }
                }
            }
            // Rows are independent: split the frame into bands, one per core, each with its own scratch rows.
            let bands = 8, workW = g.workW
            DispatchQueue.concurrentPerform(iterations: bands) { bi in
                let ra = UnsafeMutablePointer<UInt8>.allocate(capacity: max(2, workW)), rb = UnsafeMutablePointer<UInt8>.allocate(capacity: max(2, workW))
                defer { ra.deallocate(); rb.deallocate() }
                do {
                    for y in (outRows * bi / bands)..<(outRows * (bi + 1) / bands) {
                        let dst = ob + y * obpr
                        let tr = min(tileRows - 1, y / pitchY)        // lower of the tile rows covering y
                        let ly = y - tr * pitchY
                        if tr > 0 && ly < ovY {                        // also covered by the row above
                            hrow(ra, tr - 1, ly + pitchY)
                            hrow(rb, tr, ly)
                            let wb = 2 * ly + 1, wt = 2 * ovY - wb
                            for x in 0..<workW { dst[x] = UInt8((Int(ra[x]) * wt + Int(rb[x]) * wb + ovY) / (2 * ovY)) }
                        } else {
                            hrow(dst, tr, ly)
                        }
                    }
                }
            }
        }
        return out
    }
}

// MARK: - Audio (delayed to match the picture)

/// Plays the capture device's sound later by the same amount the picture is held,
/// so sound and picture stay together.
final class AudioDelay: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    // AVAudioEngine player: buffers are queued behind a block of silence as long as the picture's hold.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var wantedDelayMs = 0.0, delayMs = 0.0
    private var format: AVAudioFormat?
    private var scheduled: Int64 = 0            // frames handed to the player since the last (re)start
    private var needsRestart = true
    private var stopped = false
    private var gainDb = opts.audioGainDb
    private var volume = Float(opts.audioVolume)
    private var baseline: Double?
    private var lastCheck = hostNow()
    private(set) var buffers = 0, resyncs = 0, failures = 0
    weak var session: AVCaptureSession?
    private var dbg = ""
    private var cfgObserver: NSObjectProtocol?

    init(gainDb: Double = opts.audioGainDb, volume: Double = opts.audioVolume) {
        self.gainDb = gainDb
        self.volume = Float(volume)
        super.init()
        engine.attach(player)
        cfgObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.lock.lock(); self?.needsRestart = true; self?.lock.unlock()      // output device changed
        }
    }

    deinit {
        if let cfgObserver { NotificationCenter.default.removeObserver(cfgObserver) }
    }

    func setDelay(_ ms: Double) { lock.lock(); wantedDelayMs = ms; lock.unlock() }
    func updateLevel(gainDb newGain: Double, volume newVol: Double) {
        let vf = Float(newVol)
        lock.lock()
        gainDb = newGain
        volume = vf
        let running = !stopped && engine.isRunning
        lock.unlock()
        if running { player.volume = vf }
    }
    func takeSnapshot() -> (buffers: Int, resyncs: Int, failures: Int, delay: Double, dbg: String) {
        lock.lock(); defer { lock.unlock() }
        let snap = (buffers, resyncs, failures, delayMs, dbg)
        buffers = 0; resyncs = 0; failures = 0
        return snap
    }

    private func restart(_ fmt: AVAudioFormat, delay: Double) -> Bool {
        player.stop()
        if format != fmt || !engine.isRunning {
            engine.stop()
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            do { try engine.start() } catch {
                lock.lock(); dbg = "engine start failed: \(error.localizedDescription)"; lock.unlock()
                return false
            }
            format = fmt
        }
        lock.lock(); let curVol = volume; lock.unlock()
        player.volume = curVol
        scheduled = 0
        baseline = nil; lastCheck = hostNow()
        let n = AVAudioFrameCount(max(1, fmt.sampleRate * min(500, max(0, delay.isFinite ? delay : 0)) / 1000))   // never trust the delay blindly: an absurd value overflowed here
        if let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) {
            silence.frameLength = n
            let abl = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            player.scheduleBuffer(silence); scheduled += Int64(n)
        }
        player.play()
        return true
    }

    private func depthMs(_ fmt: AVAudioFormat) -> Double? {
        guard let rt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: rt) else { return nil }
        return Double(scheduled - pt.sampleTime) / fmt.sampleRate * 1000
    }

    private lazy var rawStereoFmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)

    func stopEngine() {
        lock.lock()
        stopped = true
        lock.unlock()
        player.stop()
        if engine.isRunning { engine.stop() }
    }

    func ingestPCM16Stereo(_ data: Data) {
        let frames = data.count / 4
        guard frames > 0, let fmt = rawStereoFmt,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let left = ch[0], right = ch[1]
        let scale: Float = 1.0 / 32768.0
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let l = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))
                let r = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
                left[i] = Float(l) * scale
                right[i] = Float(r) * scale
            }
        }
        enqueuePCMBuffer(buf, fmt: fmt)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else {
            lock.lock(); failures += 1; lock.unlock(); return
        }
        enqueuePCMBuffer(buf, fmt: fmt)
    }

    private func enqueuePCMBuffer(_ buf: AVAudioPCMBuffer, fmt: AVAudioFormat) {
        let n = buf.frameLength
        // Many HDMI capture cards hand over sound far below normal level: amplify, with a hard limit at full scale.
        lock.lock(); let curGainDb = gainDb; lock.unlock()
        var peak: Float = 0
        if curGainDb != 0, fmt.commonFormat == .pcmFormatFloat32 {
            var g = Float(pow(10.0, curGainDb / 20.0)), lo: Float = -1, hi: Float = 1
            for b in UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList) {
                guard let d = b.mData else { continue }
                let f = d.assumingMemoryBound(to: Float.self), c = vDSP_Length(Int(b.mDataByteSize) / 4)
                vDSP_vsmul(f, 1, &g, f, 1, c)
                vDSP_vclip(f, 1, &lo, &hi, f, 1, c)
                var p: Float = 0; vDSP_maxmgv(f, 1, &p, c); peak = max(peak, p)
            }
        }
        lock.lock()
        if stopped { lock.unlock(); return }
        var restartNow = needsRestart || format != fmt
        // Follow the picture's hold, but only in steps: every change is a small audible skip.
        if abs(wantedDelayMs - delayMs) > 12 { delayMs = wantedDelayMs; restartNow = true }
        let delay = delayMs
        needsRestart = false
        lock.unlock()
        // The audio device's clock drifts against the output's; re-queue when the backlog has wandered.
        let now = hostNow()
        if !restartNow, CMTimeGetSeconds(CMTimeSubtract(now, lastCheck)) > 2 {
            lastCheck = now
            // The measured backlog carries a fixed offset (output latency), so compare against the
            // value seen shortly after the last restart rather than against the nominal delay.
            if let d = depthMs(fmt) {
                // Measured backlog sits about 50 ms above the nominal delay when healthy.
                if d < delay + 10 || d > delay + 95 { restartNow = true; lock.lock(); resyncs += 1; lock.unlock() }
            }
        }
        if restartNow, !restart(fmt, delay: delay) {
            lock.lock(); failures += 1; needsRestart = true; lock.unlock(); return
        }
        player.scheduleBuffer(buf); scheduled += Int64(n)
        let dbgLine = "queued \(Int(depthMs(fmt) ?? -1)) ms, engine \(engine.isRunning), playing \(player.isPlaying), peak \(String(format: "%.2f", peak)), \(Int(fmt.sampleRate)) Hz x\(fmt.channelCount) \(fmt.commonFormat == .pcmFormatFloat32 ? "f32" : "other") \(fmt.isInterleaved ? "interleaved" : "planar")"
        lock.lock(); buffers += 1; dbg = dbgLine; lock.unlock()
    }
}

// MARK: - Modes

enum Mode: Int {
    case pass = 1      // show frames as they arrive
    case single = 2    // 30 -> 60, generated frames computed at 720p
    case tiled = 3     // 30 -> 60, 2x2 tiles, everything at ~2K
    case rifeFast = 4      // 30 -> 60 on the GPU, whole frame at capture size, motion estimated at 1/4 size
    case rifeBalanced = 5  // same, motion estimated at 1/2 size
    case rifeMedium = 6    // "4.5 tier": motion estimated at 1/3 size (1280x768 at 4K), full 4K warp+blend
    var rifeTier: RifeQualityTier? {
        switch self {
        case .rifeFast: return .fast
        case .rifeMedium: return .medium
        case .rifeBalanced: return .balanced
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .pass: return "[1] 直通·不补帧"
        case .single: return "[2] 补帧·最低延迟（补的帧偏软）"
        case .tiled: return "[3] 补帧·分块算"
        case .rifeFast: return "[4] 补帧·显卡·延迟低"
        case .rifeBalanced: return "[5] 补帧·显卡·画质好"
        case .rifeMedium: return "[6] 补帧·显卡·均衡4.5档"
        }
    }
}

// MARK: - Background sample collector (non-blocking ring buffer + async raw NV12 dump)

final class SampleCollector {
    enum Kind: String, CaseIterable {
        case occlusion = "occlusion"      // centre character steady while surrounding background moves fast
        case fastPan = "fast_pan"         // sustained whole-screen rapid camera whip
        case sceneCut = "scene_cut"       // abrupt camera/UI cut between two frames
        case stutterGap = "stutter_gap"   // game itself dropped frames (46-90 ms gap) during motion
    }
    private struct SlotMeta: Codable {
        var seq: Int
        var ptsSec: Double
        var gapMs: Double
        var mode: Int
        var allDiff: Double
        var centerDiff: Double
        var outerDiff: Double
        var meanY: Double
        var texGrad: Double
    }
    private struct ClipMeta: Codable {
        var kind: String
        var createdBeijing: String
        var width: Int
        var height: Int
        var pixelFormat: String
        var frameBytes: Int
        var frameCount: Int
        var triggerFrameOffset: Int
        var frames: [SlotMeta]
    }

    private let ringCap = 34
    private let perSessionAutoLimit = 4
    private let onDiskAutoCap = 8
    private let manualSessionLimit = 12
    private let ringQueue = DispatchQueue(label: "collector.ring", qos: .userInitiated)
    private let diskQueue = DispatchQueue(label: "collector.disk", qos: .utility)
    private let previewCtx = CIContext(options: [.useSoftwareRenderer: false])
    private let stateLock = NSLock()
    private var copyInFlight = false
    private var savedTotal = 0

    // Owned exclusively by ringQueue:
    private var ringW = 0, ringH = 0, frameBytes = 0
    private var pixFmt = "420v"
    private var slots: [Data] = []
    private var metas: [SlotMeta] = []
    private var head = 0, count = 0, seq = 0, warmupSeen = 0
    private var lastAutoSeq = -1000
    private var occStreak = 0
    private var prevAllDiff = 0.0
    private var sessionCounts: [Kind: Int] = [:]
    private var diskCounts: [Kind: Int] = [:]
    private var manualCount = 0
    private var pendingAuto: (kind: Kind, triggerSeq: Int, dueSeq: Int)?

    var totalSaved: Int { stateLock.lock(); defer { stateLock.unlock() }; return savedTotal }

    init() {
        guard opts.collect, !opts.list, !opts.selftest else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: opts.sampleDir, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(atPath: opts.sampleDir)) ?? []
        var existingAuto = 0
        for k in Kind.allCases {
            let c = items.filter { $0.contains("_\(k.rawValue)_") }.count
            diskCounts[k] = c; existingAuto += c
        }
        stateLock.lock(); savedTotal = items.filter { $0.hasPrefix("20") }.count; stateLock.unlock()
        Log.shared.line("collector: on -> \(opts.sampleDir) (existing auto \(existingAuto), press S to save last 1 s)")
    }

    /// Non-blocking entry point from Pipeline.handle. At most one frame is ever held in flight (~0.15 ms copy).
    func observe(_ pb: CVPixelBuffer, pts: CMTime, gapMs: Double, mode: Mode) {
        guard opts.collect, CVPixelBufferGetPlaneCount(pb) == 2 else { return }
        let sub = CVPixelBufferGetPixelFormatType(pb)
        guard sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return }
        stateLock.lock()
        if copyInFlight { stateLock.unlock(); return }
        copyInFlight = true
        stateLock.unlock()
        let ptsSec = CMTimeGetSeconds(pts), fmtStr = fourCC(sub), modeRaw = mode.rawValue
        ringQueue.async {
            self.ingest(pb, ptsSec: ptsSec, gapMs: gapMs, fmtStr: fmtStr, modeRaw: modeRaw)
        }
    }

    private func ingest(_ pb: CVPixelBuffer, ptsSec: Double, gapMs: Double, fmtStr: String, modeRaw: Int) {
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        guard w >= 64, h >= 64, w % 2 == 0, h % 2 == 0 else {
            stateLock.lock(); copyInFlight = false; stateLock.unlock(); return
        }
        let needBytes = w * h + w * (h / 2)
        if w != ringW || h != ringH || needBytes != frameBytes {
            ringW = w; ringH = h; frameBytes = needBytes; pixFmt = fmtStr
            slots = (0..<ringCap).map { _ in Data(count: needBytes) }
            metas = Array(repeating: SlotMeta(seq: 0, ptsSec: 0, gapMs: 0, mode: 0, allDiff: 0, centerDiff: 0, outerDiff: 0, meanY: 0, texGrad: 0), count: ringCap)
            head = 0; count = 0; warmupSeen = 0; pendingAuto = nil; occStreak = 0; prevAllDiff = 0
        }
        let slotIdx = head
        // Copy both NV12 planes tightly and unlock/release the capture buffer immediately.
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        if let ySrc = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
           let uvSrc = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            slots[slotIdx].withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.baseAddress else { return }
                for r in 0..<h { memcpy(dst + r * w, ySrc + r * yBpr, w) }
                let uvDst = dst + w * h
                for r in 0..<(h / 2) { memcpy(uvDst + r * w, uvSrc + r * uvBpr, w) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        stateLock.lock(); copyInFlight = false; stateLock.unlock()

        // Sparse regional luma analysis on our private copy (zero contention with capture/GPU).
        seq += 1; warmupSeen += 1
        var allDiff = 0.0, centerDiff = 0.0, outerDiff = 0.0, meanY = 0.0, texGrad = 0.0
        if count > 0 {
            let prevIdx = (head - 1 + ringCap) % ringCap
            slots[slotIdx].withUnsafeBytes { curRaw in
                slots[prevIdx].withUnsafeBytes { prevRaw in
                    let cur = curRaw.bindMemory(to: UInt8.self).baseAddress!
                    let prv = prevRaw.bindMemory(to: UInt8.self).baseAddress!
                    let cx0 = w * 35 / 100, cx1 = w * 65 / 100
                    let cy0 = h * 22 / 100, cy1 = h * 85 / 100
                    let hudX = w * 22 / 100, hudY = h * 75 / 100, subY = h * 88 / 100
                    var sumAll = 0, nAll = 0, sumCen = 0, nCen = 0, sumOut = 0, nOut = 0
                    var sumY = 0, sumGrad = 0
                    var y = 12
                    while y < h - 12 {
                        let row = y * w
                        var x = 12
                        while x < w - 16 {
                            let c = Int(cur[row + x]), p = Int(prv[row + x])
                            let d = abs(c - p)
                            sumAll += d; nAll += 1
                            sumY += c; sumGrad += abs(c - Int(cur[row + x + 4]))
                            if x >= cx0 && x < cx1 && y >= cy0 && y < cy1 {
                                sumCen += d; nCen += 1
                            } else if !(x < hudX && y > hudY) && y < subY {
                                sumOut += d; nOut += 1
                            }
                            x += 24
                        }
                        y += 24
                    }
                    if nAll > 0 {
                        allDiff = Double(sumAll) / Double(nAll)
                        meanY = Double(sumY) / Double(nAll)
                        texGrad = Double(sumGrad) / Double(nAll)
                    }
                    if nCen > 0 { centerDiff = Double(sumCen) / Double(nCen) }
                    if nOut > 0 { outerDiff = Double(sumOut) / Double(nOut) }
                }
            }
        }
        metas[slotIdx] = SlotMeta(seq: seq, ptsSec: ptsSec, gapMs: gapMs, mode: modeRaw,
                                  allDiff: allDiff, centerDiff: centerDiff, outerDiff: outerDiff,
                                  meanY: meanY, texGrad: texGrad)
        head = (head + 1) % ringCap
        if count < ringCap { count += 1 }

        // Fulfill any pending auto-capture once 2 post-event frames have arrived.
        if let pend = pendingAuto, seq >= pend.dueSeq {
            pendingAuto = nil
            flushWindow(kind: pend.kind.rawValue, maxFrames: 6, triggerSeq: pend.triggerSeq, notify: nil)
        } else if pendingAuto == nil, warmupSeen > 150, count >= 6, seq - lastAutoSeq >= 240, meanY >= 12.0, texGrad >= 1.5 {
            if outerDiff >= 10.0 && outerDiff >= centerDiff * 2.0 && centerDiff <= 9.0 && allDiff < 42.0 {
                occStreak += 1
            } else {
                occStreak = 0
            }
            var hit: Kind? = nil
            if canAuto(.sceneCut), allDiff >= 42.0, prevAllDiff < 20.0 {
                hit = .sceneCut
            } else if canAuto(.stutterGap), gapMs >= 46.0, gapMs <= 95.0, allDiff >= 6.0 {
                hit = .stutterGap
            } else if canAuto(.occlusion), occStreak >= 2 {
                hit = .occlusion; occStreak = 0
            } else if canAuto(.fastPan), allDiff >= 20.0, allDiff < 42.0, prevAllDiff >= 12.0 {
                hit = .fastPan
            }
            if let k = hit {
                sessionCounts[k, default: 0] += 1
                diskCounts[k, default: 0] += 1
                lastAutoSeq = seq
                pendingAuto = (k, seq, seq + 2)
            }
        }
        prevAllDiff = allDiff
    }

    private func canAuto(_ k: Kind) -> Bool {
        (sessionCounts[k] ?? 0) < perSessionAutoLimit && (diskCounts[k] ?? 0) < onDiskAutoCap
    }

    /// Key S: snapshot the last ~1 s (up to 30 frames) immediately without stalling gameplay.
    func saveManual(notify: @escaping (String) -> Void) {
        guard opts.collect else { DispatchQueue.main.async { notify("样本收集已关闭（--no-collect）") }; return }
        ringQueue.async {
            guard self.count >= 2, self.frameBytes > 0 else {
                DispatchQueue.main.async { notify("画面刚启动，还没有可保存的帧") }; return
            }
            guard self.manualCount < self.manualSessionLimit else {
                DispatchQueue.main.async { notify("本次手动抓拍已满 \(self.manualSessionLimit) 组上限") }; return
            }
            self.manualCount += 1
            let idx = self.manualCount
            self.flushWindow(kind: String(format: "manual_%02d", idx), maxFrames: min(30, self.count), triggerSeq: self.seq, notify: notify)
        }
    }

    private func flushWindow(kind: String, maxFrames: Int, triggerSeq: Int, notify: ((String) -> Void)?) {
        let take = min(maxFrames, count)
        guard take >= 2 else { return }
        var copiedFrames: [Data] = []
        var copiedMetas: [SlotMeta] = []
        copiedFrames.reserveCapacity(take); copiedMetas.reserveCapacity(take)
        let start = (head - take + ringCap) % ringCap
        for i in 0..<take {
            let idx = (start + i) % ringCap
            copiedFrames.append(Data(slots[idx]))   // value copy on ringQueue (~2 ms for 6 frames, ~8 ms for 30)
            copiedMetas.append(metas[idx])
        }
        let w = ringW, h = ringH, fb = frameBytes, fmt = pixFmt
        let trigOffset = copiedMetas.firstIndex(where: { $0.seq == triggerSeq }) ?? (take - 1)
        diskQueue.async {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "Asia/Shanghai")
            df.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = df.string(from: Date())
            self.stateLock.lock(); self.savedTotal += 1; let num = self.savedTotal; self.stateLock.unlock()
            let folderName = String(format: "%@_%@_%03d", stamp, kind, num)
            let dir = opts.sampleDir + "/" + folderName
            let fm = FileManager.default
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let nv12URL = URL(fileURLWithPath: dir + "/frames.nv12")
                fm.createFile(atPath: nv12URL.path, contents: nil)
                let fh = try FileHandle(forWritingTo: nv12URL)
                for d in copiedFrames { fh.write(d) }
                try fh.close()

                let clip = ClipMeta(kind: kind, createdBeijing: stamp, width: w, height: h,
                                    pixelFormat: fmt, frameBytes: fb, frameCount: take,
                                    triggerFrameOffset: trigOffset, frames: copiedMetas)
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = try enc.encode(clip)
                try json.write(to: URL(fileURLWithPath: dir + "/meta.json"))

                self.writePreview(nv12: copiedFrames[trigOffset], width: w, height: h, fmt: fmt, to: dir + "/preview.jpg")
                let trigMeta = copiedMetas[trigOffset]
                Log.shared.line(String(format: "sample saved: %@ (%d frames, %dx%d, allDiff %.1f center %.1f outer %.1f gap %.1f ms)",
                                       folderName, take, w, h, trigMeta.allDiff, trigMeta.centerDiff, trigMeta.outerDiff, trigMeta.gapMs))
                if let notify {
                    DispatchQueue.main.async { notify("已抓拍刚才 \(take) 张原画（\(folderName)）") }
                }
            } catch {
                Log.shared.line("sample save failed: \(error.localizedDescription)")
                if let notify { DispatchQueue.main.async { notify("抓拍保存失败：\(error.localizedDescription)") } }
            }
        }
    }

    private func writePreview(nv12: Data, width: Int, height: Int, fmt: String, to path: String) {
        let ost: OSType = fmt == "420f" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, ost, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        nv12.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.baseAddress else { return }
            if let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                for r in 0..<height { memcpy(yDst + r * yBpr, src + r * width, width) }
                let uvSrc = src + width * height
                for r in 0..<(height / 2) { memcpy(uvDst + r * uvBpr, uvSrc + r * width, width) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var ci = CIImage(cvPixelBuffer: pb)
        if width > 1280 {
            let s = 1280.0 / Double(width)
            ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
            try? previewCtx.writeJPEGRepresentation(of: ci, to: URL(fileURLWithPath: path), colorSpace: cs,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
        }
    }
}



/// Same rule as RifeEngine.protectStill, as one Metal compute pass over the frame (well under a millisecond at 4K
/// instead of 2-8 ms on the CPU): where both originals agree over a short horizontal run, the generated frame
/// takes the current original's pixel.
final class StillProtector {
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLComputePipelineState
    private(set) var splitTexMs = 0.0, splitWaitMs = 0.0, splitGpuMs = 0.0, splitQueuedMs = 0.0
    private var cache: CVMetalTextureCache?
    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        inline float luma(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

        /// Contrast-anchored 2D UI/subtitle protector:
        /// Protects static high-contrast strokes/icons (subtitles, button prompts, minimap lines) while
        /// ignoring flat low-contrast dark regions so moving night shadows never punch jagged patches.
        kernel void protectStill(texture2d<float, access::read> prev [[texture(0)]],
                                 texture2d<float, access::read> cur [[texture(1)]],
                                 texture2d<float, access::read_write> mid [[texture(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            int w = cur.get_width(), h = cur.get_height();
            if (int(gid.x) >= w || int(gid.y) >= h) return;

            const float tol = 3.5f / 255.0f;
            float4 curC = cur.read(gid);
            float3 d0 = abs(prev.read(gid).rgb - curC.rgb);
            if (max(d0.r, max(d0.g, d0.b)) > tol) return;

            int stillCount = 0;
            float minY = 1.0f, maxY = 0.0f;
            for (int dy = -1; dy <= 1; dy++) {
                uint py = uint(clamp(int(gid.y) + dy, 0, h - 1));
                for (int dx = -2; dx <= 2; dx++) {
                    uint2 p = uint2(uint(clamp(int(gid.x) + dx, 0, w - 1)), py);
                    float3 cp = cur.read(p).rgb;
                    float3 dp = abs(prev.read(p).rgb - cp);
                    if (max(dp.r, max(dp.g, dp.b)) <= tol) stillCount++;
                    float y = luma(cp);
                    minY = min(minY, y);
                    maxY = max(maxY, y);
                }
            }
            if (stillCount < 13) return;

            const int2 arms[4] = { int2(-5, 0), int2(5, 0), int2(0, -5), int2(0, 5) };
            for (int k = 0; k < 4; k++) {
                uint2 p = uint2(uint(clamp(int(gid.x) + arms[k].x, 0, w - 1)),
                                uint(clamp(int(gid.y) + arms[k].y, 0, h - 1)));
                float y = luma(cur.read(p).rgb);
                minY = min(minY, y);
                maxY = max(maxY, y);
            }
            float contrast = maxY - minY;
            if (contrast < (28.0f / 255.0f)) return;

            float blend = clamp((contrast - 28.0f / 255.0f) / (20.0f / 255.0f), 0.0f, 1.0f);
            float4 midC = mid.read(gid);
            mid.write(mix(midC, curC, blend), gid);
        }
        """
        guard let lib = try? d.makeLibrary(source: src, options: nil), let f = lib.makeFunction(name: "protectStill"),
              let p = try? d.makeComputePipelineState(function: f) else { return nil }
        device = d; queue = q; pipeline = p
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
    }
    private func texture(_ pb: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        guard let cache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        guard let t, let m = CVMetalTextureGetTexture(t) else { return nil }
        return (t, m)
    }
    func apply(previous: CVPixelBuffer, current: CVPixelBuffer, mid: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(previous) == CVPixelBufferGetWidth(mid), CVPixelBufferGetHeight(previous) == CVPixelBufferGetHeight(mid),
              CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(mid), CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(mid),
              let t0 = Optional(CACurrentMediaTime()),
              let a = texture(previous), let b = texture(current), let m = texture(mid),
              let t1 = Optional(CACurrentMediaTime()),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(a.1, index: 0); enc.setTexture(b.1, index: 1); enc.setTexture(m.1, index: 2)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreadgroups(MTLSize(width: (m.1.width + tw - 1) / tw, height: (m.1.height + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        // Diagnosis (this step creeps up over minutes): where does its time go?
        let t2 = CACurrentMediaTime()
        splitTexMs = (t1 - t0) * 1000; splitWaitMs = (t2 - t1) * 1000; splitGpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        splitQueuedMs = (cb.gpuStartTime - t1) * 1000
        // The generated picture is a new buffer every time, so the texture cache gains three entries per picture and
        // never drops them by itself: over an hour of play this step crept from 2 ms to 25 ms (2026-11-19, pictures
        // then overran the 33 ms budget). Flushing lets it forget textures whose buffers are gone.
        CVMetalTextureCacheFlush(cache!, 0)
        return cb.status == .completed
    }
}

// MARK: - GPU interpolator (RIFE on Metal: one pass over the whole frame, no tiles)

final class RifeEngine {
    private let interpolator: RifeInterpolator
    private let stream: RifeStream
    private var transfer: VTPixelTransferSession?
    private let pool: BufferPool
    private let outPool: BufferPool
    private(set) var lastConvertMs = 0.0, lastEngineMs = 0.0
    /// Every picture of the current report period (the "last" values above are one sample per second and can mislead).
    var convertSamples: [Double] = [], engineSamples: [Double] = []

    init?(width: Int, height: Int, tier: RifeQualityTier) {
        do {
            let i = try RifeInterpolator(configuration: .bundled(qualityTier: tier))
            let s = try i.makeStream(width: width, height: height)
            interpolator = i; stream = s
        } catch { Log.shared.line("rife unavailable: \(error)"); return nil }
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true]
        pool = BufferPool(width: width, height: height, format: kCVPixelFormatType_32BGRA, attrs: attrs)
        outPool = BufferPool(width: width, height: height, format: kCVPixelFormatType_32BGRA, attrs: attrs)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }
    /// The engine takes BGRA; the capture card delivers NV12.
    func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let t0 = CACurrentMediaTime(); defer { lastConvertMs = (CACurrentMediaTime() - t0) * 1000; convertSamples.append(lastConvertMs) }
        guard let transfer, let dst = pool.get() else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: dst) == noErr else { return nil }
        return dst
    }
    private(set) var lastProtectMs = 0.0, lastProtectedShare = 0.0
    /// Subtitles, HUD and other overlays do not move, but the motion estimate drags them along with the picture
    /// behind them, so in every generated frame they are bent a little: on screen they flicker at 30 Hz.
    /// Wherever a pixel (and its neighbours in the row) is the same in both originals, the generated frame takes
    /// the original pixel instead.
    func protectStill(previous: CVPixelBuffer, current: CVPixelBuffer, mid: CVPixelBuffer) {
        let t0 = CACurrentMediaTime(); defer { lastProtectMs = (CACurrentMediaTime() - t0) * 1000 }
        CVPixelBufferLockBaseAddress(previous, .readOnly); CVPixelBufferLockBaseAddress(current, .readOnly); CVPixelBufferLockBaseAddress(mid, [])
        defer { CVPixelBufferUnlockBaseAddress(mid, []); CVPixelBufferUnlockBaseAddress(current, .readOnly); CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
        guard let pp = CVPixelBufferGetBaseAddress(previous)?.assumingMemoryBound(to: UInt8.self),
              let pc = CVPixelBufferGetBaseAddress(current)?.assumingMemoryBound(to: UInt8.self),
              let pm = CVPixelBufferGetBaseAddress(mid)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(mid), h = CVPixelBufferGetHeight(mid)
        guard CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetWidth(current) == w, CVPixelBufferGetHeight(previous) == h, CVPixelBufferGetHeight(current) == h else { return }
        let rp = CVPixelBufferGetBytesPerRow(previous), rc = CVPixelBufferGetBytesPerRow(current), rm = CVPixelBufferGetBytesPerRow(mid)
        let bands = 12, tol = 3, minRun = 4
        var protected = [Int](repeating: 0, count: bands)
        protected.withUnsafeMutableBufferPointer { counts in
            let counts = counts.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { bi in
                var n = 0
                for y in (h * bi / bands)..<(h * (bi + 1) / bands) {
                    let a = pp + y * rp, b = pc + y * rc, m = pm + y * rm
                    var run = 0
                    for x in 0..<w {
                        let i = x * 4
                        let still = abs(Int(a[i]) - Int(b[i])) <= tol && abs(Int(a[i+1]) - Int(b[i+1])) <= tol && abs(Int(a[i+2]) - Int(b[i+2])) <= tol
                        if still { run += 1 } else {
                            if run >= minRun { memcpy(m + (x - run) * 4, b + (x - run) * 4, run * 4); n += run }
                            run = 0
                        }
                    }
                    if run >= minRun { memcpy(m + (w - run) * 4, b + (w - run) * 4, run * 4); n += run }
                }
                counts[bi] = n
            }
        }
        lastProtectedShare = Double(protected.reduce(0, +)) / Double(max(1, w * h))
    }
    /// Several in-between pictures at once (e.g. 1/3 and 2/3 when the game held a picture for three refreshes).
    func push(_ frame: CVPixelBuffer, timesteps: [Float]) -> [CVPixelBuffer] {
        let t0 = CACurrentMediaTime(); defer { lastEngineMs = (CACurrentMediaTime() - t0) * 1000; engineSamples.append(lastEngineMs) }
        do { return try stream.push(frame, timesteps: timesteps) } catch { Log.shared.line("rife error: \(error)"); stream.reset(); return [] }
    }
    func reset() { stream.reset() }
    /// Midpoint between the previously pushed frame and this one; nil on the first frame after a reset.
    func push(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let t0 = CACurrentMediaTime(); defer { lastEngineMs = (CACurrentMediaTime() - t0) * 1000; engineSamples.append(lastEngineMs) }
        guard let dst = outPool.get() else { return nil }
        do { return (try stream.push(frame, into: dst)) ? dst : nil } catch { Log.shared.line("rife error: \(error)"); stream.reset(); return nil }
    }

    /// Fused single-command-buffer step: converts NV12 capture IOSurface -> BGRA, skips 337 MB full-res
    /// intermediate copies, runs IFNet + edge-guided 4K warp/blend, and runs GPU subtitle protection in one pass.
    func stepFused(source: CVPixelBuffer,
                   consecutive: Bool,
                   timesteps: [Float]?,
                   gpuProtect: Bool,
                   casStrength: Float = 0.0) -> (currBGRA: CVPixelBuffer, mids: [CVPixelBuffer])? {
        let srcFmt = CVPixelBufferGetPixelFormatType(source)
        let isNV12 = (srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                      srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) &&
                     (CVPixelBufferGetIOSurface(source) != nil)
        let currBGRA: CVPixelBuffer
        let nv12Arg: CVPixelBuffer?
        if isNV12 {
            guard let dst = pool.get() else { return nil }
            copyColor(from: source, to: dst)
            currBGRA = dst
            nv12Arg = source
            lastConvertMs = 0.0
            convertSamples.append(0.0)
        } else {
            guard let dst = convert(source) else { return nil }
            copyColor(from: source, to: dst)
            currBGRA = dst
            nv12Arg = nil
        }

        if !consecutive { stream.reset() }

        let t0 = CACurrentMediaTime()
        defer { lastEngineMs = (CACurrentMediaTime() - t0) * 1000; engineSamples.append(lastEngineMs) }

        do {
            if let ts = timesteps, !ts.isEmpty {
                var outs: [CVPixelBuffer] = []
                outs.reserveCapacity(ts.count)
                for _ in ts {
                    guard let o = outPool.get() else { return nil }
                    copyColor(from: currBGRA, to: o)
                    outs.append(o)
                }
                let produced = try stream.pushFused(
                    nv12Source: nv12Arg,
                    currBGRA: currBGRA,
                    timesteps: ts,
                    outputs: outs,
                    protectStill: gpuProtect,
                    casStrength: casStrength
                )
                return (currBGRA, produced ? outs : [])
            } else {
                guard let o = outPool.get() else { return nil }
                copyColor(from: currBGRA, to: o)
                let produced = try stream.pushFused(
                    nv12Source: nv12Arg,
                    currBGRA: currBGRA,
                    into: o,
                    protectStill: gpuProtect,
                    casStrength: casStrength
                )
                return (currBGRA, produced ? [o] : [])
            }
        } catch {
            Log.shared.line("rife fused error: \(error)")
            stream.reset()
            return nil
        }
    }
}

// MARK: - Privileged UVC Bulk Helper Client (Shared IOSurface Ring)

@_silgen_name("bootstrap_register")
private func c_bootstrap_register(_ bp: mach_port_t, _ serviceName: UnsafePointer<CChar>, _ sp: mach_port_t) -> kern_return_t

@_silgen_name("bootstrap_look_up")
private func c_bootstrap_look_up(_ bp: mach_port_t, _ serviceName: UnsafePointer<CChar>, _ sp: UnsafeMutablePointer<mach_port_t>) -> kern_return_t

/// Ties the kernel IOSurface use count to a CVPixelBuffer's lifetime so the helper never overwrites
/// a ring slot while CPU, RIFE/Metal, SampleCollector, or the display layer still holds the frame.
private final class SurfaceLease {
    let surface: IOSurfaceRef
    init(_ surface: IOSurfaceRef) {
        self.surface = surface
        IOSurfaceIncrementUseCount(surface)
    }
    deinit {
        IOSurfaceDecrementUseCount(surface)
    }
}

final class RawUVCCapture {
    static let installedHelperPath = "/usr/local/libexec/captureinterp-uvc-helper"
    static let ringSlots = 8
    private static let helloMagic: UInt32 = 0x55564348 // "UVCH"
    private static let helloFlagAudio: UInt32 = 0x00010000
    private static let readyMagic: UInt32 = 0x55565244 // "UVRD"
    static let readyFlagHelperAudio = 0x00000100
    static let readyFlagCapturedDevice = 0x00000200
    private static let frameMagic: UInt32 = 0x55564652 // "UVFR"
    private static let audioMagic: UInt32 = 0x55564155 // "UVAU"
    private static let portMsgID: mach_msg_id_t = 0x55565054 // "UVPT"
    private static let leaseKey: CFString = "local.captureinterp.surface.lease" as CFString

    private struct RecvPortsMsg {
        var hdr: mach_msg_header_t
        var body: mach_msg_body_t
        var p0: mach_msg_port_descriptor_t
        var p1: mach_msg_port_descriptor_t
        var p2: mach_msg_port_descriptor_t
        var p3: mach_msg_port_descriptor_t
        var p4: mach_msg_port_descriptor_t
        var p5: mach_msg_port_descriptor_t
        var p6: mach_msg_port_descriptor_t
        var p7: mach_msg_port_descriptor_t
        var trailer: mach_msg_trailer_t
    }

    private struct SendPortsMsg {
        var hdr: mach_msg_header_t
        var body: mach_msg_body_t
        var p0: mach_msg_port_descriptor_t
        var p1: mach_msg_port_descriptor_t
        var p2: mach_msg_port_descriptor_t
        var p3: mach_msg_port_descriptor_t
        var p4: mach_msg_port_descriptor_t
        var p5: mach_msg_port_descriptor_t
        var p6: mach_msg_port_descriptor_t
        var p7: mach_msg_port_descriptor_t
    }

    private let stateLock = NSLock()
    private var stopping = false
    private var proc: Process?
    private var inWriteFD: Int32 = -1
    private var pipeIn: Pipe?
    private var watchdog: DispatchSourceTimer?
    private var lastFrameMonoNs: UInt64 = 0

    var onFrame: ((CVPixelBuffer, CMTime, CMTime) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onUnexpectedExit: (() -> Void)?

    /// Verifies that the helper binary and every ancestor directory are root-owned, non-symlink,
    /// and neither group-writable nor world-writable before invoking sudo -n.
    static func verifyHelperBinary(_ path: String) -> (ok: Bool, reason: String) {
        guard path.hasPrefix("/") else { return (false, "helper path must be absolute") }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return (false, "empty helper path") }
        var cur = ""
        for (idx, part) in parts.enumerated() {
            cur += "/" + part
            var st = stat()
            if lstat(cur, &st) != 0 {
                return (false, "missing \(cur)")
            }
            let ftype = st.st_mode & S_IFMT
            if ftype == S_IFLNK {
                return (false, "refusing symlink \(cur)")
            }
            let isLast = (idx == parts.count - 1)
            if isLast {
                if ftype != S_IFREG { return (false, "not a regular file: \(cur)") }
                if (st.st_mode & 0o111) == 0 { return (false, "not executable: \(cur)") }
            } else {
                if ftype != S_IFDIR { return (false, "not a directory: \(cur)") }
            }
            if st.st_uid != 0 {
                return (false, "\(cur) not owned by root (uid=\(st.st_uid))")
            }
            if (st.st_mode & 0o022) != 0 {
                return (false, "\(cur) is group/world writable")
            }
        }
        return (true, "ok")
    }

    static func desiredModeName(maxWidth: Int, fps: Double) -> String {
        if maxWidth > 0 && maxWidth < 2560 { return "1080p60" }
        if maxWidth > 0 && maxWidth < 3840 { return "2k60" }
        return fps < 45 ? "4k30" : "4k60"
    }

    /// Best-effort software release of USB capture state if a prior helper died on SIGKILL.
    static func runRecoverIfInstalled() {
        guard verifyHelperBinary(installedHelperPath).ok else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", installedHelperPath, "--recover"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline { usleep(40_000) }
            if p.isRunning { p.terminate() }
        } catch {}
    }

    private static func writeFull(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = Darwin.write(fd, bytes.advanced(by: off), count - off)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            off += n
        }
        return true
    }

    private static func readFull(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = Darwin.read(fd, bytes.advanced(by: off), count - off)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            off += n
        }
        return true
    }

    private static func pollReadable(_ fd: Int32, timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let r = Darwin.poll(&pfd, 1, timeoutMs)
            if r < 0 && errno == EINTR { continue }
            return r > 0 && (pfd.revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0
        }
    }

    private static func readNonBlockingString(_ fd: Int32) -> String {
        guard pollReadable(fd, timeoutMs: 20) else { return "" }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(bytes: buf[0..<n], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func packHello(clientPid: UInt32, ringSlots: UInt32, nonce: UInt64, wantAudio: Bool) -> Data {
        var d = Data(capacity: 24)
        var m = helloMagic.littleEndian; withUnsafeBytes(of: &m) { d.append(contentsOf: $0) }
        let verBits: UInt32 = 1 | (wantAudio ? helloFlagAudio : 0)
        var v = verBits.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
        var p = clientPid.littleEndian; withUnsafeBytes(of: &p) { d.append(contentsOf: $0) }
        var r = ringSlots.littleEndian; withUnsafeBytes(of: &r) { d.append(contentsOf: $0) }
        var n = nonce.littleEndian; withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        return d
    }

    func start(modeName: String, wantAudio: Bool) -> (ok: Bool, width: Int, height: Int, usbSpeed: Int, reason: String) {
        signal(SIGPIPE, SIG_IGN)
        let check = Self.verifyHelperBinary(Self.installedHelperPath)
        guard check.ok else {
            return (false, 0, 0, 0, "\(check.reason) (run sudo ./tools/install_uvc_helper.sh)")
        }

        let pIn = Pipe(), pOut = Pipe(), pErr = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Self.installedHelperPath, "--mode", modeName]
        p.standardInput = pIn
        p.standardOutput = pOut
        p.standardError = pErr

        let tLaunch = CACurrentMediaTime()
        do {
            try p.run()
        } catch {
            return (false, 0, 0, 0, "sudo launch failed: \(error.localizedDescription)")
        }

        let res = handshakeAndStartLoop(
            writeFD: pIn.fileHandleForWriting.fileDescriptor,
            readFD: pOut.fileHandleForReading.fileDescriptor,
            errHandle: pErr.fileHandleForReading,
            process: p,
            pipes: (pIn, pOut, pErr),
            wantAudio: wantAudio
        )
        if !res.ok {
            try? pIn.fileHandleForWriting.close()
            try? pOut.fileHandleForReading.close()
            try? pErr.fileHandleForReading.close()
            if p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(1.2)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            // If helper ran long enough to touch USB before failing, let DriverKit settle before AVFoundation fallback
            if CACurrentMediaTime() - tLaunch > 0.15 { usleep(800_000) }
        }
        return res
    }

    fileprivate func handshakeAndStartLoop(
        writeFD: Int32,
        readFD: Int32,
        errHandle: FileHandle?,
        process: Process?,
        pipes: (Pipe, Pipe, Pipe)?,
        wantAudio: Bool = false
    ) -> (ok: Bool, width: Int, height: Int, usbSpeed: Int, reason: String) {
        signal(SIGPIPE, SIG_IGN)
        var bp: mach_port_t = 0
        guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bp) == KERN_SUCCESS else {
            return (false, 0, 0, 0, "bootstrap port unavailable")
        }
        var srvPort: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &srvPort) == KERN_SUCCESS else {
            return (false, 0, 0, 0, "mach_port_allocate failed")
        }
        _ = mach_port_insert_right(mach_task_self_, srvPort, srvPort, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        defer {
            mach_port_deallocate(mach_task_self_, srvPort)
            mach_port_mod_refs(mach_task_self_, srvPort, MACH_PORT_RIGHT_RECEIVE, -1)
        }

        let nonce = UInt64.random(in: 1...UInt64.max)
        let svcName = String(format: "local.captureinterp.uvc.%u.%016llx", UInt32(getpid()), nonce)
        let regKr = svcName.withCString { c_bootstrap_register(bp, $0, srvPort) }
        guard regKr == KERN_SUCCESS else {
            return (false, 0, 0, 0, String(format: "bootstrap_register failed (0x%x)", regKr))
        }

        let errFD = errHandle?.fileDescriptor ?? -1
        let hello = Self.packHello(clientPid: UInt32(getpid()), ringSlots: UInt32(Self.ringSlots), nonce: nonce, wantAudio: wantAudio)
        let wroteHello = hello.withUnsafeBytes { raw in
            Self.writeFull(writeFD, raw.baseAddress!, raw.count)
        }
        guard wroteHello else {
            let errText = errFD >= 0 ? Self.readNonBlockingString(errFD) : ""
            return (false, 0, 0, 0, errText.isEmpty ? "helper handshake write failed (sudo NOPASSWD not configured?)" : errText)
        }

        var rmsg = RecvPortsMsg(
            hdr: mach_msg_header_t(), body: mach_msg_body_t(),
            p0: mach_msg_port_descriptor_t(), p1: mach_msg_port_descriptor_t(),
            p2: mach_msg_port_descriptor_t(), p3: mach_msg_port_descriptor_t(),
            p4: mach_msg_port_descriptor_t(), p5: mach_msg_port_descriptor_t(),
            p6: mach_msg_port_descriptor_t(), p7: mach_msg_port_descriptor_t(),
            trailer: mach_msg_trailer_t()
        )
        // Poll Mach receive in 100 ms steps so an immediate sudo/helper exit returns in <150 ms instead of 3.5 s.
        var rcvKr: kern_return_t = MACH_RCV_TIMED_OUT
        for _ in 0..<35 {
            rcvKr = withUnsafeMutablePointer(to: &rmsg) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) { hdrPtr in
                    mach_msg(hdrPtr, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                             mach_msg_size_t(MemoryLayout<RecvPortsMsg>.size), srvPort, 100, mach_port_t(MACH_PORT_NULL))
                }
            }
            if rcvKr == KERN_SUCCESS { break }
            if let p = process, !p.isRunning { break }
        }
        guard rcvKr == KERN_SUCCESS, rmsg.hdr.msgh_id == Self.portMsgID, rmsg.body.msgh_descriptor_count == UInt32(Self.ringSlots) else {
            let errText = errFD >= 0 ? Self.readNonBlockingString(errFD) : ""
            return (false, 0, 0, 0, errText.isEmpty ? String(format: "helper port recv failed (0x%x)", rcvKr) : errText)
        }

        let portList = [rmsg.p0.name, rmsg.p1.name, rmsg.p2.name, rmsg.p3.name, rmsg.p4.name, rmsg.p5.name, rmsg.p6.name, rmsg.p7.name]
        var surfaces: [IOSurfaceRef] = []
        surfaces.reserveCapacity(Self.ringSlots)
        for mp in portList {
            if let s = IOSurfaceLookupFromMachPort(mp) {
                surfaces.append(s)
            }
            mach_port_deallocate(mach_task_self_, mp)
        }
        guard surfaces.count == Self.ringSlots else {
            return (false, 0, 0, 0, "IOSurfaceLookupFromMachPort incomplete (\(surfaces.count)/\(Self.ringSlots))")
        }

        guard Self.pollReadable(readFD, timeoutMs: 1500) else {
            return (false, 0, 0, 0, "helper ready packet timed out")
        }
        var readyBuf = [UInt32](repeating: 0, count: 6)
        let gotReady = readyBuf.withUnsafeMutableBytes { raw in
            Self.readFull(readFD, raw.baseAddress!, raw.count)
        }
        guard gotReady, UInt32(littleEndian: readyBuf[0]) == Self.readyMagic else {
            return (false, 0, 0, 0, "helper ready packet invalid")
        }
        let width = Int(UInt32(littleEndian: readyBuf[1]))
        let height = Int(UInt32(littleEndian: readyBuf[2]))
        let usbSpeed = Int(UInt32(littleEndian: readyBuf[5]))

        let ownedOut = pipes?.1
        let ownedErr = pipes?.2

        stateLock.lock()
        stopping = false
        proc = process
        pipeIn = pipes?.0
        inWriteFD = writeFD
        lastFrameMonoNs = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()

        // No-frame watchdog: if the helper stays alive without delivering any frame for >3.0 s, trigger recovery.
        if process != nil {
            let wd = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            wd.schedule(deadline: .now() + 1.0, repeating: 1.0)
            wd.setEventHandler { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let isStopping = self.stopping
                let lastNs = self.lastFrameMonoNs
                self.stateLock.unlock()
                guard !isStopping else { return }
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if nowNs > lastNs && (nowNs - lastNs) > 3_000_000_000 {
                    Log.shared.line("raw-usb watchdog: no frames for >3.0 s; triggering recovery")
                    self.stop()
                    self.onUnexpectedExit?()
                }
            }
            stateLock.lock()
            watchdog = wd
            stateLock.unlock()
            wd.resume()
        }

        // Close stderr read end once handshake succeeds so helper stderr writes get EPIPE (SIGPIPE ignored)
        // instead of ever filling a 64 KB pipe buffer during multi-hour sessions.
        try? ownedErr?.fileHandleForReading.close()

        let reader = Thread { [weak self] in
            defer {
                try? ownedOut?.fileHandleForReading.close()
            }
            var hdrBuf = [UInt32](repeating: 0, count: 2)  // 8 bytes: magic(u32), slot_or_len(u32)
            var bodyBuf = [UInt64](repeating: 0, count: 3) // 24 bytes for frameMagic: seq, pts_mach, arrival_mach
            while true {
                var keepGoing = false
                autoreleasepool {
                    let okHdr = hdrBuf.withUnsafeMutableBytes { raw in
                        Self.readFull(readFD, raw.baseAddress!, raw.count)
                    }
                    guard okHdr, let self else { return }
                    let magic = UInt32(littleEndian: hdrBuf[0])
                    let arg = UInt32(littleEndian: hdrBuf[1])

                    if magic == Self.frameMagic {
                        let slot = Int(arg)
                        guard slot >= 0, slot < surfaces.count else { return }
                        let okBody = bodyBuf.withUnsafeMutableBytes { raw in
                            Self.readFull(readFD, raw.baseAddress!, raw.count)
                        }
                        guard okBody else { return }
                        let ptsMach = UInt64(littleEndian: bodyBuf[1])

                        self.stateLock.lock()
                        if self.stopping {
                            self.stateLock.unlock()
                            return
                        }
                        self.lastFrameMonoNs = DispatchTime.now().uptimeNanoseconds
                        self.stateLock.unlock()
                        keepGoing = true

                        let surf = surfaces[slot]
                        var umPB: Unmanaged<CVPixelBuffer>?
                        let cvr = CVPixelBufferCreateWithIOSurface(nil, surf, nil, &umPB)
                        var wrapped: CVPixelBuffer?
                        if cvr == kCVReturnSuccess, let umPB {
                            let pb = umPB.takeRetainedValue()
                            // Match UVC Color Matching descriptor (bColorPrimaries=1, bTransferCharacteristics=1,
                            // bMatrixCoefficients=1 = Rec.709, 4:2:0 Left siting) so VideoToolbox uses BT.709 YCbCr->RGB
                            // instead of defaulting to BT.601, and wide-gamut displays color-manage accurately.
                            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
                            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
                            // Increment IOSurface kernel use count BEFORE acknowledging slot back to helper.
                            // Use .shouldNotPropagate so copyColor never propagates the raw slot lease onto mid-frames!
                            CVBufferSetAttachment(pb, Self.leaseKey, SurfaceLease(surf), .shouldNotPropagate)
                            wrapped = pb
                        }

                        // Send 1-byte ack under stateLock so stop() cannot close writeFD concurrently.
                        self.stateLock.lock()
                        let activeWFD = self.stopping ? -1 : self.inWriteFD
                        if activeWFD >= 0 {
                            var ack = UInt8(slot)
                            _ = withUnsafeBytes(of: &ack) { Self.writeFull(activeWFD, $0.baseAddress!, 1) }
                        }
                        let deliverNow = !self.stopping
                        self.stateLock.unlock()

                        if deliverNow, let pb = wrapped {
                            wrapped = nil
                            let arrival = hostNow()
                            let pts = CMClockMakeHostTimeFromSystemUnits(ptsMach)
                            self.onFrame?(pb, pts, arrival)
                        }
                    } else if magic == Self.audioMagic {
                        let byteLen = Int(arg)
                        guard byteLen > 0, byteLen <= 16_384, (byteLen & 3) == 0 else { return }
                        var pcm = Data(count: byteLen)
                        let okPCM = pcm.withUnsafeMutableBytes { raw in
                            Self.readFull(readFD, raw.baseAddress!, byteLen)
                        }
                        guard okPCM else { return }
                        self.stateLock.lock()
                        let deliverNow = !self.stopping
                        self.stateLock.unlock()
                        guard deliverNow else { return }
                        keepGoing = true
                        self.onAudio?(pcm)
                    } else {
                        return
                    }
                }
                if !keepGoing { break }
            }
            guard let self else { return }
            self.stateLock.lock()
            let wasStopping = self.stopping
            let wd = self.watchdog
            self.watchdog = nil
            self.stateLock.unlock()
            wd?.cancel()
            if !wasStopping {
                self.onUnexpectedExit?()
            }
        }
        reader.name = "capture.rawusb.reader"
        reader.qualityOfService = .userInteractive
        reader.start()

        return (true, width, height, usbSpeed, "ok")
    }

    func stop() {
        stateLock.lock()
        if stopping { stateLock.unlock(); return }
        stopping = true
        let wfd = inWriteFD
        let p = proc
        let pin = pipeIn
        let wd = watchdog
        inWriteFD = -1
        proc = nil
        pipeIn = nil
        watchdog = nil
        if wfd >= 0 {
            var quitByte: UInt8 = 0xFF
            _ = withUnsafeBytes(of: &quitByte) { Self.writeFull(wfd, $0.baseAddress!, 1) }
        }
        try? pin?.fileHandleForWriting.close()
        stateLock.unlock()

        wd?.cancel()
        if let p {
            let deadline = Date().addingTimeInterval(1.2)
            while p.isRunning && Date() < deadline { usleep(20_000) }
        }
    }

    /// Deterministic offline self-test (--selftest): validates helper ownership checks, Mach IOSurface
    /// ring handoff, SurfaceLease kernel use-count lifecycle, pixel integrity, and timestamp conversion.
    static func runSelfTest() -> Bool {
        // 1. Ownership & symlink gate checks
        if verifyHelperBinary("relative/path").ok {
            fputs("SELFTEST FAIL: accepted relative path\n", stderr); return false
        }
        if !verifyHelperBinary("/usr/bin/true").ok {
            fputs("SELFTEST FAIL: rejected root-owned /usr/bin/true\n", stderr); return false
        }
        let tmpDir = NSTemporaryDirectory() + "ci_selftest_\(getpid())"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }
        let userFile = tmpDir + "/fake_helper"
        fm.createFile(atPath: userFile, contents: Data([0xCF]), attributes: [.posixPermissions: 0o755])
        if verifyHelperBinary(userFile).ok {
            fputs("SELFTEST FAIL: accepted non-root user-owned file\n", stderr); return false
        }
        let symPath = tmpDir + "/sym_true"
        try? fm.createSymbolicLink(atPath: symPath, withDestinationPath: "/usr/bin/true")
        if verifyHelperBinary(symPath).ok {
            fputs("SELFTEST FAIL: accepted symlink\n", stderr); return false
        }

        // 2. Full in-process mock helper <-> RawUVCCapture Mach port + pipe handshake & frame lease check
        let c2h = Pipe(), h2c = Pipe()
        let w = 128, h = 72
        var helperSurfs: [IOSurfaceRef] = []
        for _ in 0..<ringSlots {
            let p0: [CFString: Any] = [
                kIOSurfacePlaneWidth: w, kIOSurfacePlaneHeight: h,
                kIOSurfacePlaneBytesPerElement: 1, kIOSurfacePlaneBytesPerRow: w,
                kIOSurfacePlaneSize: w * h, kIOSurfacePlaneOffset: 0
            ]
            let p1: [CFString: Any] = [
                kIOSurfacePlaneWidth: w / 2, kIOSurfacePlaneHeight: h / 2,
                kIOSurfacePlaneBytesPerElement: 2, kIOSurfacePlaneBytesPerRow: w,
                kIOSurfacePlaneSize: w * (h / 2), kIOSurfacePlaneOffset: w * h
            ]
            let props: [CFString: Any] = [
                kIOSurfaceWidth: w, kIOSurfaceHeight: h,
                kIOSurfacePixelFormat: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kIOSurfaceAllocSize: w * h * 3 / 2,
                kIOSurfacePlaneInfo: [p0, p1]
            ]
            guard let s = IOSurfaceCreate(props as CFDictionary) else {
                fputs("SELFTEST FAIL: IOSurfaceCreate failed\n", stderr); return false
            }
            helperSurfs.append(s)
        }

        // Paint deterministic marker into slot 3
        IOSurfaceLock(helperSurfs[3], [], nil)
        let baseY = IOSurfaceGetBaseAddressOfPlane(helperSurfs[3], 0)
        memset(baseY, 0x5A, w * h)
        IOSurfaceUnlock(helperSurfs[3], [], nil)

        var ackReceived: UInt8 = 0xEE
        let ackSem = DispatchSemaphore(value: 0)
        let hReadFD = c2h.fileHandleForReading.fileDescriptor
        let hWriteFD = h2c.fileHandleForWriting.fileDescriptor

        let mockHelper = Thread {
            var hello = [UInt8](repeating: 0, count: 24)
            guard readFull(hReadFD, &hello, 24) else { return }
            let pid = hello.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: 8, as: UInt32.self)) }
            let nonce = hello.withUnsafeBytes { UInt64(littleEndian: $0.load(fromByteOffset: 16, as: UInt64.self)) }

            var bp: mach_port_t = 0
            _ = task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bp)
            let svc = String(format: "local.captureinterp.uvc.%u.%016llx", pid, nonce)
            var dst: mach_port_t = 0
            guard svc.withCString({ c_bootstrap_look_up(bp, $0, &dst) }) == KERN_SUCCESS else { return }

            func desc(_ s: IOSurfaceRef) -> mach_msg_port_descriptor_t {
                var d = mach_msg_port_descriptor_t()
                d.name = IOSurfaceCreateMachPort(s)
                d.disposition = mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_SEND)
                d.type = mach_msg_descriptor_type_t(MACH_MSG_PORT_DESCRIPTOR)
                return d
            }
            var smsg = SendPortsMsg(
                hdr: mach_msg_header_t(), body: mach_msg_body_t(msgh_descriptor_count: UInt32(ringSlots)),
                p0: desc(helperSurfs[0]), p1: desc(helperSurfs[1]), p2: desc(helperSurfs[2]), p3: desc(helperSurfs[3]),
                p4: desc(helperSurfs[4]), p5: desc(helperSurfs[5]), p6: desc(helperSurfs[6]), p7: desc(helperSurfs[7])
            )
            let bits = UInt32(MACH_MSGH_BITS_COMPLEX) | UInt32(MACH_MSG_TYPE_MOVE_SEND)
            smsg.hdr.msgh_bits = bits
            smsg.hdr.msgh_size = mach_msg_size_t(MemoryLayout<SendPortsMsg>.size)
            smsg.hdr.msgh_remote_port = dst
            smsg.hdr.msgh_id = portMsgID
            _ = withUnsafeMutablePointer(to: &smsg) { ptr in
                ptr.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) { hdrPtr in
                    mach_msg(hdrPtr, MACH_SEND_MSG, mach_msg_size_t(MemoryLayout<SendPortsMsg>.size), 0, mach_port_t(MACH_PORT_NULL), 1000, mach_port_t(MACH_PORT_NULL))
                }
            }

            let readySpeed = UInt32(5 | readyFlagHelperAudio | readyFlagCapturedDevice)
            var ready: [UInt32] = [readyMagic.littleEndian, UInt32(w).littleEndian, UInt32(h).littleEndian,
                                   UInt32(0x34323076).littleEndian, UInt32(ringSlots).littleEndian, readySpeed.littleEndian]
            _ = ready.withUnsafeBytes { writeFull(hWriteFD, $0.baseAddress!, $0.count) }

            // Emit 16-byte UAC stereo S16LE packet before the video frame
            var ahdr: [UInt32] = [audioMagic.littleEndian, UInt32(16).littleEndian]
            var apcm: [UInt8] = Array(0..<16)
            _ = ahdr.withUnsafeBytes { writeFull(hWriteFD, $0.baseAddress!, $0.count) }
            _ = apcm.withUnsafeBytes { writeFull(hWriteFD, $0.baseAddress!, $0.count) }

            // Emit 1 frame in slot 3 with 14.7 ms simulated delivery delta
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let arrMach = mach_absolute_time()
            let deltaMach = UInt64(14_700_000) * UInt64(tb.denom) / UInt64(tb.numer)
            let ptsMach = arrMach - deltaMach
            let word0 = UInt64(frameMagic) | (UInt64(3) << 32)
            var fpkt: [UInt64] = [word0.littleEndian, UInt64(1).littleEndian, ptsMach.littleEndian, arrMach.littleEndian]
            _ = fpkt.withUnsafeBytes { writeFull(hWriteFD, $0.baseAddress!, $0.count) }

            var ack: UInt8 = 0
            if readFull(hReadFD, &ack, 1) {
                ackReceived = ack
                ackSem.signal()
            }
            var quit: UInt8 = 0
            _ = readFull(hReadFD, &quit, 1)
            try? h2c.fileHandleForWriting.close()
        }
        mockHelper.start()

        let cap = RawUVCCapture()
        var heldPB: CVPixelBuffer?
        var measuredDelivMs = -1.0
        var receivedAudio = Data()
        let frameSem = DispatchSemaphore(value: 0)
        let audioSem = DispatchSemaphore(value: 0)
        cap.onAudio = { pcm in
            receivedAudio = pcm
            audioSem.signal()
        }
        cap.onFrame = { pb, pts, arrival in
            heldPB = pb
            measuredDelivMs = ms(CMTimeSubtract(arrival, pts))
            frameSem.signal()
        }
        let hs = cap.handshakeAndStartLoop(
            writeFD: c2h.fileHandleForWriting.fileDescriptor,
            readFD: h2c.fileHandleForReading.fileDescriptor,
            errHandle: nil, process: nil, pipes: (c2h, h2c, Pipe()),
            wantAudio: true
        )
        guard hs.ok, hs.width == w, hs.height == h,
              (hs.usbSpeed & readyFlagHelperAudio) != 0 else {
            fputs("SELFTEST FAIL: handshake failed: \(hs.reason)\n", stderr); return false
        }
        guard audioSem.wait(timeout: .now() + 2.0) == .success,
              receivedAudio == Data(0..<16),
              frameSem.wait(timeout: .now() + 2.0) == .success,
              ackSem.wait(timeout: .now() + 2.0) == .success else {
            fputs("SELFTEST FAIL: audio, frame, or ack timeout\n", stderr); return false
        }
        var yByte: UInt8 = 0
        var inUseWhileHeld = false
        var derivedPB: CVPixelBuffer?
        autoreleasepool {
            if let pb = heldPB {
                inUseWhileHeld = IOSurfaceIsInUse(helperSurfs[3])
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                yByte = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self).pointee ?? 0
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                // Verify copyColor (.shouldPropagate) does NOT copy SurfaceLease (.shouldNotPropagate) onto derived frames!
                var tmpDerived: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &tmpDerived)
                if let dst = tmpDerived {
                    copyColor(from: pb, to: dst)
                    derivedPB = dst
                }
            }
            heldPB = nil
        }
        // Verify ack was sent AFTER incrementing IOSurface kernel use count!
        if ackReceived != 3 || !inUseWhileHeld {
            fputs("SELFTEST FAIL: lease useCount not active while CVPixelBuffer held\n", stderr); return false
        }
        if let dst = derivedPB {
            let att = CVBufferCopyAttachments(dst, .shouldPropagate) as NSDictionary?
            if (att?[kCVImageBufferYCbCrMatrixKey] as? String) != (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {
                fputs("SELFTEST FAIL: Rec.709 color attachments did not propagate\n", stderr); return false
            }
        }
        if yByte != 0x5A {
            fputs("SELFTEST FAIL: pixel mismatch (got 0x\(String(yByte, radix: 16)))\n", stderr); return false
        }
        if measuredDelivMs < 14.5 || measuredDelivMs > 30.0 {
            fputs("SELFTEST FAIL: unexpected deliveryMs=\(measuredDelivMs)\n", stderr); return false
        }
        // Even while derivedPB is still alive, helperSurfs[3] MUST become free!
        for _ in 0..<40 {
            if !IOSurfaceIsInUse(helperSurfs[3]) { break }
            usleep(5_000)
        }
        if IOSurfaceIsInUse(helperSurfs[3]) {
            fputs("SELFTEST FAIL: IOSurface still marked in-use after CVPixelBuffer release (propagated leak)\n", stderr); return false
        }
        _ = derivedPB
        cap.stop()

        // 3. Verify fast handshake abort (< 400 ms) when child process exits immediately (e.g. sudo -n denied)
        let fastIn = Pipe(), fastOut = Pipe(), fastErr = Pipe()
        let fastProc = Process()
        fastProc.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        fastProc.standardInput = fastIn; fastProc.standardOutput = fastOut; fastProc.standardError = fastErr
        try? fastProc.run()
        fastProc.waitUntilExit()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let fastRes = RawUVCCapture().handshakeAndStartLoop(
            writeFD: fastIn.fileHandleForWriting.fileDescriptor,
            readFD: fastOut.fileHandleForReading.fileDescriptor,
            errHandle: fastErr.fileHandleForReading,
            process: fastProc,
            pipes: (fastIn, fastOut, fastErr)
        )
        let fastMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        try? fastIn.fileHandleForWriting.close()
        try? fastOut.fileHandleForReading.close()
        try? fastErr.fileHandleForReading.close()
        if fastRes.ok || fastMs > 400.0 {
            fputs("SELFTEST FAIL: dead-process handshake took \(fastMs) ms or succeeded\n", stderr); return false
        }

        // 4. Verify fused NV12->BGRA BT.709 conversion accuracy + medium ("4.5") RIFE tier + fused GPU subtitle protection
        let rw = 384, rh = 216
        guard let rifeMed = RifeEngine(width: rw, height: rh, tier: .medium) else {
            fputs("SELFTEST FAIL: RifeEngine(tier: .medium) init failed\n", stderr); return false
        }
        func makeTestNV12(shiftX: Int) -> CVPixelBuffer? {
            var pbOpt: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                        kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, rw, rh, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pbOpt)
            guard let pb = pbOpt else { return nil }
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
            CVPixelBufferLockBaseAddress(pb, [])
            let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for y in 0..<rh {
                for x in 0..<rw {
                    // Moving gradient background + static high-contrast subtitle block (width 8px >= 5px, dark outline)
                    let inSubBox = (y >= 178 && y < 194 && x >= 78 && x < 122)
                    let isSubWhite = (y >= 180 && y < 192 && x >= 82 && x < 98)
                    let texRipple = (((x + shiftX) % 4) < 2) ? 14 : 0
                    yBase[y * yBpr + x] = isSubWhite ? 235 : (inSubBox ? 16 : UInt8(40 + ((x + shiftX + y) % 130) + texRipple))
                }
            }
            for y in 0..<(rh / 2) {
                for x in 0..<(rw / 2) {
                    uvBase[y * uvBpr + x * 2 + 0] = 128
                    uvBase[y * uvBpr + x * 2 + 1] = 128
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            return pb
        }
        guard let f0 = makeTestNV12(shiftX: 0), let f1 = makeTestNV12(shiftX: 12), let f2 = makeTestNV12(shiftX: 24),
              let refBGRA = rifeMed.convert(f0),
              let s0 = rifeMed.stepFused(source: f0, consecutive: true, timesteps: nil, gpuProtect: true, casStrength: 0.0),
              let s1 = rifeMed.stepFused(source: f1, consecutive: true, timesteps: nil, gpuProtect: true, casStrength: 0.0),
              let s2 = rifeMed.stepFused(source: f2, consecutive: true, timesteps: [Float(1.0 / 3.0), Float(2.0 / 3.0)], gpuProtect: true, casStrength: 0.8),
              s0.mids.isEmpty, s1.mids.count == 1, s2.mids.count == 2 else {
            fputs("SELFTEST FAIL: stepFused medium tier 1-step or 2-step execution failed\n", stderr); return false
        }
        let colorDelta = compareBGRA(refBGRA, s0.currBGRA).diff
        if colorDelta > 1.5 || rifeMed.lastConvertMs != 0.0 {
            fputs("SELFTEST FAIL: fused NV12->BGRA BT.709 delta=\(colorDelta) (expected <=1.5)\n", stderr); return false
        }
        // Verify CAS sharpening measurably increases horizontal texture gradient without overshoot
        let unsharpGrad = compareBGRA(s0.currBGRA, s1.currBGRA).gradA
        let sharpGrad = compareBGRA(s0.currBGRA, s2.currBGRA).gradB
        if sharpGrad <= unsharpGrad {
            fputs("SELFTEST FAIL: CAS did not boost local detail (unsharp=\(unsharpGrad) sharp=\(sharpGrad))\n", stderr); return false
        }
        // Verify fused protectStill kept the center of the high-contrast static subtitle block (x=90, y=186) exact!
        CVPixelBufferLockBaseAddress(s1.currBGRA, .readOnly)
        CVPixelBufferLockBaseAddress(s1.mids[0], .readOnly)
        let curRow = CVPixelBufferGetBaseAddress(s1.currBGRA)!.assumingMemoryBound(to: UInt8.self) + 186 * CVPixelBufferGetBytesPerRow(s1.currBGRA)
        let midRow = CVPixelBufferGetBaseAddress(s1.mids[0])!.assumingMemoryBound(to: UInt8.self) + 186 * CVPixelBufferGetBytesPerRow(s1.mids[0])
        let subDiff = abs(Int(curRow[90 * 4 + 1]) - Int(midRow[90 * 4 + 1]))
        CVPixelBufferUnlockBaseAddress(s1.mids[0], .readOnly)
        CVPixelBufferUnlockBaseAddress(s1.currBGRA, .readOnly)
        if subDiff > 1 {
            fputs("SELFTEST FAIL: fused protectStill did not preserve static subtitle (diff=\(subDiff))\n", stderr); return false
        }

        if ProcessInfo.processInfo.environment["CI_BENCH_4K"] == "1" {
            let bw = 3840, bh = 2160
            var b0Opt: CVPixelBuffer?, b1Opt: CVPixelBuffer?
            let bAttrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                         kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, bw, bh, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bAttrs as CFDictionary, &b0Opt)
            CVPixelBufferCreate(nil, bw, bh, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bAttrs as CFDictionary, &b1Opt)
            if let b0 = b0Opt, let b1 = b1Opt {
                for tier in [RifeQualityTier.fast, RifeQualityTier.medium, RifeQualityTier.balanced] {
                    if let eng = RifeEngine(width: bw, height: bh, tier: tier) {
                        for i in 0..<24 {
                            _ = eng.stepFused(source: (i % 2 == 0) ? b0 : b1, consecutive: true, timesteps: nil, gpuProtect: true)
                        }
                        let samples = Array(eng.engineSamples.dropFirst(4))
                        print(String(format: "BENCH 4K fused tier=%@: p50=%.2f ms p95=%.2f ms min=%.2f ms",
                                     tier.rawValue, percentile(samples, 0.5), percentile(samples, 0.95), samples.min() ?? -1))
                    }
                }
            }
        }

        if ProcessInfo.processInfo.environment["CI_BENCH_ALL"] == "1" {
            let rep = HardwareBenchmark.run()
            if rep.entries.count != 9 {
                fputs("SELFTEST FAIL: expected 9 benchmark entries, got \(rep.entries.count)\n", stderr); return false
            }
            print(rep.formattedSummary())
        }

        print(String(format: "CaptureInterp selftest: PASS (ownership, Mach ring, non-propagating lease, fused-NV12 diff=%.2f, fast-fail=%.1f ms, delivery=%.2f ms)", colorDelta, fastMs, measuredDelivMs))
        return true
    }
}

// MARK: - Built-in PS5 Hardware Tier Benchmark (4K / 2K / 1080p)

enum HardwareBenchmark {
    static let smoothP95LimitMs = 25.5
    static let smoothP50LimitMs = 24.0
    static let borderlineP95LimitMs = 28.5

    struct Entry {
        let resShort: String
        let width: Int
        let height: Int
        let maxWidth: Int
        let mode: Mode
        let modeShort: String
        let p50Ms: Double
        let p95Ms: Double

        var isSmooth: Bool { p95Ms <= HardwareBenchmark.smoothP95LimitMs && p50Ms <= HardwareBenchmark.smoothP50LimitMs }
        var isBorderline: Bool { !isSmooth && p95Ms <= HardwareBenchmark.borderlineP95LimitMs }
        var verdict: String {
            if isSmooth { return "稳带" }
            if isBorderline { return "贴边" }
            return "超负荷"
        }
        var fullPresetLabel: String {
            let r = maxWidth == 0 ? "4K 原生 (3840×2160)" : (maxWidth == 2560 ? "限制 2K (2560×1440)" : "限制 1080p (1920×1080)")
            return "\(r) ＋ \(mode.title)"
        }
    }

    struct Report {
        let chipName: String
        let modelIdentifier: String
        let entries: [Entry]
        let recommended: Entry?
        let alternativeNote: String?

        var isFanlessAir: Bool {
            modelIdentifier.localizedCaseInsensitiveContains("Air")
        }

        func formattedSummary() -> String {
            var lines: [String] = []
            lines.append("本机芯片：\(chipName)\(modelIdentifier.isEmpty ? "" : "（\(modelIdentifier)）")")
            lines.append("PS5 30→60 帧不掉帧红线：单张显卡补帧需 ≤ 25.5 毫秒")
            lines.append("")
            for res in ["4K", "2K", "1080p"] {
                let sub = entries.filter { $0.resShort == res }
                let parts = sub.map { e in
                    String(format: "%@ %.1fms(%@)", e.modeShort, e.p95Ms, e.verdict)
                }
                let resTitle = res == "4K" ? "4K  (3840×2160)" : (res == "2K" ? "2K  (2560×1440)" : "1080p(1920×1080)")
                lines.append("\(resTitle)：" + parts.joined(separator: " ｜ "))
            }
            lines.append("")
            if let rec = recommended {
                lines.append("★ 本机接 PS5 最佳推荐：\(rec.fullPresetLabel)（实测 p95 \(String(format: "%.1f", rec.p95Ms)) 毫秒）")
                if let alt = alternativeNote {
                    lines.append("  备选方案：\(alt)")
                }
            } else {
                lines.append("★ 本机显卡负载较高：建议选「限制 1080p ＋ [4] 显卡·延迟低」或「[1] 直通」")
            }
            if isFanlessAir {
                lines.append("  提示：检测到无风扇机型，连续游玩半小时以上若机身发热降频，可在右键菜单往下降一档分辨率。")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(onProgress: ((String) -> Void)? = nil) -> Report {
        let chip = {
            let s = sysctlString("machdep.cpu.brand_string")
            if !s.isEmpty { return s }
            return MTLCreateSystemDefaultDevice()?.name ?? "Apple Silicon"
        }()
        let hwModel = sysctlString("hw.model")

        let resolutions: [(short: String, w: Int, h: Int, maxW: Int)] = [
            ("4K", 3840, 2160, 0),
            ("2K", 2560, 1440, 2560),
            ("1080p", 1920, 1080, 1920),
        ]
        let modes: [(mode: Mode, short: String)] = [
            (.rifeFast, "[4]延迟低"),
            (.rifeMedium, "[6]4.5档"),
            (.rifeBalanced, "[5]画质好"),
        ]

        var allEntries: [Entry] = []
        let pbAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        for res in resolutions {
            autoreleasepool {
                var b0Opt: CVPixelBuffer?, b1Opt: CVPixelBuffer?
                CVPixelBufferCreate(nil, res.w, res.h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, pbAttrs as CFDictionary, &b0Opt)
                CVPixelBufferCreate(nil, res.w, res.h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, pbAttrs as CFDictionary, &b1Opt)
                guard let b0 = b0Opt, let b1 = b1Opt else { return }

                // Fill synthetic textured motion pattern so GPU texture cache behaves realistically
                for (idx, pb) in [b0, b1].enumerated() {
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
                       let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) {
                        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                        let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                        let shift = idx * 8
                        for r in stride(from: 0, to: res.h, by: 4) {
                            let row = yBase + r * yBpr
                            let val = UInt8(truncatingIfNeeded: (r + shift) & 0xFF)
                            memset(row, Int32(val), res.w)
                        }
                        memset(uvBase, 128, (res.h / 2) * uvBpr)
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                }

                var fastAlreadyOverloaded = false
                for m in modes {
                    guard let tier = m.mode.rifeTier else { continue }
                    onProgress?("正在实测本机算力：\(res.short) \(m.short)…")
                    if fastAlreadyOverloaded && m.mode == .rifeBalanced {
                        // Fast/Medium at this resolution already exceeded >50 ms/frame; avoid multi-second GPU stall on entry chips.
                        let prev = allEntries.last?.p95Ms ?? 60.0
                        allEntries.append(Entry(resShort: res.short, width: res.w, height: res.h, maxWidth: res.maxW,
                                                mode: m.mode, modeShort: m.short, p50Ms: prev * 1.9, p95Ms: prev * 2.0))
                        continue
                    }
                    autoreleasepool {
                        guard let eng = RifeEngine(width: res.w, height: res.h, tier: tier) else {
                            allEntries.append(Entry(resShort: res.short, width: res.w, height: res.h, maxWidth: res.maxW,
                                                    mode: m.mode, modeShort: m.short, p50Ms: 999, p95Ms: 999))
                            return
                        }
                        let warmupCount = 3
                        var measured: [Double] = []
                        for i in 0..<(warmupCount + 8) {
                            let src = (i % 2 == 0) ? b0 : b1
                            let t0 = CACurrentMediaTime()
                            _ = eng.stepFused(source: src, consecutive: true, timesteps: nil, gpuProtect: true, casStrength: 0.55)
                            let dt = (CACurrentMediaTime() - t0) * 1000.0
                            if i >= warmupCount {
                                measured.append(dt)
                                // Early stop if clearly over budget (>42 ms) after 3 measured frames so entry Macs stay responsive
                                if measured.count >= 3 && percentile(measured, 0.5) > 42.0 {
                                    break
                                }
                            }
                        }
                        let p50 = percentile(measured, 0.5)
                        let p95 = percentile(measured, 0.95)
                        if p50 > 50.0 { fastAlreadyOverloaded = true }
                        allEntries.append(Entry(resShort: res.short, width: res.w, height: res.h, maxWidth: res.maxW,
                                                mode: m.mode, modeShort: m.short, p50Ms: p50, p95Ms: p95))
                    }
                }
            }
        }

        // Priority ranking for best PS5 experience on Mac
        let preferenceOrder: [(Int, Mode)] = [
            (0, .rifeBalanced),
            (0, .rifeMedium),
            (0, .rifeFast),
            (2560, .rifeBalanced),
            (2560, .rifeMedium),
            (2560, .rifeFast),
            (1920, .rifeBalanced),
            (1920, .rifeMedium),
            (1920, .rifeFast),
        ]
        func findEntry(_ mw: Int, _ mode: Mode) -> Entry? {
            allEntries.first { $0.maxWidth == mw && $0.mode == mode }
        }
        let bestSmooth = preferenceOrder.compactMap { findEntry($0.0, $0.1) }.first { $0.isSmooth }
        let bestFallback = bestSmooth ?? preferenceOrder.compactMap { findEntry($0.0, $0.1) }.first { $0.isBorderline }

        var altNote: String? = nil
        if let rec = bestFallback {
            if rec.maxWidth == 0 && rec.mode == .rifeFast {
                if let twoKMed = findEntry(2560, .rifeMedium), twoKMed.isSmooth {
                    altNote = "若更看重转视角动作细腻度，也可切「限制 2K ＋ [6] 均衡 4.5 档」（实测 \(String(format: "%.1f", twoKMed.p95Ms))ms）"
                }
            } else if rec.maxWidth == 0 && rec.mode == .rifeBalanced, rec.p95Ms > 21.0 {
                if let fourKMed = findEntry(0, .rifeMedium), fourKMed.isSmooth {
                    altNote = "若追求极致跟手低延迟，可切「4K 原生 ＋ [6] 均衡 4.5 档」（实测仅 \(String(format: "%.1f", fourKMed.p95Ms))ms）"
                }
            }
        }

        return Report(chipName: chip, modelIdentifier: hwModel, entries: allEntries, recommended: bestFallback, alternativeNote: altNote)
    }
}

if opts.selftest {
    exit(RawUVCCapture.runSelfTest() ? 0 : 1)
}

// MARK: - Pipeline

final class Pipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "capture.interp", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "capture.deliver", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingFrames = 0
    private let benchLock = NSLock()
    private var _benchmarkPaused = false
    func setBenchmarkPaused(_ paused: Bool) {
        benchLock.lock(); _benchmarkPaused = paused; benchLock.unlock()
        if paused {
            queue.sync {} // drain any in-flight GPU interpolation before benchmarking
        } else {
            queue.async { self.resetTiming() }
        }
    }
    private var interpBox: AnyObject?
    @available(macOS 26.0, *)
    private var interp: Interpolator? {
        get { interpBox as? Interpolator }
        set { interpBox = newValue }
    }
    private var prevScaled: CVPixelBuffer?
    private var tiledBox: AnyObject?
    @available(macOS 26.0, *)
    private var tiled: TiledInterpolator? {
        get { tiledBox as? TiledInterpolator }
        set { tiledBox = newValue }
    }
    private var prevTiles: [CVPixelBuffer]?
    private var tiledFailed = false
    private(set) var mode: Mode = {
        let initial: Mode
        if opts.initialModeOverride > 0, let m = Mode(rawValue: opts.initialModeOverride) {
            initial = m
        } else if !opts.interpolate {
            initial = .pass
        } else if opts.rife == "balanced" {
            initial = .rifeBalanced
        } else if opts.rife == "medium" {
            initial = .rifeMedium
        } else if !opts.rife.isEmpty {
            initial = .rifeFast
        } else if opts.tiles > 1 {
            initial = .tiled
        } else {
            initial = .single
        }
        if initial == .single || initial == .tiled {
            if #unavailable(macOS 26.0) { return .rifeMedium }
        }
        return initial
    }()
    private var sourceW = 0, sourceH = 0
    private var fastSourceNoted = false
    private var warmup = 0
    var onStatus: ((String) -> Void)?          // short on-screen status line, called on the main queue
    var onStats: ((String) -> Void)?           // once a second while frames flow: "60.0 fps · 68 ms · 丢帧 0", main queue
    var onStreamStateChange: ((Bool) -> Void)? // true when video stream is active, false when idle/disconnected
    private(set) var isStreaming = false
    private func notifyStreamActive(_ active: Bool) {
        isStreaming = active
        DispatchQueue.main.async { self.onStreamStateChange?(active) }
    }
    private var deviceName = ""
    private let configLock = NSLock()
    private var selectedDevicePref = opts.device
    private var maxWidthPref = opts.maxWidth
    private var audioModePref = opts.audio
    private var audioGainDbPref = opts.audioGainDb
    private var audioVolumePref = opts.audioVolume
    private var targetFpsPref = opts.fps
    private var activeSourceFps = opts.fps
    private var reconnectTimer: Timer?
    private var fileReader: AVAssetReader?   // must outlive the decode loop
    private var prevPTS = CMTime.invalid
    let collector = SampleCollector()
    private let audioRefLock = NSLock()
    private var _audio: AudioDelay?
    private var audio: AudioDelay? {
        get { audioRefLock.lock(); defer { audioRefLock.unlock() }; return _audio }
        set { audioRefLock.lock(); _audio = newValue; audioRefLock.unlock() }
    }
    private let audioQueue = DispatchQueue(label: "capture.audio", qos: .userInteractive)

    var currentDevicePref: String { configLock.lock(); defer { configLock.unlock() }; return selectedDevicePref }
    var currentActiveDeviceName: String { deviceName }
    var currentSourceSize: String { sourceSize }
    var currentMaxWidth: Int { configLock.lock(); defer { configLock.unlock() }; return maxWidthPref }
    var currentAudioGainDb: Double { configLock.lock(); defer { configLock.unlock() }; return audioGainDbPref }
    var isAudioEnabled: Bool {
        configLock.lock(); defer { configLock.unlock() }
        return !audioModePref.isEmpty && audioVolumePref > 0.001
    }
    var currentSharpness: Float { sharpLock.lock(); defer { sharpLock.unlock() }; return casStrength }
    private func currentActiveSourceFps() -> Double { configLock.lock(); defer { configLock.unlock() }; return activeSourceFps }
    private func setActiveSourceFps(_ fps: Double) { configLock.lock(); activeSourceFps = fps; configLock.unlock() }
    // display refresh grid, updated from the screen's display link
    private let vsLock = NSLock()
    private var vsTarget = 0.0, vsPeriod = 0.0
    private var prevMidSlot = 0.0
    private var holdMs: [Double] = []         // capture timestamp -> refresh on which the original appears

    func updateVsync(target: Double, period: Double) {
        vsLock.lock(); vsTarget = target; vsPeriod = period; vsLock.unlock()
    }

    // per-second stats
    private var frames = 0, mids = 0, lateMids = 0, lateOrig = 0, failed = 0
    private var deliveryMs: [Double] = [], readyMs: [Double] = [], interpMs: [Double] = []
    private var lastReport = hostNow()
    private var readyHistory: [Double] = []   // rolling (ready - capture PTS), ms
    private var liveOffsetMs = 0.0
    private var audioHoldHistory: [Double] = []   // last ~20 s of picture holds
    private var effOffsetMs = 0.0             // hold actually used for the current frame, from capture PTS
    private var offsetBootstrapped = false
    private var gapHistory: [Double] = []     // recent source frame intervals, ms
    private var nominalHalfMs = 1000.0 / 60.0 // half a source interval, smoothed
    private var lastEnqueued = CMTime.invalid // presentation times must only move forward
    private var procMs: [Double] = []         // frame arrival -> handed to the display layer
    private var droppedMids = 0
    private var seamDiffs: [Double] = [], textureDiffs: [Double] = []
    private var lumaSteps: [Double] = []      // |mid brightness - average of its two neighbours|
    private var prevWorkLuma = 0.0
    private var sourceSize = ""
    private(set) var usingRawUSB = opts.rawUSB
    private var rawCapture: RawUVCCapture?
    private var switchingSource = false

    private func setupDisplayAndInterpolators(width: Int, height: Int) {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: hostClock, timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: hostNow())
            CMTimebaseSetRate(tb, rate: 1)
            layer.controlTimebase = tb
        }
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        queue.sync {
            self.prepareInterpolators(width: width, height: height)
        }
    }

    private func attachCaptureAudio(to sess: AVCaptureSession, matchingHint: String) {
        configLock.lock()
        let audioMode = audioModePref
        let gain = audioGainDbPref
        let vol = audioVolumePref
        configLock.unlock()
        guard !audioMode.isEmpty else { return }
        let wantAudio = audioMode == "auto" ? String(matchingHint.prefix(12)) : audioMode
        func isVirtualOrPhoneMic(_ d: AVCaptureDevice) -> Bool {
            ["iPhone", "iPad", "Virtual", "Oray", "WeMeet", "BlackHole", "MacBook"].contains {
                d.localizedName.localizedCaseInsensitiveContains($0)
            }
        }
        if let mic = audioDevices().first(where: { $0.localizedName.localizedCaseInsensitiveContains(wantAudio) })
            ?? (audioMode == "auto" ? audioDevices().first(where: { $0.deviceType == .external && !isVirtualOrPhoneMic($0) }) : nil),
           let micIn = try? AVCaptureDeviceInput(device: mic), sess.canAddInput(micIn) {
            sess.addInput(micIn)
            let delayed = AudioDelay(gainDb: gain, volume: vol)
            delayed.session = sess
            let aout = AVCaptureAudioDataOutput()
            aout.setSampleBufferDelegate(delayed, queue: audioQueue)
            if sess.canAddOutput(aout) { sess.addOutput(aout); audio = delayed }
            Log.shared.line("audio: \(mic.localizedName) (delayed to match the picture, volume \(vol))")
        }
    }

    private func clearAVSession() {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        session.commitConfiguration()
        let oldAudio = audio
        audio = nil
        if let oldAudio {
            audioQueue.sync { oldAudio.stopEngine() }
        }
    }

    private func makeRawCaptureAndConnect(modeName: String) -> (raw: RawUVCCapture, ok: Bool, width: Int, height: Int, usbSpeed: Int, reason: String) {
        let raw = RawUVCCapture()
        raw.onFrame = { [weak self] pb, pts, arrival in
            guard let self else { return }
            self.captureQueue.async {
                self.deliverFrame(pb, pts: pts, arrival: arrival)
            }
        }
        // Install onAudio BEFORE start() launches the reader thread so the closure reference is never mutated concurrently.
        raw.onAudio = { [weak self] pcm in
            guard let self else { return }
            self.audioQueue.async {
                self.audio?.ingestPCM16Stereo(pcm)
            }
        }
        raw.onUnexpectedExit = { [weak self] in
            self?.handleRawUSBUnexpectedExit()
        }
        configLock.lock(); let wantAud = !audioModePref.isEmpty; configLock.unlock()
        let res = raw.start(modeName: modeName, wantAudio: wantAud)
        return (raw, res.ok, res.width, res.height, res.usbSpeed, res.reason)
    }

    private func finishActivateRawUSB(_ raw: RawUVCCapture, modeName: String, width: Int, height: Int, usbSpeed: Int) {
        rawCapture = raw
        usingRawUSB = true
        setActiveSourceFps(modeName.hasSuffix("60") ? 60.0 : 30.0)
        if deviceName.isEmpty { deviceName = "USB 3.2 Capture" }
        sourceSize = "\(width)x\(height)"

        let linkSpeed = usbSpeed & 0xFF
        let hasHelperAudio = (usbSpeed & RawUVCCapture.readyFlagHelperAudio) != 0
        let capturedWhole = (usbSpeed & RawUVCCapture.readyFlagCapturedDevice) != 0

        configLock.lock()
        let wantAud = !audioModePref.isEmpty
        let gain = audioGainDbPref
        let vol = audioVolumePref
        configLock.unlock()

        if wantAud {
            if hasHelperAudio {
                audio = AudioDelay(gainDb: gain, volume: vol)
                Log.shared.line("audio: \(deviceName) (raw-usb 48kHz PCM, delayed to match the picture, volume \(vol))")
            } else if !capturedWhole {
                session.beginConfiguration()
                attachCaptureAudio(to: session, matchingHint: deviceName)
                session.commitConfiguration()
                if !session.inputs.isEmpty { session.startRunning() }
            } else {
                Log.shared.line("warning: raw-usb captured whole device but UAC audio interface was unavailable")
            }
        }

        setupDisplayAndInterpolators(width: width, height: height)
        notifyStreamActive(true)
        Log.shared.line("device: \(deviceName) (raw-usb \(linkSpeed >= 5 ? "10G" : "5G")) format: \(sourceSize) 420v interp: \(opts.interpolate) offset: \(opts.offsetMs == 0 ? "adaptive" : "\(opts.offsetMs) ms")")
    }

    private func startRawUSB() -> (ok: Bool, reason: String) {
        clearAVSession()
        configLock.lock()
        let mw = maxWidthPref
        let fps = max(targetFpsPref, 60.0)
        configLock.unlock()
        let modeName = RawUVCCapture.desiredModeName(maxWidth: mw, fps: fps)
        let r = makeRawCaptureAndConnect(modeName: modeName)
        guard r.ok else { return (false, r.reason) }
        finishActivateRawUSB(r.raw, modeName: modeName, width: r.width, height: r.height, usbSpeed: r.usbSpeed)
        return (true, "ok")
    }

    private func handleRawUSBUnexpectedExit() {
        DispatchQueue.main.async {
            guard self.usingRawUSB, !self.switchingSource else { return }
            self.switchingSource = true
            self.rawCapture?.stop()
            self.rawCapture = nil
            self.usingRawUSB = false
            self.clearAVSession()
            self.resetCaptureAndTiming()
            Log.shared.line("raw-usb helper exited unexpectedly; attempting recovery and fallback to AVFoundation")

            DispatchQueue.global(qos: .userInitiated).async {
                RawUVCCapture.runRecoverIfInstalled()
                usleep(900_000)
                let pref = self.currentDevicePref
                var foundDev: AVCaptureDevice?
                for _ in 0..<10 {
                    if let d = preferredVideoDevice(pref) {
                        foundDev = d; break
                    }
                    usleep(200_000)
                }
                DispatchQueue.main.async {
                    self.switchingSource = false
                    if foundDev != nil && self.startAVFoundation() {
                        Log.shared.line("fell back to AVFoundation after raw-usb exit")
                        self.onStatus?("直读中断，已自动回退系统采集（\(self.sourceSize)）")
                    } else {
                        Log.shared.line("capture card absent after raw-usb exit; prompting replug")
                        self.notifyStreamActive(false)
                        self.onStatus?("直读中断且未检测到采集卡，请重新插拔采集卡")
                        self.scheduleReconnectLoop()
                    }
                }
            }
        }
    }

    func toggleCaptureSource() {
        setRawUSBEnabled(!usingRawUSB)
    }

    func setRawUSBEnabled(_ targetRaw: Bool) {
        guard opts.file.isEmpty, !switchingSource, targetRaw != usingRawUSB else { return }
        switchingSource = true
        reconnectTimer?.invalidate(); reconnectTimer = nil
        Prefs.saveRawUSB(targetRaw)

        if targetRaw {
            onStatus?("正在切换 USB 直读…")
            clearAVSession()
            resetCaptureAndTiming()
            configLock.lock()
            let mw = maxWidthPref
            let fps = max(targetFpsPref, 60.0)
            configLock.unlock()
            let modeName = RawUVCCapture.desiredModeName(maxWidth: mw, fps: fps)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = self.makeRawCaptureAndConnect(modeName: modeName)
                DispatchQueue.main.async {
                    self.switchingSource = false
                    if r.ok {
                        self.finishActivateRawUSB(r.raw, modeName: modeName, width: r.width, height: r.height, usbSpeed: r.usbSpeed)
                        self.onStatus?("输入源：USB 直读 256KB（\(self.sourceSize)）")
                    } else {
                        Log.shared.line("raw-usb switch failed (\(r.reason)); staying on AVFoundation")
                        self.usingRawUSB = false
                        Prefs.saveRawUSB(false)
                        if self.startAVFoundation() {
                            self.onStatus?("直读未就绪，保持系统采集（\(self.sourceSize)）")
                        } else {
                            self.notifyStreamActive(false)
                            self.onStatus?("直读未就绪且未找到外接采集卡，等待连接…")
                            self.scheduleReconnectLoop()
                        }
                    }
                }
            }
        } else {
            onStatus?("正在切回系统采集…")
            rawCapture?.stop()
            rawCapture = nil
            usingRawUSB = false
            clearAVSession()
            resetCaptureAndTiming()
            DispatchQueue.global(qos: .userInitiated).async {
                // Allow DriverKit uvcassistantextension & usbaudiod ~0.9 s to re-bind after helper releases device
                usleep(900_000)
                if preferredVideoDevice(self.currentDevicePref) == nil {
                    RawUVCCapture.runRecoverIfInstalled()
                    usleep(900_000)
                }
                DispatchQueue.main.async {
                    self.switchingSource = false
                    if self.startAVFoundation() {
                        self.onStatus?("输入源：系统采集 AVFoundation（\(self.sourceSize)）")
                    } else {
                        self.notifyStreamActive(false)
                        self.onStatus?("切回系统采集未找到外接采集卡，等待连接…")
                        self.scheduleReconnectLoop()
                    }
                }
            }
        }
    }

    private func restartActiveCapture(statusPrefix: String) {
        guard opts.file.isEmpty, !switchingSource else { return }
        switchingSource = true
        reconnectTimer?.invalidate(); reconnectTimer = nil
        let wantRaw = usingRawUSB
        rawCapture?.stop()
        rawCapture = nil
        usingRawUSB = false
        clearAVSession()
        resetCaptureAndTiming()

        DispatchQueue.global(qos: .userInitiated).async {
            if wantRaw {
                usleep(250_000)
                self.configLock.lock()
                let mw = self.maxWidthPref
                let fps = max(self.targetFpsPref, 60.0)
                self.configLock.unlock()
                let modeName = RawUVCCapture.desiredModeName(maxWidth: mw, fps: fps)
                let r = self.makeRawCaptureAndConnect(modeName: modeName)
                DispatchQueue.main.async {
                    self.switchingSource = false
                    if r.ok {
                        self.finishActivateRawUSB(r.raw, modeName: modeName, width: r.width, height: r.height, usbSpeed: r.usbSpeed)
                        self.onStatus?("\(statusPrefix)（USB 直读 \(self.sourceSize)）")
                    } else if self.startAVFoundation() {
                        self.onStatus?("\(statusPrefix)（系统采集 \(self.sourceSize)）")
                    } else {
                        self.notifyStreamActive(false)
                        self.onStatus?("切换后未检测到采集画面，等待设备就绪…")
                        self.scheduleReconnectLoop()
                    }
                }
            } else {
                usleep(250_000)
                DispatchQueue.main.async {
                    self.switchingSource = false
                    if self.startAVFoundation() {
                        self.onStatus?("\(statusPrefix)（\(self.deviceName) \(self.sourceSize)）")
                    } else {
                        self.notifyStreamActive(false)
                        self.onStatus?("未找到所选采集设备，等待连接…")
                        self.scheduleReconnectLoop()
                    }
                }
            }
        }
    }

    func selectVideoDevice(_ name: String) {
        guard opts.file.isEmpty, !switchingSource else {
            onStatus?("正在切换输入源，请稍候…")
            return
        }
        configLock.lock()
        selectedDevicePref = name
        configLock.unlock()
        deviceName = name
        Prefs.saveDevice(name)
        if !name.isEmpty && usingRawUSB {
            // User explicitly chose a specific AVFoundation device: switch off raw-USB so that exact device is opened.
            Prefs.saveRawUSB(false)
            setRawUSBEnabled(false)
            return
        }
        restartActiveCapture(statusPrefix: name.isEmpty ? "采集设备：自动选择" : "采集设备：\(name)")
    }

    func selectMaxWidth(_ width: Int) {
        guard opts.file.isEmpty, !switchingSource else {
            onStatus?("正在切换输入源，请稍候…")
            return
        }
        configLock.lock()
        let prev = maxWidthPref
        maxWidthPref = width
        configLock.unlock()
        Prefs.saveMaxWidth(width)
        guard prev != width else { return }
        let label = width == 0 ? "原生最高（4K）" : (width <= 1920 ? "1080p" : "2K")
        restartActiveCapture(statusPrefix: "分辨率上限：\(label)")
    }

    func setAudioEnabled(_ enabled: Bool) {
        configLock.lock()
        let hadAudioObj = (audio != nil)
        audioModePref = enabled ? "auto" : ""
        audioVolumePref = enabled ? 1.0 : 0.0
        let gain = audioGainDbPref
        configLock.unlock()
        Prefs.saveAudioEnabled(enabled)
        if enabled {
            if hadAudioObj {
                audio?.updateLevel(gainDb: gain, volume: 1.0)
                onStatus?("声音：已开启（+\(Int(gain)) dB）")
            } else {
                restartActiveCapture(statusPrefix: "声音：已开启")
            }
        } else {
            audio?.updateLevel(gainDb: gain, volume: 0.0)
            onStatus?("声音：已静音")
        }
    }

    func setAudioGainDb(_ db: Double) {
        configLock.lock()
        audioGainDbPref = db
        if audioModePref.isEmpty { audioModePref = "auto" }
        audioVolumePref = 1.0
        let hadAudioObj = (audio != nil)
        configLock.unlock()
        Prefs.saveAudioEnabled(true)
        Prefs.saveAudioGainDb(db)
        if hadAudioObj {
            audio?.updateLevel(gainDb: db, volume: 1.0)
            onStatus?("音量放大：+\(Int(db)) dB")
        } else {
            restartActiveCapture(statusPrefix: "音量放大：+\(Int(db)) dB")
        }
    }

    func startWaitingForDevice() {
        scheduleReconnectLoop()
    }

    func shutdown() {
        reconnectTimer?.invalidate(); reconnectTimer = nil
        rawCapture?.stop(); rawCapture = nil
        clearAVSession()
    }

    func start() -> Bool {
        if usingRawUSB {
            let res = startRawUSB()
            if res.ok { return true }
            Log.shared.line("raw-usb unavailable (\(res.reason)); falling back to AVFoundation")
            usingRawUSB = false
            if startAVFoundation() {
                DispatchQueue.main.async { self.onStatus?("直读未就绪，已自动回退系统采集（\(self.sourceSize)）") }
                return true
            }
            notifyStreamActive(false)
            return false
        }
        let ok = startAVFoundation()
        if !ok { notifyStreamActive(false) }
        return ok
    }

    private func startAVFoundation() -> Bool {
        configLock.lock()
        let devPref = selectedDevicePref
        let mw = maxWidthPref
        let wantFps = targetFpsPref
        configLock.unlock()
        let lookupName = !devPref.isEmpty ? devPref : ""
        guard let dev = preferredVideoDevice(lookupName) else {
            Log.shared.line("no matching video device; have: \(videoDevices().map(\.localizedName))")
            return false
        }
        deviceName = dev.localizedName
        // Highest 16:9 resolution that offers the requested fps (or ~30 fps fallback); among equals prefer
        // NV12, then other uncompressed formats, and MJPEG last.
        func supportsFps(_ f: AVCaptureDevice.Format, _ fps: Double) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps + 0.01 && $0.maxFrameRate >= fps - 0.1 }
        }
        func sub(_ f: AVCaptureDevice.Format) -> String { fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)).lowercased() }
        func isMJPEG(_ f: AVCaptureDevice.Format) -> Bool { sub(f).contains("jp") || sub(f) == "dmb1" }
        let sized = dev.formats.filter { mw == 0 || Int(CMVideoFormatDescriptionGetDimensions($0.formatDescription).width) <= mw }
        var lockTargetFps = wantFps
        var candidates = sized.filter { supportsFps($0, wantFps) }
        if candidates.isEmpty {
            lockTargetFps = 30.0
            candidates = sized.filter { supportsFps($0, 30.0) }
        }
        if candidates.isEmpty {
            candidates = sized.filter { f in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 } }
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let wide = abs(Double(d.width) / Double(d.height) - 16.0 / 9.0) < 0.02
            let kind = isMJPEG(f) ? 0 : (["420v", "420f"].contains(sub(f)) ? 3 : (["2vuy", "yuvs", "yuy2"].contains(sub(f)) ? 2 : 1))
            // The system hands MJPEG formats over already decoded (they look like 420v), so the only
            // way to tell them apart is that they reach higher frame rates than the raw ones.
            let top = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let fast = opts.preferCompressed ? min(Int(top), 999) : 0
            return (wide ? 1_000_000_000 : 0) + Int(d.width) * Int(d.height) * 4 + kind + fast
        }
        guard let format = candidates.max(by: { score($0) < score($1) }) else {
            Log.shared.line("device has no >=30 fps format"); return false
        }
        if isMJPEG(format) { Log.shared.line("warning: this size is only offered as MJPEG (compressed); expect extra delay. Try --max-width 1920 for an uncompressed format.") }
        func matchingRange(_ f: AVCaptureDevice.Format, _ fps: Double) -> AVFrameRateRange? {
            f.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= fps + 0.01 && $0.maxFrameRate >= fps - 0.1 })
                ?? f.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= 30.01 && $0.maxFrameRate >= 29.9 })
        }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            for old in session.inputs { session.removeInput(old) }      // clean slate when reconnecting
            for old in session.outputs { session.removeOutput(old) }
            guard session.canAddInput(input) else { session.commitConfiguration(); return false }
            session.addInput(input)
            try dev.lockForConfiguration()
            dev.activeFormat = format
            if let r = matchingRange(format, lockTargetFps) {
                // Capture cards report fixed-point ranges (e.g. 1000000/30000030); anything but the
                // range's own duration throws. Only a real span (e.g. 1–60) takes a plain 1/fps.
                let fixed = r.maxFrameRate - r.minFrameRate < 0.5
                let chosenFps = (r.minFrameRate <= lockTargetFps + 0.01 && r.maxFrameRate >= lockTargetFps - 0.1) ? lockTargetFps : 30.0
                let dur = fixed ? r.minFrameDuration : CMTime(value: 1, timescale: Int32(chosenFps))
                dev.activeVideoMinFrameDuration = dur
                dev.activeVideoMaxFrameDuration = dur
            } else {
                Log.shared.line("warning: could not lock target fps on this format; source may run at default rate")
            }
            dev.unlockForConfiguration()
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                 kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(out) else { session.commitConfiguration(); return false }
            session.addOutput(out)
            attachCaptureAudio(to: session, matchingHint: dev.localizedName)
            session.commitConfiguration()
        } catch {
            Log.shared.line("capture setup failed: \(error.localizedDescription)"); return false
        }
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        sourceSize = "\(d.width)x\(d.height)"
        Log.shared.line("device: \(dev.localizedName) format: \(sourceSize) \(fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))) interp: \(opts.interpolate) offset: \(opts.offsetMs == 0 ? "adaptive" : "\(opts.offsetMs) ms")")

        setupDisplayAndInterpolators(width: Int(d.width), height: Int(d.height))
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceLost(_:)), name: .AVCaptureDeviceWasDisconnected, object: dev)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceLost(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        session.startRunning()
        // The session can reset the device's frame rate when it commits/starts (some HDMI capture cards
        // fall back to their 25 fps range), so re-apply the frame rate lock once running.
        if let r = matchingRange(format, lockTargetFps),
           (try? dev.lockForConfiguration()) != nil {
            if dev.activeFormat != format { dev.activeFormat = format }
            let chosenFps = (r.minFrameRate <= lockTargetFps + 0.01 && r.maxFrameRate >= lockTargetFps - 0.1) ? lockTargetFps : 30.0
            let dur = r.maxFrameRate - r.minFrameRate < 0.5 ? r.minFrameDuration : CMTime(value: 1, timescale: Int32(chosenFps))
            dev.activeVideoMinFrameDuration = dur
            dev.activeVideoMaxFrameDuration = dur
            dev.unlockForConfiguration()
        }
        let actualSec = dev.activeVideoMinFrameDuration.seconds
        let actualFps = (actualSec > 0 && actualSec.isFinite) ? (1.0 / actualSec) : lockTargetFps
        setActiveSourceFps(actualFps)
        notifyStreamActive(true)
        Log.shared.line("frame rate locked after start: \(String(format: "%.2f", actualFps)) fps")
        return true
    }

    private func scheduleReconnectLoop() {
        guard reconnectTimer == nil else { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let wantRaw = Prefs.enabled ? (UserDefaults.standard.object(forKey: "pref.rawUSB") as? Bool ?? self.usingRawUSB) : self.usingRawUSB
            let pref = self.currentDevicePref
            guard preferredVideoDevice(pref) != nil else { return }
            t.invalidate(); self.reconnectTimer = nil
            self.resetCaptureAndTiming()
            if wantRaw && pref.isEmpty { self.usingRawUSB = true }
            if self.start() {
                Log.shared.line("reconnected")
                self.onStatus?("采集设备已连接（\(self.sourceSize)）")
            } else {
                self.scheduleReconnectLoop()
            }
        }
    }

    /// The card was unplugged, or the console changed its signal: wait and reconnect.
    @objc private func deviceLost(_ note: Notification) {
        DispatchQueue.main.async {
            guard !self.usingRawUSB, !self.switchingSource, self.reconnectTimer == nil else { return }
            Log.shared.line("capture device lost (\(note.name.rawValue)); waiting to reconnect")
            self.notifyStreamActive(false)
            self.onStatus?("采集设备断开，等待重新连接…")
            self.session.stopRunning()
            self.scheduleReconnectLoop()
        }
    }

    private func resetCaptureAndTiming() {
        captureQueue.sync {
            self.lastRaw = nil
            self.lastSeenPTS = .invalid
            self.lastKeptPTS = .invalid
            self.recentDiffs.removeAll()
            self.capIndex = 0
            self.pickParity = 0
            self.parityVotes = 0
            self.contentUsed = false
            self.tentative = false
            self.repeatRun = 0
        }
        queue.sync {
            self.resetTiming()
        }
    }

    private func resetTiming() {
        prevScaled = nil; prevTiles = nil; prevPTS = .invalid; rifePrevBGRA = nil
        readyHistory.removeAll(); gapHistory.removeAll(); offsetBootstrapped = false; audioHoldHistory.removeAll()
        liveOffsetMs = 0; prevMidSlot = 0; fastSourceNoted = false; warmup = 0
    }

    /// Switch mode while running (keys 1-6 or menu). Applied at the next frame, on the processing thread.
    func setMode(_ m: Mode) {
        if m == .single || m == .tiled {
            if #unavailable(macOS 26.0) {
                DispatchQueue.main.async { self.onStatus?("2/3 档系统补帧需 macOS 26+，请使用 4/5/6 显卡档") }
                return
            }
        }
        Prefs.saveMode(m.rawValue)
        modeLock.lock(); pendingMode = m; modeLock.unlock()
    }
    private let modeLock = NSLock()
    private var pendingMode: Mode?
    /// The mode the user asked for; `mode` catches up at the next frame.
    var requestedMode: Mode { modeLock.lock(); defer { modeLock.unlock() }; return pendingMode ?? mode }
    private let sharpLock = NSLock()
    private var casStrength = Float(opts.sharpness)

    func setSharpness(_ value: Float) {
        let clamped = min(1.0, max(0.0, value))
        let label: String
        if clamped < 0.05 { label = "关（0.0）" }
        else if clamped < 0.75 { label = String(format: "标准（%.2f）", clamped) }
        else { label = String(format: "强（%.2f）", clamped) }
        sharpLock.lock()
        casStrength = clamped
        let inRife = (mode.rifeTier != nil)
        sharpLock.unlock()
        Prefs.saveSharpness(clamped)
        Log.shared.line("sharpness: \(clamped) (\(label))")
        let note = inRife ? "锐化：\(label)　　按 K 切换" : "锐化：\(label)（切到 4/5/6 显卡档生效）"
        DispatchQueue.main.async { self.onStatus?(note) }
    }

    let upscaler = SpatialUpscaler(mode: opts.upscale)
    private let targetLock = NSLock()
    private var layerPx = (w: 0, h: 0)

    /// Main thread, after every change of the layer's size or scale; the frame queue reads it to size the upscale.
    func updateDisplayTarget() {
        let b = layer.bounds.size, s = layer.contentsScale
        targetLock.lock(); layerPx = (Int(b.width * s), Int(b.height * s)); targetLock.unlock()
    }

    private func upscaled(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        targetLock.lock(); let px = layerPx; targetLock.unlock()
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        guard px.w > 0, px.h > 0, w > 0, h > 0 else { return pb }
        let k = min(Double(px.w) / w, Double(px.h) / h)
        let even = { (v: Double) in Int((v / 2).rounded()) * 2 }
        return upscaler.upscale(pb, to: (even(w * k), even(h * k))) ?? pb
    }

    func toggleUpscale() {
        let m: UpscaleMode = upscaler.mode == .off ? .metalfx : .off
        upscaler.mode = m
        Log.shared.line("upscale: \(m.rawValue)")
        DispatchQueue.main.async { self.onStatus?(m == .off ? "放大：关　　按 X 切换" : "放大：MetalFX 开　　按 X 切换") }
    }

    func cycleSharpness() {
        sharpLock.lock(); let cur = casStrength; sharpLock.unlock()
        if cur < 0.2 { setSharpness(0.55) }
        else if cur < 0.75 { setSharpness(0.90) }
        else { setSharpness(0.0) }
    }

    private func applyPendingMode() {
        modeLock.lock(); let m = pendingMode; pendingMode = nil; modeLock.unlock()
        guard let m, m != mode else { return }
        mode = m
        rifeEngines[m]?.reset()
        resetTiming()
        ensureInterpolators()
        Log.shared.line("mode: \(m.rawValue) \(m.title)")
        let text = "模式：" + m.title + "　　按 1-6 切换"
        DispatchQueue.main.async { self.onStatus?(text) }
    }

    func applyRecommendedPreset(mode targetMode: Mode, maxWidth targetWidth: Int) {
        setMode(targetMode)
        configLock.lock()
        let prevW = maxWidthPref
        maxWidthPref = targetWidth
        configLock.unlock()
        Prefs.saveMaxWidth(targetWidth)
        let resLabel = targetWidth == 0 ? "4K 原生" : (targetWidth <= 1920 ? "1080p" : "2K")
        if prevW != targetWidth {
            restartActiveCapture(statusPrefix: "已应用推荐：\(resLabel) ＋ \(targetMode.title)")
        } else {
            onStatus?("已应用推荐：\(resLabel) ＋ \(targetMode.title)")
        }
    }

    private func deliverFrame(_ pb: CVPixelBuffer, pts: CMTime, arrival: CMTime) {
        benchLock.lock(); let paused = _benchmarkPaused; benchLock.unlock()
        if paused { return }
        guard acceptFrame(pb, pts: pts) else { return }
        pendingLock.lock()
        if pendingFrames >= 2 { pendingLock.unlock(); return }      // processing is behind: skip rather than queue up delay
        pendingFrames += 1
        pendingLock.unlock()
        queue.async {
            let t0 = hostNow()
            defer { let took = ms(CMTimeSubtract(hostNow(), t0)); if took > 100 { Log.shared.line(String(format: "slow frame: %.0f ms total, waited %.0f ms in queue", took, ms(CMTimeSubtract(t0, arrival)))) } }
            self.handle(pb, pts: pts, arrival: arrival)
            self.pendingLock.lock(); self.pendingFrames -= 1; self.pendingLock.unlock()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let arrival = hostNow()
        // Capture timestamps are on the session clock; express them on the host clock.
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let clock = session.synchronizationClock { pts = CMSyncConvertTime(pts, from: clock, to: hostClock) }
        deliverFrame(pb, pts: pts, arrival: arrival)
    }

    /// File simulation: decode a video and hand frames over on a steady ~30 fps clock,
    /// as a capture device would. Decode happens ahead of time so it is not counted.
    func startFile(_ path: String) -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else {
            Log.shared.line("cannot open \(path)"); return false
        }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { Log.shared.line("reader failed"); return false }
        fileReader = reader
        setActiveSourceFps(30.0)
        let fps = Double(track.nominalFrameRate)
        let step = max(1, Int((fps / 30.0).rounded()))   // 60 fps file -> every 2nd frame
        let size = track.naturalSize
        sourceSize = "\(Int(size.width))x\(Int(size.height))"
        Log.shared.line("file: \((path as NSString).lastPathComponent) \(sourceSize) \(fps) fps, feeding every \(step) frame(s) interp: \(opts.interpolate)")
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: hostClock, timebaseOut: &tb)
        if let tb { CMTimebaseSetTime(tb, time: hostNow()); CMTimebaseSetRate(tb, rate: 1); layer.controlTimebase = tb }
        layer.videoGravity = .resizeAspect
        sourceW = Int(size.width); sourceH = Int(size.height)
        prepareInterpolators(width: sourceW, height: sourceH)
        let interval = Double(step) / fps
        let feeder = DispatchQueue(label: "file.decode", qos: .userInitiated)
        let ready = DispatchSemaphore(value: 0)
        var pending: [CVPixelBuffer] = []
        let lock = NSLock()
        feeder.async {   // decode ahead, keep a small backlog
            var n = 0
            var more = true
            while more {
                autoreleasepool {
                    guard let sb = out.copyNextSampleBuffer() else { more = false; return }
                    n += 1
                    guard n % step == 0, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
                    while true { lock.lock(); let c = pending.count; lock.unlock(); if c < 3 { break }; usleep(2000) }
                    lock.lock(); pending.append(pb); lock.unlock()
                    ready.signal()
                }
            }
            usleep(400_000)   // let the last frames reach the screen
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        queue.async {
            var next = CMTimeGetSeconds(hostNow()) + 0.5
            while true {
                ready.wait()
                lock.lock(); let pb = pending.removeFirst(); lock.unlock()
                let wait = next - CMTimeGetSeconds(hostNow())
                if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
                else if wait < -0.1 { next = CMTimeGetSeconds(hostNow()) }   // after a stall, resume the cadence instead of bursting
                autoreleasepool {
                    // A real card stamps the capture time, so a slow previous frame does not stretch the gap
                    // between pictures. Stamping `now` let one slow frame look like a held picture, which made
                    // the next frame slower still.
                    let pts = CMTime(seconds: next, preferredTimescale: 1_000_000_000)
                    self.handle(pb, pts: pts, arrival: hostNow())
                }
                next += interval
            }
        }
        notifyStreamActive(true)   // behave like a live device: the control card hides over video, so file benchmarks match real play
        return true
    }

    /// Create the interpolation sessions before the first frame, so start-up does not stall the stream.
    private func prepareInterpolators(width: Int, height: Int) {
        if sourceW != 0 && (sourceW != width || sourceH != height) {
            rifeEngines.removeAll(); rifeFailed = false
            interpBox = nil; tiledBox = nil; tiledFailed = false; rifePrevBGRA = nil
        }
        sourceW = width; sourceH = height
        ensureInterpolators()
    }

    /// Make sure the sessions needed by the current mode exist.
    private var rifeEngines: [Mode: RifeEngine] = [:]
    private var perPictureMs: [Mode: Double] = [:]   // smoothed RIFE time per in-between picture, per tier
    private var rifeFailed = false
    private var rifeDebugCount = 0
    private var longGaps = 0, earlyShown = 0
    private lazy var stillProtector = StillProtector()
    private var lastProtectMs = 0.0
    private var dumpSeen = 0
    private var rifePrevBGRA: CVPixelBuffer?
    private func ensureInterpolators() {
        if let tier = mode.rifeTier, rifeEngines[mode] == nil, !rifeFailed, sourceW > 0 {
            if let e = RifeEngine(width: sourceW, height: sourceH, tier: tier) {
                rifeEngines[mode] = e
                Log.shared.line("rife mode: \(sourceW)x\(sourceH) whole frame on the GPU, tier \(tier.rawValue)")
            } else { rifeFailed = true; Log.shared.line("rife mode unavailable, showing originals only") }
        }
        if mode == .tiled && tiledBox == nil && !tiledFailed {
            if #available(macOS 26.0, *) {
                let grid = opts.grid ?? (opts.tiles == 9 ? Grid.k3 : Grid.k2)
                tiled = TiledInterpolator(grid)
                if tiled == nil { tiledFailed = true; Log.shared.line("tile mode unavailable, using single pass") }
                else { Log.shared.line("tile mode: \(grid.cols)x\(grid.rows) of \(grid.tileW)x\(grid.tileH) -> \(grid.workW)x\(grid.workH), originals \(opts.origNative ? "native" : "work size")") }
            } else {
                tiledFailed = true
                Log.shared.line("tile mode requires macOS 26+")
            }
        }
        if (mode == .single || (mode == .tiled && tiledFailed)) && interpBox == nil && sourceW > 0 {
            if #available(macOS 26.0, *) {
                interp = Interpolator(sourceWidth: sourceW, sourceHeight: sourceH)
                if let i = interp { Log.shared.line("interp size: \(i.width)x\(i.height)") } else { Log.shared.line("interpolation unavailable, passing frames through") }
            } else {
                Log.shared.line("system interpolation requires macOS 26+; passing frames through")
            }
        }
    }

    /// True when frames should simply be shown as they arrive.
    private var passing: Bool {
        if mode == .pass { return true }
        if rifeEngines[mode] != nil { return false }
        if mode == .tiled && tiledBox != nil && !tiledFailed { return false }
        return interpBox == nil
    }

    /// Hand a frame to the display layer. Presentation times never go backwards or collide.
    @discardableResult
    private func enqueue(_ pb: CVPixelBuffer, at time: CMTime) -> CMTime {
        var t = time
        if lastEnqueued.isValid {
            let floor = CMTimeAdd(lastEnqueued, CMTime(value: 4, timescale: 1000))
            if t < floor { t = floor }
        }
        if layer.status == .failed { layer.flush() }
        if noDisplayDebug { lastEnqueued = t; return t }     // diagnosis only (CI_NO_DISPLAY=1): how much does putting pictures on screen slow the GPU model down?
        if let sb = makeSample(upscaled(pb), pts: t) { layer.enqueue(sb) }
        lastEnqueued = t
        return t
    }

    // --- 60 fps capture carrying a 30 fps game: every picture arrives twice. ---
    private var lastRaw: CVPixelBuffer?
    private var recentDiffs: [Double] = []      // frame-to-frame differences of the last two seconds
    private var lastSeenPTS = CMTime.invalid, lastKeptPTS = CMTime.invalid, lastKeptWasRepeat = false
    private(set) var contentIs60 = false

    /// Sparse luma comparison: true when this frame is the same picture as the previous one.
    private func differenceFromPrevious(_ pb: CVPixelBuffer) -> Double {
        defer { lastRaw = pb }
        guard let prev = lastRaw, CVPixelBufferGetWidth(prev) == CVPixelBufferGetWidth(pb),
              CVPixelBufferGetHeight(prev) == CVPixelBufferGetHeight(pb) else { return 99 }
        CVPixelBufferLockBaseAddress(pb, .readOnly); CVPixelBufferLockBaseAddress(prev, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly); CVPixelBufferUnlockBaseAddress(prev, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let b = CVPixelBufferGetBaseAddressOfPlane(prev, 0) else { return 99 }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let ra = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(prev, 0)
        let pa = a.assumingMemoryBound(to: UInt8.self), pbb = b.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        var y = 8
        while y < h {
            var x = 8
            while x < w { sum += abs(Int(pa[y * ra + x]) - Int(pbb[y * rb + x])); n += 1; x += 16 }
            y += 16
        }
        let d = n > 0 ? Double(sum) / Double(n) : 99
        diffLog.append(d); if diffLog.count >= 120 {
            let v = diffLog.sorted(); diffLog.removeAll()
            Log.shared.line(String(format: "   frame-to-frame difference over 2 s: p10 %.3f p25 %.3f p50 %.3f p75 %.3f p90 %.3f", v[12], v[30], v[60], v[90], v[108]))
        }
        return d
    }
    private var diffLog: [Double] = []
    private let seenLock = NSLock()
    private var capIndex = 0, pickParity = 0, parityVotes = 0
    private var contentUsed = false, tentative = false, repeatRun = 0
    private var parityChange = [0.0, 0.0]         // recent picture change seen on even / odd capture frames
    private(set) var paritySwitches = 0
    private var seenCount = 0
    private var noiseFloor = 0.0, sceneRef = 0.0, maxSinceKept = 99.0
    private var pickGaps = [0, 0, 0, 0], samePictureAgain = 0

    /// Runs on the light capture queue for every delivered frame; decides whether the frame is processed.
    /// Keeping this off the processing queue matters: a 60 fps device must never wait for a generated frame.
    private func acceptFrame(_ pb: CVPixelBuffer, pts: CMTime) -> Bool {
        if currentActiveSourceFps() >= 50 {
            // Frames can go missing while a generated frame is being computed, so only neighbours
            // one 60 Hz step apart say anything about repeats.
            let seenGap = lastSeenPTS.isValid ? ms(CMTimeSubtract(pts, lastSeenPTS)) : -1
            lastSeenPTS = pts
            seenLock.lock(); seenCount += 1; seenLock.unlock()
            if seenGap > 60 || (seenGap < 0 && seenGap != -1) { Log.shared.line(String(format: "capture gap: %.0f ms between delivered frames", seenGap)) }
            let d = differenceFromPrevious(pb)
            let neighbour = seenGap > 5 && seenGap < 22          // previous frame really was the one before
            var isRepeat = false, known = false
            if neighbour {
                recentDiffs.append(d); if recentDiffs.count > 120 { recentDiffs.removeFirst() }
                // A repeat differs from its original by nothing, or by a little noise (4K capture).
                // Anything clearly below the typical change of the last two seconds counts as one.
                // Reference = upper quartile: with half the frames being repeats the median sits right
                // on the edge between the two groups and would make the verdict flip constantly.
                let sortedD = recentDiffs.sorted()
                let ref = sortedD[sortedD.count * 3 / 4]
                // At least a quarter of the frames are repeats (half at 60 fps capture, three quarters at 120), so the
                // lower quartile sits inside the repeats: 0 on cards whose repeats are bit-identical, the card's own
                // compression noise on cards that re-encode every frame (some MJPEG capture cards: about 0.11).
                if sortedD.count >= 60 { noiseFloor = sortedD[sortedD.count / 4]; sceneRef = ref }
                let limit = max(0.9, 0.6 * ref)        // repeats measured at up to ~40% of a real change (noisy 4K scenes)
                isRepeat = d < limit; known = true
                if recentDiffs.count >= 90 {
                    let share = Double(recentDiffs.filter { $0 < limit }.count) / Double(recentDiffs.count)
                    // Wide gap between the two verdicts so the mode cannot flip back and forth.
                    let now60 = share < 0.12 ? true : (share > 0.30 ? false : contentIs60)
                    if now60 != contentIs60 {
                        contentIs60 = now60
                        Log.shared.line(String(format: "game content is ~%d fps (repeated frames %.0f%%)", now60 ? 60 : 30, share * 100))
                        if mode != .pass && opts.autoPass { queue.async { self.resetTiming() }; let t = now60 ? "游戏已是 60 帧，自动直通" : "游戏是 30 帧，补到 60"; DispatchQueue.main.async { self.onStatus?(t) } }
                    }
                }
            } else { recentDiffs.removeAll() }
            if mode != .pass && !(opts.autoPass && contentIs60) {
                // Use the first copy of each picture (it is 16.7 ms fresher). While the picture stands
                // still nothing tells the copies apart, so simply keep every other frame.
                let keptGap = lastKeptPTS.isValid ? ms(CMTimeSubtract(pts, lastKeptPTS)) : 1000
                var keep: Bool
                if opts.legacyPick {
                    if keptGap < 0 || keptGap > 60 { keep = true }
                    else if known && !isRepeat { keep = keptGap >= 25 || lastKeptWasRepeat }
                    else if known { keep = keptGap >= 31 }                 // a repeat: only on the 30 fps cadence (still picture, or its original was missed)
                    else { keep = keptGap >= 25 }
                } else {
                    // Judging every frame on its own ("is this a repeat?") goes wrong in dark or slow scenes, and each
                    // wrong verdict shifts the 30 fps cadence by one capture frame: two pictures 16.7 ms apart, then
                    // none for 50 ms (seen in a real game as "in 30.4-31.2 fps" and as flicker on the glass).
                    // Instead: number the capture frames, take every other one, and move to the other half only
                    // when the evidence has pointed there for a while.
                    capIndex += seenGap > 5 ? max(1, Int((seenGap / 16.6667).rounded())) : 1
                    maxSinceKept = neighbour ? max(maxSinceKept, d) : 99
                    let par = capIndex & 1
                    if neighbour { parityChange[par] = parityChange[par] * 0.9 + d; parityChange[1 - par] *= 0.9 }
                    if opts.votePick {
                        let other = 1 - pickParity
                        if parityChange[other] > 1.6 * parityChange[pickParity] + 0.3 { parityVotes += 1 } else { parityVotes = 0 }
                        if parityVotes >= 10 { pickParity = other; parityVotes = 0; paritySwitches += 1 }
                        keep = par == pickParity || keptGap < 0 || keptGap > 60
                    } else {
                        // Third version. With 60 fps capture a repeated picture is bit-identical to the one before
                        // (difference exactly 0), so "repeat" needs no guessing: the earlier limits (0.9, or a share
                        // of the recent average) called slow real pictures repeats. Stay on one half; when the frame
                        // due now repeats a picture already used (the console held it for three capture frames),
                        // skip it and take the very next frame if that one is new: one 50 ms step, nothing lost,
                        // instead of a repeated picture, several stale ones and a 50 ms hole.
                        let repeatLimit = opts.exactRepeat ? 0.003 : max(0.003, 1.6 * noiseFloor)
                        let repeated = neighbour && d < repeatLimit
                        repeatRun = repeated ? repeatRun + 1 : 0
                        if !repeated { contentUsed = false }
                        if keptGap < 0 || keptGap > 60 { keep = true; tentative = false }
                        else if tentative {
                            tentative = false
                            if repeated { pickParity = 1 - pickParity; keep = false }     // nothing new after all: back to the old half
                            else { keep = true; paritySwitches += 1 }
                        }
                        else if par == pickParity {
                            // repeatRun > 2: the picture stands still (or the game stalled); just keep the cadence.
                            if repeated && contentUsed && repeatRun <= 2 { pickParity = 1 - par; tentative = true; keep = false } else { keep = true }
                        }
                        else { keep = false }
                    }
                    if keep && keptGap >= 0 && keptGap < 25 { keep = false }      // never two pictures one capture frame apart
                    if keep {
                        contentUsed = true
                        // Diagnostics: the rhythm of the pictures taken, and how often a picture already taken came again.
                        let lim = max(0.003, 1.6 * noiseFloor)
                        seenLock.lock()
                        if keptGap >= 0 && keptGap < 100 { pickGaps[keptGap < 29.5 ? 0 : (keptGap < 37.5 ? 1 : (keptGap < 46 ? 2 : 3))] += 1 }
                        if maxSinceKept < lim && sceneRef > 3 * lim + 0.2 { samePictureAgain += 1 }
                        seenLock.unlock()
                        maxSinceKept = 0
                    }
                }
                if !keep { return false }
                lastKeptPTS = pts
                lastKeptWasRepeat = known && isRepeat
            }
        }
        return true
    }

    private func handle(_ pb: CVPixelBuffer, pts: CMTime, arrival: CMTime) {
        applyPendingMode()
        frames += 1
        deliveryMs.append(ms(CMTimeSubtract(arrival, pts)))

        // A source that already runs at ~60 fps needs no generated frames on a 60 Hz screen.
        let srcGap = prevPTS.isValid ? ms(CMTimeSubtract(pts, prevPTS)) : -1
        vsLock.lock(); let screenPeriod = vsPeriod; vsLock.unlock()
        let fastSource = mode != .pass && screenPeriod > 0.015
            && (currentActiveSourceFps() >= 50 ? (opts.autoPass && contentIs60) : (gapHistory.count >= 20 && nominalHalfMs < 11))
        if fastSource && !fastSourceNoted {
            fastSourceNoted = true
            Log.shared.line("source is already ~60 fps on a 60 Hz screen: passing through")
            DispatchQueue.main.async { self.onStatus?("信号已是 60 帧，自动直通") }
        }
        if passing || fastSource {
            if srcGap > 5 && srcGap < 60 {
                gapHistory.append(srcGap)
                if gapHistory.count > 60 { gapHistory.removeFirst(gapHistory.count - 60) }
                nominalHalfMs = min(20, max(7, percentile(gapHistory, 0.5) / 2))
            }
            prevPTS = pts
            audio?.setDelay(0)                          // picture is not held, so neither is the sound
            // Pass-through: no waiting at all, show the frame as soon as it arrives.
            if layer.status == .failed { layer.flush() }
            if let sb = makeSample(upscaled(pb), pts: arrival) {
                if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
                    let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                layer.enqueue(sb)
            }
            procMs.append(ms(CMTimeSubtract(hostNow(), arrival)))
            collector.observe(pb, pts: pts, gapMs: srcGap, mode: mode)
            report()
            return
        }

        // Source cadence: only bridge frames that are really consecutive.
        let gapMs = prevPTS.isValid ? ms(CMTimeSubtract(pts, prevPTS)) : -1
        let consecutive = gapMs > 5 && gapMs < (rifeEngines[mode] != nil && opts.multiMid ? 76 : 60)   // GPU mode also bridges a picture held for four refreshes
        if consecutive {
            gapHistory.append(gapMs)
            if gapHistory.count > 60 { gapHistory.removeFirst(gapHistory.count - 60) }
            nominalHalfMs = min(20, max(7, percentile(gapHistory, 0.5) / 2))   // smoothed, so jitter cannot reorder frames
        }
        let half = CMTime(seconds: nominalHalfMs / 1000.0, preferredTimescale: 1_000_000_000)

        // How long to hold frames: follow the slowest recent frames; rise at once, come down slowly.
        // The screen compositor needs the GPU around every refresh; a GPU interpolation running just then makes it
        // miss refreshes. Optionally start the job at a fixed point of the refresh cycle.
        if opts.gpuPhaseMs >= 0, rifeEngines[mode] != nil {
            vsLock.lock(); let vt0 = vsTarget, vp0 = vsPeriod; vsLock.unlock()
            if vp0 > 0.004 {
                var ph = (CMTimeGetSeconds(hostNow()) - vt0).truncatingRemainder(dividingBy: vp0); if ph < 0 { ph += vp0 }
                var wait = opts.gpuPhaseMs / 1000.0 - ph; if wait < -0.0015 { wait += vp0 }
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        let schedNow = hostNow()
        let follow = opts.followArrival && opts.offsetMs <= 0
        if opts.offsetMs > 0 { liveOffsetMs = opts.offsetMs }
        else if readyHistory.count >= 20 {
            // Big (4K / BGRA) frames reaching the display layer only ~2 ms before their time often miss that refresh
            // (measured on the glass: bursts of shared refreshes whenever the hold sat on its lower step). 6 ms was clean.
            let big = rifeEngines[mode] != nil || (sourceW > 2600 && !(mode == .tiled && !opts.origNative))
            let want = percentile(readyHistory, 0.98) + (opts.marginMs >= 0 ? opts.marginMs : (big ? 8.0 : 2.0))
            if !offsetBootstrapped { liveOffsetMs = want; offsetBootstrapped = true }
            else if want > liveOffsetMs { liveOffsetMs = want }
            else if liveOffsetMs - want > 2 { liveOffsetMs -= max(0.05, (liveOffsetMs - want) * 0.01) }   // far above: come down in seconds, not minutes
        } else if liveOffsetMs == 0 { liveOffsetMs = follow ? 40 : 60 }
        // Follow mode: the capture card's delivery delay drifts in a slow sawtooth (its 60.000 fps clock against the
        // console's 59.94). Each frame's own delay is already known here, so only the processing time is estimated.
        effOffsetMs = follow ? min(100, max(0, ms(CMTimeSubtract(schedNow, pts)))) + liveOffsetMs : liveOffsetMs   // clamp: the first frames can carry wild timestamps
        let offset = CMTime(seconds: effOffsetMs / 1000.0, preferredTimescale: 1_000_000_000)
        var midTime = CMTimeAdd(pts, offset)          // generated frame
        var origTime = CMTimeAdd(midTime, half)        // this original, half a source interval later
        var hold = effOffsetMs + nominalHalfMs
        vsLock.lock(); let vt = vsTarget, vp = vsPeriod; vsLock.unlock()
        if opts.vsync && vp > 0.004 {
            // Put each frame on a definite screen refresh. Timestamp jitter of a millisecond or two can
            // then no longer flip a frame between two neighbouring refreshes.
            let p = CMTimeGetSeconds(pts)
            // Measured on the glass (ScreenCaptureKit frame status): 4K or BGRA frames handed over 3 ms before a refresh
            // often miss it and two frames then share one refresh (looks like flicker, or like no interpolation at all).
            // A sweep (1...15 ms, three 4K modes) found only 5 ms clean: 0 shared refreshes in 51 s per mode, while 3 ms
            // and 7-15 ms all showed bursts. Small NV12 frames are fine with 3 ms.
            let bigFrames = rifeEngines[mode] != nil || (sourceW > 2600 && !(mode == .tiled && !opts.origNative))
            let lead = (opts.leadMs >= 0 ? opts.leadMs : (bigFrames ? 5.0 : 3.0)) / 1000.0
            let desired = p + effOffsetMs / 1000.0 + lead                      // earliest refresh this frame can make
            var slot = vt + ((desired - vt) / vp).rounded(.up) * vp
            if consecutive && prevMidSlot > 0 {
                let steps = max(1, (gapMs / 1000.0 / vp).rounded())
                var expected = prevMidSlot + steps * vp
                expected = vt + ((expected - vt) / vp).rounded() * vp          // back onto the current grid
                // Keep the established phase while it is still reachable and not needlessly late.
                // The hold steps by one refresh as the card's delivery delay drifts. Right at a step the per-frame jitter
                // used to flip it back and forth for seconds; every flip puts two frames on one refresh or leaves one
                // empty (seen on the glass as bursts of flicker). Hence a dead band: go up only when really unreachable
                // (no tolerance: letting the headroom shrink by 3 ms brought the bursts back at the top of every delivery cycle), come down only with a clear 5 ms beyond one refresh to spare.
                // 2026-11-19: with a 12 ms band the hold still came down once per delivery cycle (the card's sawtooth plus the
                // one-capture-frame jump when the picked half changes add up to more than a refresh of slack): 65 level
                // changes in 15 minutes of play, seen as flicker in bursts. Steady now tolerates a whole extra refresh of
                // slack, so the established rhythm on the glass is kept through the cycle (--hold-band <ms> to override).
                // 2026-11-19 later the same day: the wider band (--hold-band 23) did stop the level changes but the flicker of the
                // fast tier stayed, and the careful tier sat at 101 ms instead of ~80. Default is back to 12 ms.
                let band = opts.holdBandMs >= 0 ? opts.holdBandMs / 1000.0 : (opts.steady ? 0.012 : 0.005)
                if expected >= desired && expected <= desired + vp + band { slot = expected }
            }
            prevMidSlot = slot
            let halfSlots = max(1, (nominalHalfMs / 1000.0 / vp).rounded())
            midTime = CMTime(seconds: slot - lead, preferredTimescale: 1_000_000_000)
            origTime = CMTime(seconds: slot + halfSlots * vp - lead, preferredTimescale: 1_000_000_000)
            hold = (slot + halfSlots * vp - p) * 1000.0
        }
        holdMs.append(hold)
        // The picture's hold now steps up and down with the card's delivery sawtooth (every ~8 s). Each change of the
        // sound's delay is an audible skip, so the sound keeps to the upper step: at most one refresh behind the picture.
        audioHoldHistory.append(hold)
        if audioHoldHistory.count > 600 { audioHoldHistory.removeFirst(audioHoldHistory.count - 600) }
        audio?.setDelay(percentile(audioHoldHistory, 0.95))

        var mid: CVPixelBuffer?
        var earlyMid: CVPixelBuffer?                   // GPU mode, long gap: the 1/3 picture, one refresh before `mid`
        var shown: CVPixelBuffer = pb                  // what represents this original on screen
        var work: CVPixelBuffer?
        let t0 = hostNow()
        if let rife = rifeEngines[mode] {
            let refreshes = (consecutive && vp > 0.004) ? Int((gapMs / (vp * 1000)).rounded()) : 2
            var customSteps: [Float]? = nil
            if (refreshes == 3 || refreshes == 4) && opts.multiMid {
                longGaps += 1
                // Two in-between pictures must both finish before the next picture arrives (one 30 fps slot, less
                // headroom), judged from this machine's measured time per picture. Otherwise one at 2/3 or 3/4:
                // two pictures that overrun the slot delay the next frame, which then looks like another held picture.
                let perPic = perPictureMs[mode] ?? 0
                let affordTwo = (mode == .rifeFast || mode == .rifeMedium) && perPic > 0 && 2 * perPic <= 1000.0 / 30.0 - 6.0
                customSteps = affordTwo
                    ? [Float(refreshes - 2) / Float(refreshes), Float(refreshes - 1) / Float(refreshes)]
                    : [Float(refreshes - 1) / Float(refreshes)]
            }
            let useGPUProtect = opts.protectStill && !opts.protectOnCPU
            sharpLock.lock(); let curCAS = casStrength; sharpLock.unlock()
            if let res = rife.stepFused(source: pb, consecutive: consecutive, timesteps: customSteps, gpuProtect: useGPUProtect, casStrength: curCAS) {
                let bgra = res.currBGRA
                shown = bgra
                defer { rifePrevBGRA = bgra }
                if useGPUProtect { lastProtectMs = 0.0 }
                if !res.mids.isEmpty {
                    let ms = rife.lastEngineMs / Double(res.mids.count)
                    let old = perPictureMs[mode] ?? 0
                    perPictureMs[mode] = old == 0 ? ms : old * 0.9 + ms * 0.1
                }

                var pushed: CVPixelBuffer? = nil
                if res.mids.count == 2 {
                    if opts.protectStill && opts.protectOnCPU, let p = rifePrevBGRA {
                        rife.protectStill(previous: p, current: bgra, mid: res.mids[0])
                    }
                    earlyMid = res.mids[0]
                    pushed = res.mids[1]
                } else if res.mids.count == 1 {
                    pushed = res.mids[0]
                }

                if let m = pushed, consecutive {
                    if opts.protectStill && opts.protectOnCPU, let p = rifePrevBGRA {
                        let tp = CACurrentMediaTime()
                        rife.protectStill(previous: p, current: bgra, mid: m)
                        lastProtectMs = (CACurrentMediaTime() - tp) * 1000
                    }
                    mid = m
                    rifeDebugCount += 1
                    if rifeDebugCount % 30 == 0 {
                        let a = meanBGRA(bgra), b = meanBGRA(m)
                        Log.shared.line(String(format: "   rife check: orig BGRA %.1f %.1f %.1f %.1f | mid %.1f %.1f %.1f %.1f | fmt %@ / %@ | %dx%d / %dx%d", a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3],
                                               fourCC(CVPixelBufferGetPixelFormatType(bgra)), fourCC(CVPixelBufferGetPixelFormatType(m)),
                                               CVPixelBufferGetWidth(bgra), CVPixelBufferGetHeight(bgra), CVPixelBufferGetWidth(m), CVPixelBufferGetHeight(m)))
                        if let p = rifePrevBGRA {
                            let pc = compareBGRA(p, bgra), mc = compareBGRA(m, bgra), mp = compareBGRA(m, p)
                            Log.shared.line(String(format: "   rife motion: |prev-cur| %.2f  |mid-cur| %.2f  |mid-prev| %.2f   detail: orig %.2f mid %.2f", pc.diff, mc.diff, mp.diff, mc.gradB, mc.gradA))
                        }
                        Log.shared.line("   rife tags: orig \(CVBufferCopyAttachments(bgra, .shouldPropagate).map { ($0 as NSDictionary).allKeys.count } ?? -1) keys, mid \(CVBufferCopyAttachments(m, .shouldPropagate).map { ($0 as NSDictionary).allKeys.count } ?? -1) keys")
                    }
                } else if consecutive { failed += 1 }
            } else { failed += 1; rife.reset() }
        } else if mode == .tiled, #available(macOS 26.0, *), let tiled, !tiledFailed {
            if let w = tiled.work(from: pb), let tiles = tiled.crop(w) {
                work = w
                if !opts.origNative { shown = w }
                if consecutive, let prev = prevTiles {
                    let t0 = hostNow()
                    mid = tiled.midpoint(previous: prev, current: tiles, previousPTS: prevPTS, currentPTS: pts, like: w)
                    let took = ms(CMTimeSubtract(hostNow(), t0))
                    if took > 100 { Log.shared.line(String(format: "slow interp: %.0f ms (frame gap %.1f ms)", took, ms(CMTimeSubtract(pts, prevPTS)))) }
                    if mid == nil { failed += 1 }
                }
                prevTiles = tiles
            } else { failed += 1; prevTiles = nil }
        } else if #available(macOS 26.0, *), let interp {
            if let scaled = interp.prepare(pb) {
                if consecutive, let prev = prevScaled {
                    mid = interp.midpoint(previous: prev, current: scaled, previousPTS: prevPTS, currentPTS: pts)
                    if mid == nil { failed += 1 }
                }
                prevScaled = scaled
            } else { failed += 1; prevScaled = nil }
        }
        prevPTS = pts

        if !opts.dump.isEmpty, let mid {
            dumpSeen += 1
            if dumpSeen > opts.dumpAfter && dumpSeen <= opts.dumpAfter + 6 {
                let k = dumpSeen - opts.dumpAfter, m = mid, o = shown, dir = opts.dump
                dumpQueue.async {
                    savePNG(m, String(format: "%@/%02d_a_mid.png", dir, k)); savePNG(o, String(format: "%@/%02d_b_orig.png", dir, k))
                    Log.shared.line("dumped pair \(k)")
                }
            }
        }
        if let mid {
            let ready = hostNow()
            interpMs.append(ms(CMTimeSubtract(ready, t0)))
            readyMs.append(ms(CMTimeSubtract(ready, pts)))
            warmup += 1
            if warmup > 10 {                               // the first frames after a start or mode switch are slow
                readyHistory.append(follow ? ms(CMTimeSubtract(ready, schedNow)) : readyMs.last!)
                if readyHistory.count > 180 { readyHistory.removeFirst(readyHistory.count - 180) }
            }
            let lateBy = ms(CMTimeSubtract(ready, midTime))
            if lateBy > 0 { lateMids += 1 }
            // One line per picture that was late or slow, with where its time went.
            if warmup > 10, lateBy > 0 || interpMs.last! > 33 {
                let r = rifeEngines[mode]
                Log.shared.line(String(format: "event %@: %@ | late by %.1f ms | delivery %.1f | interp %.1f (convert %.1f engine %.1f protect %.1f) | frame gap %.1f ms",
                                       Log.clock(), lateBy > 8 ? "dropped" : (lateBy > 0 ? "late" : "slow"), lateBy, ms(CMTimeSubtract(arrival, pts)), interpMs.last!,
                                       r?.lastConvertMs ?? 0, r?.lastEngineMs ?? 0, lastProtectMs, gapMs))
            }
            if lateBy > 8 { droppedMids += 1 }          // too late to be useful: show only the original
            else {
                if let e = earlyMid, vp > 0.004 {
                    let t = CMTimeSubtract(midTime, CMTime(seconds: vp, preferredTimescale: 1_000_000_000))
                    if ms(CMTimeSubtract(ready, t)) <= 2 { enqueue(e, at: t); earlyShown += 1 }      // only if it can still make its refresh
                }
                enqueue(mid, at: midTime); mids += 1
            }
        }
        if hostNow() > origTime { lateOrig += 1 }
        enqueue(shown, at: origTime)
        procMs.append(ms(CMTimeSubtract(hostNow(), arrival)))

        // Quality statistics, after the frames are on their way.
        if #available(macOS 26.0, *), let tiled, let work {
            let wl = meanLuma(work)
            if let mid {
                lumaSteps.append(abs(meanLuma(mid) - (wl + prevWorkLuma) / 2))
                seamDiffs.append(tiled.lastSeamDiff); textureDiffs.append(tiled.lastTextureDiff)
            }
            prevWorkLuma = wl
        }
        collector.observe(pb, pts: pts, gapMs: gapMs, mode: mode)
        report()
    }

    private func report() {
        let now = hostNow()
        let span = CMTimeGetSeconds(CMTimeSubtract(now, lastReport))
        guard span >= 1 else { return }
        let srcIs60 = currentActiveSourceFps() >= 50
        var stats: String
        if passing || fastSourceNoted {
            stats = String(format: "%.1f fps · %.0f ms · 丢帧 0", Double(frames) / span, percentile(procMs, 0.95))
            Log.shared.line(String(format: "src %@ in %.1f fps | pass-through | device delivery p50 %.1f p95 %.1f ms | our processing p95 %.2f ms (arrival -> display layer; excludes vsync and compositor)",
                                   sourceSize, Double(frames) / span, percentile(deliveryMs, 0.5), percentile(deliveryMs, 0.95), percentile(procMs, 0.95)))
        } else {
            // Scheduled hold from capture timestamp to the original's display time. Not included: delay inside the
            // capture device before the timestamp, waiting for the next display refresh, and the system compositor.
            let hold = percentile(holdMs, 0.5)
            seenLock.lock(); let seen = seenCount; seenCount = 0; seenLock.unlock()
            let src = srcIs60 ? String(format: "采集 %.0f 帧（其中新画面 %.0f）", Double(seen) / span, Double(frames) / span) : String(format: "采集 %.0f 帧", Double(frames) / span)
            stats = String(format: "%.1f fps · %.0f ms · 丢帧 %d", Double(frames + mids) / span, hold, droppedMids)
            Log.shared.line(String(format: "src %@ in %.1f fps | out %.1f fps | mid %d late %d dropped %d fail %d | orig late %d | delivery p50 %.1f p95 %.1f ms | ready p95 %.1f ms | interp p95 %.1f ms | offset %.1f ms | hold to refresh p50 %.1f p95 %.1f ms (%@) | beyond delivery %.1f ms",
                                   sourceSize, Double(frames) / span, Double(frames + mids) / span, mids, lateMids, droppedMids, failed, lateOrig,
                                   percentile(deliveryMs, 0.5), percentile(deliveryMs, 0.95), percentile(readyMs, 0.95), percentile(interpMs, 0.95),
                                   effOffsetMs, hold, percentile(holdMs, 0.95), opts.vsync && vsPeriod > 0.004 ? "on refresh grid" : "not aligned",
                                   hold - percentile(deliveryMs, 0.5)))
        }
        if srcIs60 && !opts.legacyPick { Log.shared.line("   picked half: \(pickParity), switches so far \(paritySwitches) | long gaps (50-67 ms) \(longGaps), filled with two pictures \(earlyShown) | picks so far by gap 25:\(pickGaps[0]) 33:\(pickGaps[1]) 42:\(pickGaps[2]) 50+:\(pickGaps[3]), same picture taken again \(samePictureAgain), repeat noise \(String(format: "%.3f", noiseFloor))") }
        if let r = rifeEngines[mode] { Log.shared.line(String(format: "   stages: convert %.1f engine %.1f protect %.1f ms", r.lastConvertMs, r.lastEngineMs, lastProtectMs)) }
        if upscaler.mode == .metalfx {
            let u = upscaler, k = u.key
            if u.gpuMs.isEmpty { Log.shared.line("   upscale: none this period (\(u.lastSkip))") }
            else { Log.shared.line(String(format: "   upscale %dx%d->%dx%d gpu p50 %.2f p95 %.2f wall p50 %.2f p95 %.2f ms (%d pictures)", k.inW, k.inH, k.outW, k.outH,
                                          percentile(u.gpuMs, 0.5), percentile(u.gpuMs, 0.95), percentile(u.wallMs, 0.5), percentile(u.wallMs, 0.95), u.gpuMs.count)) }
        }
        upscaler.gpuMs.removeAll(keepingCapacity: true); upscaler.wallMs.removeAll(keepingCapacity: true)
        if let sp = stillProtector { Log.shared.line(String(format: "   protect split: textures %.2f | submit-to-done %.2f (queued before GPU start %.2f, GPU run %.2f) ms", sp.splitTexMs, sp.splitWaitMs, sp.splitQueuedMs, sp.splitGpuMs)) }
        if let r = rifeEngines[mode], !r.engineSamples.isEmpty {
            Log.shared.line(String(format: "   stages all pictures: convert p50 %.1f p95 %.1f | engine p50 %.1f p95 %.1f max %.1f ms (%d pictures)",
                                   percentile(r.convertSamples, 0.5), percentile(r.convertSamples, 0.95), percentile(r.engineSamples, 0.5), percentile(r.engineSamples, 0.95), r.engineSamples.max() ?? 0, r.engineSamples.count))
            r.convertSamples.removeAll(keepingCapacity: true); r.engineSamples.removeAll(keepingCapacity: true)
        }
        if !seamDiffs.isEmpty {
            if #available(macOS 26.0, *), let tiled { Log.shared.line(String(format: "   stages: scale %.1f cut %.1f engine %.1f stitch %.1f ms", tiled.lastScaleMs, tiled.lastCropMs, tiled.lastEngineMs, tiled.lastStitchMs)) }
            Log.shared.line(String(format: "   seam: tiles differ %.2f in overlap (p95 %.2f) vs natural detail %.2f (0-255 scale)",
                                   seamDiffs.reduce(0, +) / Double(seamDiffs.count), percentile(seamDiffs, 0.95),
                                   textureDiffs.reduce(0, +) / Double(textureDiffs.count)))
            Log.shared.line(String(format: "   brightness: generated frame differs from its neighbours by %.2f (p95 %.2f) of 255",
                                   lumaSteps.reduce(0, +) / Double(max(1, lumaSteps.count)), percentile(lumaSteps, 0.95)))
            seamDiffs.removeAll(); textureDiffs.removeAll(); lumaSteps.removeAll()
        }
        if let curAudio = audio {
            let snap = curAudio.takeSnapshot()
            Log.shared.line(String(format: "   audio: %d buffers, delayed %.0f ms, clock resyncs %d, renderer failures %d", snap.buffers, snap.delay, snap.resyncs, snap.failures) + " | " + snap.dbg)
        }
        let sc = collector.totalSaved
        if sc > 0 { stats += " · 样本 \(sc)" }
        DispatchQueue.main.async { self.onStats?(stats) }
        holdMs.removeAll()
        frames = 0; mids = 0; lateMids = 0; lateOrig = 0; failed = 0; droppedMids = 0
        deliveryMs.removeAll(); readyMs.removeAll(); interpMs.removeAll(); procMs.removeAll()
        lastReport = now
    }
}

// MARK: - Console UI (card-row menu, toast, stats pill)

/// One card of the menu. The view reads it on every render; the closures read and change the live pipeline.
struct MenuItem {
    let title: String
    let symbol: String                 // SF Symbol name
    let options: () -> [String]
    let current: () -> Int             // -1: an action item, no option is "the current one"
    let apply: (Int) -> Void
    let note: (Int) -> String
}

/// Colors and sizes of the prototypes (Shelf.dc.html, Playing.dc.html), which are drawn on a 1280x720 artboard.
enum Look {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    static let white = CGColor(gray: 1, alpha: 1)
    static let clear = CGColor(gray: 0, alpha: 0)
    static let base = rgb(0x05070d)
    static let dim = rgb(0xa7b0c0)
    static let noteText = rgb(0xc4cbd8)
    static let hintText = rgb(0x6b7487)
    static let cardFocused = rgb(0x24304a)
    static let card = rgb(0x1a2133, 0.92)
    static let toast = rgb(0x141a28)
    static let pill = rgb(0x0b0f19, 0.92)
    static let transition: CFTimeInterval = 0.12

    /// Artboard pixels to points for a view of this height: 1.5 on a 1080-point 4K TV.
    static func scale(_ height: CGFloat) -> CGFloat { min(2, max(0.75, height / 720)) }

    static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, lineHeight: CGFloat? = nil, digits: Bool = false) -> NSAttributedString {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        if let lineHeight {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = lineHeight
            p.maximumLineHeight = lineHeight
            attrs[.paragraphStyle] = p
        }
        return NSAttributedString(string: s, attributes: attrs)
    }

    static func measure(_ a: NSAttributedString, width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let r = a.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// CATextLayer's own truncation draws a cut-off line half a line too low (seen with CJK text), so single lines are cut here.
    static func fitted(_ a: NSAttributedString, width: CGFloat) -> NSAttributedString {
        guard measure(a).width > width, a.length > 0 else { return a }
        let attrs = a.attributes(at: 0, effectiveRange: nil)
        var chars = Array(a.string)
        while !chars.isEmpty {
            chars.removeLast()
            let t = NSAttributedString(string: String(chars) + "…", attributes: attrs)
            if measure(t).width <= width { return t }
        }
        return NSAttributedString(string: "", attributes: attrs)
    }

    static func textLayer(wrapped: Bool = false, align: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let t = CATextLayer()
        t.isWrapped = wrapped
        t.truncationMode = .none
        t.alignmentMode = align
        return t
    }

    /// The bundle's AppIcon.icns; drawn here when the app runs outside its bundle.
    static let icon: CGImage = {
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return img }
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        drawMaccapIcon(ctx, size: 256)
        return ctx.makeImage()!
    }()

    /// Same drawing as tools/make_icon.swift: the prototype SVG (viewBox 256, y down).
    static func drawMaccapIcon(_ ctx: CGContext, size: CGFloat) {
        let k = size / 256
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: k, y: -k)
        ctx.setFillColor(rgb(0xefebe2))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 24, y: 24, width: 208, height: 208), cornerWidth: 48, cornerHeight: 48, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(rgb(0x1b1a17))
        ctx.setLineWidth(6)
        ctx.stroke(CGRect(x: 52, y: 62, width: 100, height: 74))
        ctx.stroke(CGRect(x: 104, y: 120, width: 100, height: 74))
        ctx.setFillColor(rgb(0xbf3320))
        ctx.fill(CGRect(x: 78, y: 91, width: 100, height: 74))
        ctx.restoreGState()
    }

    private static var symbols: [String: CGImage] = [:]

    /// A white SF Symbol fitted into a square of `box` points.
    static func symbol(_ name: String, box: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(name)@\(box)x\(scale)"
        if let hit = symbols[key] { return hit }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: box, weight: .regular)) else { return nil }
        let px = Int((box * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let k = min(box / img.size.width, box / img.size.height)
        let w = img.size.width * k, h = img.size.height * k
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: CGRect(x: (box - w) / 2, y: (box - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: 0, y: 0, width: box, height: box))
        let out = ctx.makeImage()
        symbols[key] = out
        return out
    }
}

/// Full-window console menu: top bar, a row of cards (one per MenuItem), and the focused card's options.
/// Static layers only. It animates (Look.transition) on open, close and focus change, and draws nothing while closed.
final class CardMenuView: NSView {
    var items: [MenuItem] = []
    var stats = "" { didSet { if isOpen && stats != oldValue { still { self.layoutTopBar() } } } }
    var hint = "" { didSet { if isOpen && hint != oldValue { still { self.layoutHint() } } } }
    private(set) var isOpen = false
    private var focus = 0
    private var option = 0
    private var rowShift: CGFloat = 0

    private final class Card {
        let ring = CALayer()
        let body = CALayer()
        let icon = CALayer()
        let value = Look.textLayer(align: .center)
    }

    private let scrim = CAGradientLayer()
    private let iconLayer = CALayer()
    private let nameLayer = Look.textLayer()
    private let statsLayer = Look.textLayer(align: .right)
    private var cards: [Card] = []
    private var cardRects: [CGRect] = []
    private let titleLayer = Look.textLayer()
    private var pillLayers: [CALayer] = []
    private var pillRects: [CGRect] = []
    private let noteLayer = Look.textLayer(wrapped: true)
    private let hintLayer = Look.textLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        isHidden = true
        scrim.startPoint = CGPoint(x: 0, y: 0.5)
        scrim.endPoint = CGPoint(x: 1, y: 0.5)
        scrim.colors = [Look.rgb(0x05070d, 0.96), Look.rgb(0x05070d, 0.82), Look.rgb(0x05070d, 0.35)]
        scrim.locations = [0, 0.5, 1]
        iconLayer.contents = Look.icon
        iconLayer.contentsGravity = .resizeAspect
        for l in [scrim, iconLayer, nameLayer, statsLayer, titleLayer, noteLayer, hintLayer] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var s: CGFloat { Look.scale(bounds.height) }
    private var px: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Bounds-relative rect in artboard orientation (y down) to layer geometry (y up).
    private func up(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) }

    private func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func currentOrFirst(_ i: Int) -> Int { max(0, items[i].current()) }

    // MARK: Commands

    func setOpen(_ open: Bool) {
        guard open != isOpen, let root = layer else { return }
        isOpen = open
        CATransaction.begin()
        CATransaction.setAnimationDuration(Look.transition)
        if open {
            if !items.isEmpty { focus = min(focus, items.count - 1); option = currentOrFirst(focus) }
            still { root.opacity = 0; self.render() }
            isHidden = false
            root.opacity = 1
        } else {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.isOpen else { return }
                self.isHidden = true
            }
            root.opacity = 0
        }
        CATransaction.commit()
    }

    /// Re-read every item from the model (after a setting changed somewhere).
    func reload() {
        guard isOpen else { return }
        still { render() }
    }

    func moveFocus(_ d: Int) {
        guard isOpen, !items.isEmpty else { return }
        let f = min(items.count - 1, max(0, focus + d))
        guard f != focus else { return }
        focus = f
        option = currentOrFirst(f)
        animated { render() }
    }

    func moveOption(_ d: Int) {
        guard isOpen, !items.isEmpty else { return }
        let n = items[focus].options().count
        let o = min(n - 1, max(0, option + d))
        guard o != option else { return }
        option = o
        animated { render() }
    }

    func activate() {
        guard isOpen, !items.isEmpty, option < items[focus].options().count else { return }
        items[focus].apply(option)
        reload()
    }

    private func animated(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Look.transition)
        body()
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let top = CGPoint(x: p.x, y: bounds.height - p.y)
        if let i = cardRects.firstIndex(where: { $0.contains(top) }) {
            if i != focus { focus = i; option = currentOrFirst(i); animated { render() } }
        } else if let j = pillRects.firstIndex(where: { $0.contains(top) }) {
            option = j
            activate()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reload()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reload()
    }

    // MARK: Layout (artboard units times s, y down, converted by up())

    private func render() {
        guard !items.isEmpty else { return }
        option = min(option, max(0, items[focus].options().count - 1))
        scrim.frame = bounds
        layoutTopBar()
        layoutCards()
        layoutDetails()
        layoutHint()
    }

    private func layoutTopBar() {
        let s = s, px = px
        iconLayer.frame = up(CGRect(x: 64 * s, y: 40 * s, width: 40 * s, height: 40 * s))
        let name = Look.text("Maccap", size: 20 * s, weight: .light, color: Look.white)
        let nsz = Look.measure(name)
        nameLayer.string = name
        nameLayer.contentsScale = px
        nameLayer.frame = up(CGRect(x: 118 * s, y: 60 * s - nsz.height / 2, width: nsz.width + 2, height: nsz.height))
        let st = Look.fitted(Look.text(stats, size: 14 * s, weight: .regular, color: Look.dim, digits: true), width: bounds.width / 2)
        let ssz = Look.measure(st)
        statsLayer.string = st
        statsLayer.contentsScale = px
        let w = min(ssz.width + 2, bounds.width / 2)
        statsLayer.frame = up(CGRect(x: bounds.width - 64 * s - w, y: 60 * s - ssz.height / 2, width: w, height: ssz.height))
    }

    private func layoutCards() {
        let s = s, px = px
        while cards.count < items.count {
            let c = Card()
            c.body.addSublayer(c.icon)
            c.body.addSublayer(c.value)
            layer?.addSublayer(c.ring)
            layer?.addSublayer(c.body)
            cards.append(c)
        }
        while cards.count > items.count {
            let c = cards.removeLast()
            c.ring.removeFromSuperlayer()
            c.body.removeFromSuperlayer()
        }
        let pad = 64 * s, gap = 22 * s, rowTop = 116 * s, rowH = 160 * s
        let sizes = items.indices.map { $0 == focus ? 150 * s : 118 * s }
        var starts: [CGFloat] = []
        var x: CGFloat = 0
        for w in sizes { starts.append(x); x += w + gap }
        let total = x - gap, avail = bounds.width - 2 * pad
        let f0 = starts[focus], f1 = f0 + sizes[focus]
        if f0 < rowShift { rowShift = f0 }
        if f1 - rowShift > avail { rowShift = f1 - avail }
        rowShift = max(0, min(rowShift, total - avail))

        cardRects = []
        for (i, c) in cards.enumerated() {
            let on = i == focus, w = sizes[i]
            let r = CGRect(x: pad + starts[i] - rowShift, y: rowTop + (rowH - w) / 2, width: w, height: w)
            cardRects.append(r)
            let item = items[i], opts = item.options(), cur = item.current()
            c.ring.frame = up(r.insetBy(dx: -6 * s, dy: -6 * s))
            c.ring.cornerRadius = 22 * s
            c.ring.backgroundColor = Look.rgb(0xffffff, 0.18)
            c.ring.opacity = on ? 1 : 0
            c.body.frame = up(r)
            c.body.cornerRadius = 16 * s
            c.body.borderWidth = 3 * s
            c.body.borderColor = on ? Look.white : Look.clear
            c.body.backgroundColor = on ? Look.cardFocused : Look.card
            c.body.shadowColor = Look.rgb(0x000000)
            c.body.shadowOpacity = on ? 0.6 : 0
            c.body.shadowRadius = 20 * s
            c.body.shadowOffset = CGSize(width: 0, height: -16 * s)
            c.body.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: 16 * s, cornerHeight: 16 * s, transform: nil)

            let label = Look.fitted(Look.text(opts.indices.contains(cur) ? opts[cur] : item.title, size: 12 * s, weight: .regular, color: on ? Look.white : Look.dim), width: w - 16 * s)
            let lh = Look.measure(label).height
            let icon = 34 * s, glyph = 28 * s, contentTop = (w - icon - 10 * s - lh) / 2
            c.icon.contents = Look.symbol(item.symbol, box: glyph, scale: px)
            c.icon.contentsScale = px
            c.icon.frame = CGRect(x: (w - glyph) / 2, y: w - contentTop - icon + (icon - glyph) / 2, width: glyph, height: glyph)
            c.value.string = label
            c.value.contentsScale = px
            c.value.frame = CGRect(x: 8 * s, y: w - contentTop - icon - 10 * s - lh, width: w - 16 * s, height: lh)
        }
    }

    private func layoutDetails() {
        let s = s, px = px
        let item = items[focus], opts = item.options(), cur = item.current()
        let left = 64 * s, maxW = min(620 * s, bounds.width - 2 * left)
        var y = 312 * s

        let title = Look.text(item.title, size: 52 * s, weight: .light, color: Look.white, lineHeight: 57.2 * s)
        let tsz = Look.measure(title, width: maxW)
        titleLayer.string = title
        titleLayer.contentsScale = px
        titleLayer.frame = up(CGRect(x: left, y: y, width: maxW, height: tsz.height))
        y += tsz.height + 18 * s

        still {
            pillLayers.forEach { $0.removeFromSuperlayer() }
            pillLayers = []
            pillRects = []
            var x = left
            let h = 48 * s
            for (j, o) in opts.enumerated() {
                let selected = j == cur
                let label = Look.text(o, size: 16 * s, weight: .semibold, color: selected ? Look.base : Look.white)
                let lsz = Look.measure(label)
                let w = lsz.width + 52 * s
                if x > left && x + w > left + maxW { x = left; y += h + 10 * s }
                let r = CGRect(x: x, y: y, width: w, height: h)
                pillRects.append(r)
                if j == option {
                    let ring = CALayer()
                    ring.frame = up(r.insetBy(dx: -5 * s, dy: -5 * s))
                    ring.cornerRadius = h / 2 + 5 * s
                    ring.borderWidth = 2 * s
                    ring.borderColor = Look.white
                    pillLayers.append(ring)
                }
                let p = CALayer()
                p.frame = up(r)
                p.cornerRadius = h / 2
                p.borderWidth = 2 * s
                p.borderColor = selected || j == option ? Look.white : Look.rgb(0xffffff, 0.35)
                p.backgroundColor = selected ? Look.white : Look.clear
                let t = Look.textLayer(align: .center)
                t.string = label
                t.contentsScale = px
                t.frame = CGRect(x: 0, y: (h - lsz.height) / 2, width: w, height: lsz.height)
                p.addSublayer(t)
                pillLayers.append(p)
                x += w + 10 * s
            }
            pillLayers.forEach { layer?.addSublayer($0) }
        }
        y += 48 * s + 18 * s

        let note = Look.text(opts.isEmpty ? "" : item.note(option), size: 18 * s, weight: .light, color: Look.noteText, lineHeight: 28.8 * s)
        let nsz = Look.measure(note, width: maxW)
        noteLayer.string = note
        noteLayer.contentsScale = px
        noteLayer.frame = up(CGRect(x: left, y: y, width: maxW, height: nsz.height))
    }

    private func layoutHint() {
        let s = s
        let h = Look.fitted(Look.text(hint, size: 12 * s, weight: .regular, color: Look.hintText), width: bounds.width - 128 * s)
        let sz = Look.measure(h)
        hintLayer.string = h
        hintLayer.contentsScale = px
        hintLayer.frame = up(CGRect(x: 64 * s, y: bounds.height - 40 * s - sz.height, width: min(sz.width + 2, bounds.width - 128 * s), height: sz.height))
    }
}

/// Top-right toast of Playing.dc.html: icon, bold first line, grey second line. Hides 2 s after the last show.
final class ToastView: NSView {
    private let iconLayer = CALayer()
    private let titleLayer = Look.textLayer(wrapped: true)
    private let detailLayer = Look.textLayer(wrapped: true)
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        isHidden = true
        autoresizingMask = [.minXMargin, .minYMargin]
        layer?.backgroundColor = Look.toast
        layer?.shadowColor = Look.rgb(0x000000)
        layer?.shadowOpacity = 0.5
        iconLayer.contents = Look.icon
        iconLayer.contentsGravity = .resizeAspect
        for l in [iconLayer, titleLayer, detailLayer] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title: String, detail: String) {
        guard let host = superview, let root = layer else { return }
        let s = Look.scale(host.bounds.height), px = window?.backingScaleFactor ?? 2
        let w = 340 * s, textX = 16 * s + 40 * s + 14 * s, textW = w - textX - 16 * s
        let t = Look.text(title, size: 15 * s, weight: .semibold, color: Look.white)
        let d = Look.text(detail, size: 13 * s, weight: .regular, color: Look.dim)
        let tsz = Look.measure(t, width: textW)
        let dsz = detail.isEmpty ? .zero : Look.measure(d, width: textW)
        let textH = tsz.height + (detail.isEmpty ? 0 : 3 * s + dsz.height)
        let h = max(40 * s, textH) + 28 * s
        let top = (h - textH) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = NSRect(x: host.bounds.width - 32 * s - w, y: host.bounds.height - 28 * s - h, width: w, height: h)
        root.cornerRadius = 14 * s
        root.shadowRadius = 18 * s
        root.shadowOffset = CGSize(width: 0, height: -12 * s)
        root.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 14 * s, cornerHeight: 14 * s, transform: nil)
        iconLayer.frame = CGRect(x: 16 * s, y: (h - 40 * s) / 2, width: 40 * s, height: 40 * s)
        titleLayer.string = t
        titleLayer.contentsScale = px
        titleLayer.frame = CGRect(x: textX, y: h - top - tsz.height, width: textW, height: tsz.height)
        detailLayer.string = d
        detailLayer.contentsScale = px
        detailLayer.frame = CGRect(x: textX, y: h - top - textH, width: textW, height: dsz.height)
        detailLayer.isHidden = detail.isEmpty
        CATransaction.commit()
        isHidden = false
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// Bottom-left stats pill of Playing.dc.html. `nil` hides it.
final class StatsPillView: NSView {
    private let textLayer = Look.textLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        isHidden = true
        autoresizingMask = [.maxXMargin, .maxYMargin]
        layer?.backgroundColor = Look.pill
        layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ line: String?) {
        guard let line, let host = superview else { isHidden = true; return }
        let s = Look.scale(host.bounds.height)
        let t = Look.text(line, size: 13 * s, weight: .regular, color: Look.white, digits: true)
        let sz = Look.measure(t)
        let h = sz.height + 12 * s, w = sz.width + 28 * s
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = NSRect(x: 28 * s, y: 24 * s, width: w, height: h)
        layer?.cornerRadius = h / 2
        textLayer.string = t
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.frame = CGRect(x: 14 * s, y: 6 * s, width: sz.width + 1, height: sz.height)
        CATransaction.commit()
        isHidden = false
    }
}

// MARK: - App

/// A borderless window does not take key presses unless it says it can.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ContentView: NSView {
    var buildContextMenu: (() -> NSMenu)?
    var onDoubleClickBackground: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClickBackground?()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        buildContextMenu?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var window: NSWindow!
    var contentView: ContentView!
    var activeScreen: NSScreen?
    let pipeline = Pipeline()
    var displayLink: CADisplayLink?
    let toast = ToastView(frame: .zero)
    let statsPill = StatsPillView(frame: .zero)
    private var liveStats: String?
    var hudPinned = Prefs.loadHudPinned()
    var installingHelper = false
    var runningBenchmark = false
    var isBorderlessFullscreen = false
    var savedWindowedFrame: NSRect?
    let cardMenu = CardMenuView(frame: .zero)
    private var menuOverVideo = false   // P opened the menu over a playing stream
    private var streamActive = false

    private let windowedStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    private let fullscreenWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    private let controlMenu = NSMenu(title: "控制")

    private var desiredWindowLevel: NSWindow.Level {
        isBorderlessFullscreen ? fullscreenWindowLevel : .normal
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        ProcessInfo.processInfo.environment["CI_HEADLESS"] != "1"
    }

    /// Toast for a status line ("title　　detail"). Forced lines always show; the rest only while the stats pill is pinned.
    func showStatus(_ text: String, force: Bool = false) {
        cardMenu.reload()
        guard hudPinned || force else { return }
        let parts = text.components(separatedBy: "　　")
        toast.show(title: parts[0], detail: parts.dropFirst().joined(separator: " "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline.shutdown()
    }

    @objc func refreshTick(_ link: CADisplayLink) {
        pipeline.updateVsync(target: link.targetTimestamp, period: link.targetTimestamp - link.timestamp)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isHeadless = ProcessInfo.processInfo.environment["CI_HEADLESS"] == "1"
        if !isHeadless && opts.file.isEmpty {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else {
                    Log.shared.line("camera permission denied")
                    DispatchQueue.main.async { self.showCameraPermissionAlertAndExit() }
                    return
                }
                let go = { DispatchQueue.main.async { self.begin() } }
                if !self.pipeline.isAudioEnabled { go(); return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    if !ok { Log.shared.line("microphone permission denied: no sound from the capture device") }
                    go()
                }
            }
        } else if !opts.file.isEmpty {
            DispatchQueue.main.async { self.begin() }
        } else {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else { Log.shared.line("camera permission denied"); DispatchQueue.main.async { NSApp.terminate(nil) }; return }
                DispatchQueue.main.async { self.begin() }
            }
        }
    }

    private func showCameraPermissionAlertAndExit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要摄像头权限才能读取 PS5 采集卡画面"
        alert.informativeText = "免驱 HDMI 采集卡在 macOS 中识别为外接摄像头。\n请在「系统设置 → 隐私与安全性 → 摄像头」中勾选 CaptureInterp，然后重新打开本应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    private func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    private func diagonal(_ s: NSScreen) -> Double {
        let mm = CGDisplayScreenSize(displayID(s))
        return Double((mm.width * mm.width + mm.height * mm.height).squareRoot())
    }

    private func attachDisplayLink(to screen: NSScreen) {
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(refreshTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func defaultWindowedRect(on screen: NSScreen) -> NSRect {
        let vis = screen.visibleFrame
        let w = min(1240.0, max(860.0, vis.width * 0.80))
        let h = min(760.0, max(580.0, vis.height * 0.82))
        let x = vis.origin.x + (vis.width - w) * 0.5
        let y = vis.origin.y + (vis.height - h) * 0.5
        return NSRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    private func setBorderlessFullscreen(_ targetFull: Bool) {
        guard let window, let screen = activeScreen ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if targetFull == isBorderlessFullscreen { return }
        if targetFull {
            savedWindowedFrame = window.frame
            isBorderlessFullscreen = true
            window.styleMask = [.borderless]
            window.isMovableByWindowBackground = false
            window.level = fullscreenWindowLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: true)
        } else {
            isBorderlessFullscreen = false
            window.level = .normal
            window.collectionBehavior = [.managed]
            window.styleMask = windowedStyleMask
            window.titlebarAppearsTransparent = true
            window.title = "CaptureInterp — 苹果电脑接 PS5 实时补帧"
            window.isMovableByWindowBackground = true
            let restore = savedWindowedFrame ?? defaultWindowedRect(on: screen)
            window.setFrame(restore, display: true)
        }
        window.contentView = contentView
        contentView.layer?.contentsScale = screen.backingScaleFactor
        pipeline.layer.contentsScale = screen.backingScaleFactor
        pipeline.layer.frame = contentView.bounds
        pipeline.updateDisplayTarget()
        window.makeKeyAndOrderFront(nil)
        updateMenuVisibility()
    }

    func windowDidResize(_ notification: Notification) {
        guard let contentView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pipeline.layer.frame = contentView.bounds
        CATransaction.commit()
        pipeline.updateDisplayTarget()
    }

    private func moveToScreen(_ screen: NSScreen, savePref: Bool) {
        activeScreen = screen
        if savePref { Prefs.saveScreenName(screen.localizedName) }
        if isBorderlessFullscreen {
            window.setFrame(screen.frame, display: true)
        } else {
            let rect = defaultWindowedRect(on: screen)
            savedWindowedFrame = rect
            window.setFrame(rect, display: true)
        }
        contentView.layer?.contentsScale = screen.backingScaleFactor
        pipeline.layer.contentsScale = screen.backingScaleFactor
        pipeline.layer.frame = contentView.bounds
        pipeline.updateDisplayTarget()
        attachDisplayLink(to: screen)
        showStatus("输出显示器：\(screen.localizedName)", force: true)
    }

    // MARK: - Card-row menu

    private func activeScreenIndex() -> Int {
        let id = activeScreen.map { displayID($0) } ?? 0
        return NSScreen.screens.firstIndex { displayID($0) == id } ?? -1
    }

    private func makeMenuItems() -> [MenuItem] {
        let p = pipeline
        let modes: [Mode] = [.pass, .rifeFast, .rifeMedium, .rifeBalanced]
        let widths = [0, 2560, 1920]
        let sharpness: [Float] = [0.0, 0.55, 0.90]
        let gains = [0.0, 12.0, 20.0, 26.0]
        func notes(_ n: [String]) -> (Int) -> String { { n.indices.contains($0) ? n[$0] : "" } }
        return [
            MenuItem(title: "补帧档位", symbol: "square.on.square",
                     options: { ["直通", "[4] 低延迟", "[6] 均衡", "[5] 画质"] },
                     current: { modes.firstIndex(of: p.requestedMode) ?? -1 },
                     apply: { p.setMode(modes[$0]) },
                     note: notes(["不补帧。没有等待，只有 30 帧。", "单帧约 17 ms，延迟约 68 ms。最稳。", "单帧约 25 ms。画质更好，余量小。", "M1 Pro 跟不上 2K，会掉到约 48 帧。"])),
            MenuItem(title: "采集分辨率", symbol: "viewfinder",
                     options: { ["4K", "2K", "1080p"] },
                     current: { let w = p.currentMaxWidth; return w == 0 ? 0 : (w <= 1920 ? 2 : 1) },
                     apply: { p.selectMaxWidth(widths[$0]) },
                     note: notes(["M1 Pro 补不动 4K，只适合直通。", "推荐。PS5 输出 4K，这里缩到 2K 再补帧。", "最省，画面最软。"])),
            MenuItem(title: "MetalFX 超分", symbol: "arrow.up.left.and.arrow.down.right",
                     options: { ["关", "开"] },
                     current: { p.upscaler.mode == .metalfx ? 1 : 0 },
                     apply: { if ($0 == 1) != (p.upscaler.mode == .metalfx) { p.toggleUpscale() } },
                     note: notes(["系统直接拉伸到 4K，文字发虚。", "用 MetalFX 放大到 4K，每帧约 2 ms。"])),
            MenuItem(title: "锐化", symbol: "triangle",
                     options: { ["关", "0.55", "0.90"] },
                     current: { let v = p.currentSharpness; return v < 0.15 ? 0 : (v < 0.75 ? 1 : 2) },
                     apply: { p.setSharpness(sharpness[$0]) },
                     note: notes(["开 MetalFX 时推荐关。", "标准锐化。", "强锐化，噪点会变明显。"])),
            MenuItem(title: "状态条", symbol: "chart.xyaxis.line",
                     options: { ["隐藏", "常显"] },
                     current: { [unowned self] in self.hudPinned ? 1 : 0 },
                     apply: { [unowned self] in self.setHudPinned($0 == 1) },
                     note: notes(["游玩时屏幕上只有画面。", "角落常显帧率和延迟。"])),
            MenuItem(title: "声音", symbol: "speaker.wave.2",
                     options: { ["静音", "+0 dB", "+12 dB", "+20 dB", "+26 dB"] },
                     current: {
                         guard p.isAudioEnabled else { return 0 }
                         let g = p.currentAudioGainDb
                         return 1 + (g < 6 ? 0 : (g < 16 ? 1 : (g < 23 ? 2 : 3)))
                     },
                     apply: { if $0 == 0 { p.setAudioEnabled(false) } else { p.setAudioGainDb(gains[$0 - 1]) } },
                     note: notes(["不放采集卡的声音。", "原始音量。采集卡的声音通常很轻。", "适中放大。", "默认。声音延后，和画面对齐。", "强放大。声音大时会破音。"])),
            MenuItem(title: "输入源", symbol: "cable.connector",
                     options: { ["自动识别"] + videoDevices().map { $0.localizedName + ($0.deviceType == .external ? " [外接]" : "") } + ["刷新设备"] },
                     current: {
                         let pref = p.currentDevicePref
                         guard !pref.isEmpty else { return 0 }
                         return videoDevices().firstIndex { $0.localizedName.localizedCaseInsensitiveContains(pref) }.map { $0 + 1 } ?? 0
                     },
                     apply: { [unowned self] i in
                         let devs = videoDevices()
                         if i == 0 { p.selectVideoDevice("") }
                         else if i <= devs.count { p.selectVideoDevice(devs[i - 1].localizedName) }
                         else { self.refreshDevices() }
                     },
                     note: { i in
                         let devs = videoDevices()
                         if i == 0 { return "自动找外接采集卡。PS5 要关 HDCP，否则黑屏。" }
                         if i <= devs.count { return devs[i - 1].deviceType == .external ? "只用这台外接设备。" : "只用这台设备。它不是外接采集卡。" }
                         return "重新找设备。没有画面时马上连接。"
                     }),
            MenuItem(title: "输出屏幕", symbol: "display",
                     options: { NSScreen.screens.map { "\($0.localizedName)（\(Int($0.frame.width * $0.backingScaleFactor))×\(Int($0.frame.height * $0.backingScaleFactor))）" } },
                     current: { [unowned self] in self.activeScreenIndex() },
                     apply: { [unowned self] i in
                         let screens = NSScreen.screens
                         if screens.indices.contains(i) { self.moveToScreen(screens[i], savePref: true) }
                     },
                     note: { [unowned self] i in i == self.activeScreenIndex() ? "画面在这块屏幕上。" : "把画面移到这块屏幕。" }),
            MenuItem(title: "工具", symbol: "wrench.and.screwdriver",
                     options: { [unowned self] in
                         [self.runningBenchmark ? "实测中…" : "一键实测 (B)", self.isBorderlessFullscreen ? "退出全屏 (F)" : "进入全屏 (F)", "10G 直读 (U)"]
                     },
                     current: { -1 },
                     apply: { [unowned self] i in
                         switch i {
                         case 0: self.runHardwareBenchmarkDialog()
                         case 1: self.setBorderlessFullscreen(!self.isBorderlessFullscreen)
                         default: self.toggleRawUSB()
                         }
                     },
                     note: { [unowned self] i in
                         switch i {
                         case 0: return self.runningBenchmark ? "正在测算。结果会弹窗显示。" : "约 3 秒。测出本机能带哪一档。"
                         case 1: return self.isBorderlessFullscreen ? "退回窗口模式。" : "无边框全屏。按 F 切换。"
                         default:
                             if p.usingRawUSB { return "已开启。再按一次切回系统采集。" }
                             return RawUVCCapture.verifyHelperBinary(RawUVCCapture.installedHelperPath).ok
                                 ? "绕过系统驱动直读 USB。4K60 不丢帧。" : "先安装直读组件。需要管理员密码。"
                         }
                     }),
        ]
    }

    /// Open while no stream plays; over a stream only after P (or --open-menu).
    private func updateMenuVisibility() {
        let streaming = pipeline.isStreaming
        cardMenu.hint = streaming ? "← → 选卡片　↑ ↓ 选值　Return 确定　Esc 回到游戏" : "← → 选卡片　↑ ↓ 选值　Return 确定　插上采集卡后自动出画面"
        cardMenu.stats = streaming ? (liveStats ?? "已连接 · \(pipeline.currentSourceSize)") : "未检测到采集卡"
        cardMenu.setOpen(!streaming || menuOverVideo)
        cardMenu.reload()
        updateStatsPill()
    }

    private func updateStatsPill() {
        statsPill.show(hudPinned && pipeline.isStreaming && !cardMenu.isOpen ? liveStats : nil)
    }

    @objc private func toggleMenu(_ sender: Any?) {
        if pipeline.isStreaming { menuOverVideo.toggle() }
        updateMenuVisibility()
    }

    @objc private func uiToggleFullscreen(_ sender: Any?) {
        setBorderlessFullscreen(!isBorderlessFullscreen)
    }

    private func refreshDevices() {
        cardMenu.reload()
        guard !pipeline.isStreaming else { return }
        if pipeline.start() {
            showStatus("采集设备已连接（\(pipeline.currentSourceSize)）", force: true)
        } else {
            showStatus("仍未检测到外接 PS5 采集卡，请检查 USB 与 HDMI 连接", force: true)
        }
    }

    private func setHudPinned(_ on: Bool) {
        hudPinned = on
        Prefs.saveHudPinned(on)
        if on { showStatus("状态条：常显", force: true) }
        updateStatsPill()
        cardMenu.reload()
    }

    private func toggleRawUSB() {
        if !pipeline.usingRawUSB && !RawUVCCapture.verifyHelperBinary(RawUVCCapture.installedHelperPath).ok {
            promptInstallUVCHelper(activateAfterInstall: true)
            return
        }
        pipeline.toggleCaptureSource()
    }

    // MARK: - Menu Construction & Actions

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 CaptureInterp", action: #selector(orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏 CaptureInterp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(hideItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 CaptureInterp", action: #selector(menuQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu

        let ctrlItem = NSMenuItem(title: "控制", action: nil, keyEquivalent: "")
        controlMenu.delegate = self
        ctrlItem.submenu = controlMenu
        main.addItem(ctrlItem)

        NSApp.mainMenu = main
    }

    @objc private func orderFrontStandardAboutPanel(_ sender: Any?) {
        window?.level = .normal
        NSApp.orderFrontStandardAboutPanel(sender)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.installingHelper && !self.runningBenchmark { self.window?.level = self.desiredWindowLevel }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateSettingsMenu(menu)
    }

    private func buildPopupSettingsMenu() -> NSMenu {
        let m = NSMenu(title: "CaptureInterp 设置")
        populateSettingsMenu(m)
        return m
    }

    private func popUpMenuOnWindow() {
        guard let view = contentView, let win = window else { return }
        let m = buildPopupSettingsMenu()
        let mouseInWin = win.mouseLocationOutsideOfEventStream
        let inside = view.bounds.contains(mouseInWin)
        let pt = inside ? mouseInWin : NSPoint(x: 32, y: max(48, view.bounds.height - 48))
        m.popUp(positioning: nil, at: pt, in: view)
    }

    private func populateSettingsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        func addHeader(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // 0. Panel, Fullscreen & Benchmark
        let menuOpen = cardMenu.isOpen
        let panelItem = NSMenuItem(title: menuOpen ? "收起菜单 (P)" : "打开菜单 (P)", action: #selector(toggleMenu(_:)), keyEquivalent: "")
        panelItem.target = self
        panelItem.isEnabled = pipeline.isStreaming || !menuOpen
        menu.addItem(panelItem)

        let fsItem = NSMenuItem(title: isBorderlessFullscreen ? "退回窗口模式 (F / Esc)" : "进入无边框全屏游玩 (F)", action: #selector(uiToggleFullscreen(_:)), keyEquivalent: "f")
        fsItem.target = self
        menu.addItem(fsItem)

        let benchTitle = runningBenchmark
            ? "正在实测本机芯片算力（请稍候）…"
            : "⚡ 一键测算本机接 PS5 推荐档位 (B)…"
        let benchItem = NSMenuItem(title: benchTitle, action: #selector(menuRunBenchmark(_:)), keyEquivalent: "")
        benchItem.target = self
        benchItem.isEnabled = !runningBenchmark && !installingHelper
        menu.addItem(benchItem)
        menu.addItem(.separator())

        // 1. Interpolation Mode
        addHeader("PS5 补帧档位（快捷键 1–6）")
        let curMode = pipeline.mode
        let modeEntries: [(Mode, String, Bool)] = {
            var sysAvail = false
            if #available(macOS 26.0, *) { sysAvail = true }
            return [
                (.pass, "[1] 直通·不补帧（60帧原生游戏用）", true),
                (.rifeFast, "[4] 显卡·延迟低（极速）", true),
                (.rifeMedium, "[6] 显卡·均衡 4.5 档（推荐）", true),
                (.rifeBalanced, "[5] 显卡·画质好（高算力 Mac 推荐）", true),
                (.single, "[2] 系统单块·720p（需 macOS 26+）", sysAvail),
                (.tiled, "[3] 系统分块·2K（需 macOS 26+）", sysAvail),
            ]
        }()
        for (m, label, enabled) in modeEntries {
            let item = NSMenuItem(title: label, action: #selector(menuSelectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m.rawValue
            item.state = (curMode == m) ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 2. Sharpness & Resolution
        let sharpSub = NSMenu(title: "画面锐化")
        let curSharp = pipeline.currentSharpness
        let sharpChoices: [(String, Float)] = [
            ("关（0.0）", 0.0),
            ("标准（0.55，默认）", 0.55),
            ("强（0.90）", 0.90),
        ]
        for (label, val) in sharpChoices {
            let it = NSMenuItem(title: label, action: #selector(menuSelectSharpness(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: val)
            it.state = abs(curSharp - val) < 0.12 ? .on : .off
            sharpSub.addItem(it)
        }
        let sharpParent = NSMenuItem(title: "画面锐化 (K)", action: nil, keyEquivalent: "")
        sharpParent.submenu = sharpSub
        menu.addItem(sharpParent)

        let resSub = NSMenu(title: "采集分辨率上限")
        let curMW = pipeline.currentMaxWidth
        let resChoices: [(String, Int)] = [
            ("原生最高（4K 3840×2160）", 0),
            ("限制 2K（2560×1440）", 2560),
            ("限制 1080p（1920×1080）", 1920),
        ]
        for (label, mw) in resChoices {
            let it = NSMenuItem(title: label, action: #selector(menuSelectMaxWidth(_:)), keyEquivalent: "")
            it.target = self
            it.tag = mw
            it.state = (curMW == mw || (mw == 2560 && curMW > 1920 && curMW < 3840) || (mw == 1920 && curMW > 0 && curMW <= 1920)) ? .on : .off
            resSub.addItem(it)
        }
        let resParent = NSMenuItem(title: "采集分辨率上限", action: nil, keyEquivalent: "")
        resParent.submenu = resSub
        menu.addItem(resParent)

        // 3. Output Display
        let scrSub = NSMenu(title: "输出显示器")
        let curScrID = activeScreen.map { displayID($0) } ?? 0
        for s in NSScreen.screens {
            let pxW = Int(s.frame.width * s.backingScaleFactor)
            let pxH = Int(s.frame.height * s.backingScaleFactor)
            let it = NSMenuItem(title: "\(s.localizedName)（\(pxW)×\(pxH)）", action: #selector(menuSelectScreen(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            it.state = (displayID(s) == curScrID) ? .on : .off
            scrSub.addItem(it)
        }
        let scrParent = NSMenuItem(title: "输出显示器", action: nil, keyEquivalent: "")
        scrParent.submenu = scrSub
        menu.addItem(scrParent)

        menu.addItem(.separator())

        // 4. Capture Device & 10G Raw-USB Helper
        let devSub = NSMenu(title: "采集输入设备")
        let curDevPref = pipeline.currentDevicePref
        let autoDevItem = NSMenuItem(title: "自动识别外接 PS5 采集卡（推荐）", action: #selector(menuSelectDevice(_:)), keyEquivalent: "")
        autoDevItem.target = self
        autoDevItem.representedObject = ""
        autoDevItem.state = curDevPref.isEmpty ? .on : .off
        devSub.addItem(autoDevItem)
        let devs = videoDevices()
        if !devs.isEmpty { devSub.addItem(.separator()) }
        for d in devs {
            let tag = (d.deviceType == .external) ? " [外接]" : " [内置/其它]"
            let it = NSMenuItem(title: d.localizedName + tag, action: #selector(menuSelectDevice(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.localizedName
            it.state = (!curDevPref.isEmpty && d.localizedName.localizedCaseInsensitiveContains(curDevPref)) ? .on : .off
            devSub.addItem(it)
        }
        let devParent = NSMenuItem(title: "采集输入设备", action: nil, keyEquivalent: "")
        devParent.submenu = devSub
        menu.addItem(devParent)

        let helperInstalled = RawUVCCapture.verifyHelperBinary(RawUVCCapture.installedHelperPath).ok
        let rawItem = NSMenuItem(title: "启用 USB 256KB 无损直读 (U)", action: #selector(menuToggleRawUSB(_:)), keyEquivalent: "")
        rawItem.target = self
        rawItem.state = pipeline.usingRawUSB ? .on : .off
        menu.addItem(rawItem)

        let helperTitle = helperInstalled
            ? "重新安装 / 更新 10G 采集卡直读组件… [已安装]"
            : "安装 10G 采集卡直读组件（解锁满血 4K60 无损）…"
        let installItem = NSMenuItem(title: helperTitle, action: #selector(menuInstallHelper(_:)), keyEquivalent: "")
        installItem.target = self
        installItem.isEnabled = !installingHelper
        menu.addItem(installItem)

        menu.addItem(.separator())

        // 5. Audio & Gain
        let audOn = pipeline.isAudioEnabled
        let audToggle = NSMenuItem(title: "播放采集卡声音", action: #selector(menuToggleAudio(_:)), keyEquivalent: "")
        audToggle.target = self
        audToggle.state = audOn ? .on : .off
        menu.addItem(audToggle)

        let gainSub = NSMenu(title: "音量放大")
        let curGain = pipeline.currentAudioGainDb
        for (label, db) in [("不放大（+0 dB）", 0.0), ("适中（+12 dB）", 12.0), ("标准（+20 dB，默认）", 20.0), ("强（+26 dB）", 26.0)] {
            let it = NSMenuItem(title: label, action: #selector(menuSelectAudioGain(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: db)
            it.state = (audOn && abs(curGain - db) < 1.5) ? .on : .off
            gainSub.addItem(it)
        }
        let gainParent = NSMenuItem(title: "音量放大（解决采集卡声音轻）", action: nil, keyEquivalent: "")
        gainParent.submenu = gainSub
        menu.addItem(gainParent)

        menu.addItem(.separator())

        // 6. Diagnostics & Quit
        let hudItem = NSMenuItem(title: "状态栏常显 (H)", action: #selector(menuToggleHud(_:)), keyEquivalent: "")
        hudItem.target = self
        hudItem.state = hudPinned ? .on : .off
        menu.addItem(hudItem)

        let sampleItem = NSMenuItem(title: "抓取最近 1 秒原画样本 (S)", action: #selector(menuSaveSample(_:)), keyEquivalent: "")
        sampleItem.target = self
        menu.addItem(sampleItem)

        let logItem = NSMenuItem(title: "在访达中查看运行日志", action: #selector(menuRevealLog(_:)), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        let qItem = NSMenuItem(title: "退出 CaptureInterp (Q)", action: #selector(menuQuit(_:)), keyEquivalent: "")
        qItem.target = self
        menu.addItem(qItem)
    }

    @objc private func menuSelectMode(_ sender: NSMenuItem) {
        if let m = Mode(rawValue: sender.tag) {
            pipeline.setMode(m)
            self.cardMenu.reload()
        }
    }

    @objc private func menuSelectSharpness(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber {
            pipeline.setSharpness(n.floatValue)
            cardMenu.reload()
        }
    }

    @objc private func menuSelectMaxWidth(_ sender: NSMenuItem) {
        pipeline.selectMaxWidth(sender.tag)
        cardMenu.reload()
    }

    @objc private func menuSelectScreen(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? NSScreen { moveToScreen(s, savePref: true) }
    }

    @objc private func menuSelectDevice(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            pipeline.selectVideoDevice(name)
            cardMenu.reload()
        }
    }

    @objc private func menuToggleRawUSB(_ sender: NSMenuItem) {
        toggleRawUSB()
    }

    @objc private func menuInstallHelper(_ sender: NSMenuItem) {
        promptInstallUVCHelper(activateAfterInstall: true)
    }

    @objc private func menuToggleAudio(_ sender: NSMenuItem) {
        pipeline.setAudioEnabled(!pipeline.isAudioEnabled)
        cardMenu.reload()
    }

    @objc private func menuSelectAudioGain(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber {
            pipeline.setAudioGainDb(n.doubleValue)
            cardMenu.reload()
        }
    }

    @objc private func menuToggleHud(_ sender: NSMenuItem) {
        setHudPinned(!hudPinned)
    }

    @objc private func menuSaveSample(_ sender: NSMenuItem) {
        pipeline.collector.saveManual { [weak self] msg in self?.showStatus(msg, force: true) }
    }

    @objc private func menuRevealLog(_ sender: NSMenuItem) {
        Log.shared.flush()
        let url = URL(fileURLWithPath: opts.log)
        if FileManager.default.fileExists(atPath: opts.log) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    @objc private func menuQuit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func menuRunBenchmark(_ sender: Any?) {
        runHardwareBenchmarkDialog()
    }

    private func runHardwareBenchmarkDialog() {
        guard !runningBenchmark && !installingHelper else { return }
        runningBenchmark = true
        cardMenu.reload()
        showStatus("正在实测本机芯片 4K / 2K / 1080p 补帧算力（约 3 秒）…", force: true)

        DispatchQueue.global(qos: .userInitiated).async {
            self.pipeline.setBenchmarkPaused(true)
            let rep = HardwareBenchmark.run { step in
                DispatchQueue.main.async { self.showStatus(step, force: true) }
            }
            self.pipeline.setBenchmarkPaused(false)
            Log.shared.line("hardware benchmark completed:\n" + rep.formattedSummary())

            DispatchQueue.main.async {
                self.runningBenchmark = false
                self.cardMenu.reload()
                self.window?.level = .normal
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "本机接 PS5 补帧算力实测结果"
                alert.informativeText = rep.formattedSummary()
                if rep.recommended != nil {
                    alert.addButton(withTitle: "一键应用推荐档位")
                    alert.addButton(withTitle: "保持当前设置")
                } else {
                    alert.addButton(withTitle: "知道了")
                }

                let resp = alert.runModal()
                self.window?.level = self.desiredWindowLevel
                self.window?.makeKeyAndOrderFront(nil)

                if resp == .alertFirstButtonReturn, let rec = rep.recommended {
                    self.pipeline.applyRecommendedPreset(mode: rec.mode, maxWidth: rec.maxWidth)
                    self.cardMenu.reload()
                } else {
                    self.showStatus("测算完成，保持当前模式：" + self.pipeline.mode.title, force: true)
                }
            }
        }
    }

    private func locateBundledHelperInstaller() -> String? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL {
            let p = resURL.appendingPathComponent("helper/install_uvc_helper.sh").path
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let repoPath = (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).appendingPathComponent("tools/install_uvc_helper.sh")
        if fm.isExecutableFile(atPath: repoPath) { return repoPath }
        return nil
    }

    private func promptInstallUVCHelper(activateAfterInstall: Bool) {
        guard !installingHelper else { return }
        guard let installerPath = locateBundledHelperInstaller() else {
            showStatus("未找到内置 10G 直读安装脚本", force: true)
            return
        }
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "安装 10G 采集卡 USB 无损直读组件"
        alert.informativeText = "针对 Realtek 0bda:0911 主控的 USB 3.2 10Gbps 采集卡，macOS 自带驱动会把每次读取切碎为 16KB，导致 4K60 掉帧。\n\n点击「授权安装」后，系统将请求管理员密码，把只读采集组件安装到 /usr/local/libexec/captureinterp-uvc-helper，解锁 256KB 大包满血 4K60 无损直读（无需打开终端或安装 Xcode）。"
        alert.addButton(withTitle: "授权安装")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn else {
            window?.level = desiredWindowLevel
            return
        }

        installingHelper = true
        cardMenu.reload()
        showStatus("正在等待管理员授权安装 10G 直读组件…", force: true)
        let user = NSUserName()
        let appleScript = """
        on run argv
            set installerPath to item 1 of argv
            set targetUser to item 2 of argv
            set cmd to quoted form of installerPath & " --user " & quoted form of targetUser
            do shell script cmd with administrator privileges
        end run
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", appleScript, installerPath, user]
            let errPipe = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errPipe
            var ok = false
            var errMsg = ""
            do {
                try p.run()
                p.waitUntilExit()
                ok = (p.terminationStatus == 0)
                if !ok {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errMsg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            } catch {
                errMsg = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.installingHelper = false
                self.window?.level = self.desiredWindowLevel
                self.window?.makeKeyAndOrderFront(nil)
                if ok && RawUVCCapture.verifyHelperBinary(RawUVCCapture.installedHelperPath).ok {
                    Log.shared.line("uvc helper installed via GUI")
                    self.showStatus("10G 直读组件安装完成", force: true)
                    if activateAfterInstall && !self.pipeline.usingRawUSB {
                        self.pipeline.setRawUSBEnabled(true)
                    }
                } else if errMsg.contains("-128") || errMsg.localizedCaseInsensitiveContains("canceled") || errMsg.contains("取消") {
                    self.showStatus("已取消安装 10G 直读组件", force: true)
                } else {
                    Log.shared.line("uvc helper GUI install failed: \(errMsg)")
                    self.showStatus("直读组件安装未完成，继续使用系统采集", force: true)
                }
                self.cardMenu.reload()
            }
        }
    }

    func begin() {
        if ProcessInfo.processInfo.environment["CI_HEADLESS"] == "1" {
            if opts.fileExplicit && opts.file.isEmpty { Log.shared.line("--file path is empty"); NSApp.terminate(nil); return }
            guard !opts.fileExplicit ? pipeline.start() : pipeline.startFile(opts.file) else { NSApp.terminate(nil); return }
            if let s = ProcessInfo.processInfo.environment["CI_TEST_MANUAL_AT"], let sec = Double(s), sec > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                    self.pipeline.collector.saveManual { Log.shared.line("headless manual notify: \($0)") }
                }
            }
            if opts.seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + opts.seconds) { NSApp.terminate(nil) } }
            return
        }
        setupMainMenu()
        let screens = NSScreen.screens
        let named = opts.screenName.isEmpty ? nil : screens.first { $0.localizedName.localizedCaseInsensitiveContains(opts.screenName) }
        let external = screens.filter { CGDisplayIsBuiltin(displayID($0)) == 0 }.max { diagonal($0) < diagonal($1) }
        let automatic = opts.screenExplicit && screens.indices.contains(opts.screen) ? screens[opts.screen] : (external ?? NSScreen.main ?? screens[0])
        let screen = named ?? automatic
        activeScreen = screen
        Log.shared.line(String(format: "screen: %@ (%.0f mm diagonal, %.0fx%.0f px, %@)", screen.localizedName, diagonal(screen),
                               screen.frame.width * screen.backingScaleFactor, screen.frame.height * screen.backingScaleFactor,
                               named != nil ? "named" : (opts.screenExplicit ? "by index" : "chosen automatically")))

        let initialRect = defaultWindowedRect(on: screen)
        savedWindowedFrame = initialRect
        window = KeyWindow(contentRect: initialRect, styleMask: windowedStyleMask, backing: .buffered, defer: false, screen: screen)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1.0)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "CaptureInterp — 苹果电脑接 PS5 实时补帧"
        window.minSize = NSSize(width: 780, height: 540)
        window.delegate = self

        let view = ContentView(frame: NSRect(origin: .zero, size: initialRect.size))
        view.autoresizingMask = [.width, .height]
        view.buildContextMenu = { [weak self] in
            self?.buildPopupSettingsMenu() ?? NSMenu()
        }
        view.onDoubleClickBackground = { [weak self] in
            guard let self else { return }
            self.setBorderlessFullscreen(!self.isBorderlessFullscreen)
        }
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1.0).cgColor
        view.layer?.contentsScale = screen.backingScaleFactor
        pipeline.layer.contentsScale = screen.backingScaleFactor
        pipeline.layer.frame = view.bounds
        pipeline.updateDisplayTarget()
        pipeline.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(pipeline.layer)
        contentView = view
        window.contentView = view

        cardMenu.frame = view.bounds
        cardMenu.autoresizingMask = [.width, .height]
        cardMenu.items = makeMenuItems()
        view.addSubview(cardMenu)
        view.addSubview(statsPill)
        view.addSubview(toast)

        if opts.fullscreen {
            setBorderlessFullscreen(true)
        } else {
            window.setFrame(initialRect, display: true)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        pipeline.onStreamStateChange = { [weak self] active in
            guard let self else { return }
            if active && !self.streamActive { self.menuOverVideo = false }
            if !active { self.liveStats = nil }
            self.streamActive = active
            self.updateMenuVisibility()
        }
        pipeline.onStats = { [weak self] line in
            guard let self else { return }
            self.liveStats = line
            if self.pipeline.isStreaming { self.cardMenu.stats = line }
            self.updateStatsPill()
        }
        pipeline.onStatus = { [weak self] text in
            guard let self else { return }
            let important = text.hasPrefix("模式") || text.hasPrefix("锐化") || text.hasPrefix("放大") || text.hasPrefix("输入源") || text.hasPrefix("采集") || text.hasPrefix("分辨率") || text.hasPrefix("声音") || text.hasPrefix("音量") || text.hasPrefix("正在实测") || text.hasPrefix("已应用推荐") || text.hasPrefix("测算完成") || text.contains("断开") || text.contains("直读") || text.contains("自动直通") || text.contains("连接") || text.contains("未检测") || text.contains("2/3 档")
            self.showStatus(text, force: important)
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.contains(.command) {
                if (e.charactersIgnoringModifiers ?? "").lowercased() == "f" {
                    self.setBorderlessFullscreen(!self.isBorderlessFullscreen)
                    return nil
                }
                return e
            }
            if self.cardMenu.isOpen {
                switch e.keyCode {
                case 123: self.cardMenu.moveFocus(-1); return nil
                case 124: self.cardMenu.moveFocus(1); return nil
                case 125: self.cardMenu.moveOption(1); return nil
                case 126: self.cardMenu.moveOption(-1); return nil
                case 36, 76: self.cardMenu.activate(); return nil
                default: break
                }
            }
            let key = (e.charactersIgnoringModifiers ?? "").lowercased()
            if let digit = Int(key), let m = Mode(rawValue: digit) {
                self.pipeline.setMode(m)
                self.cardMenu.reload()
                return nil
            }
            switch key {
            case "q": NSApp.terminate(nil); return nil
            case "f": self.setBorderlessFullscreen(!self.isBorderlessFullscreen); return nil
            case "p": self.toggleMenu(nil); return nil
            case "m": self.popUpMenuOnWindow(); return nil
            case "b": self.runHardwareBenchmarkDialog(); return nil
            case "k": self.pipeline.cycleSharpness(); self.cardMenu.reload(); return nil
            case "x": self.pipeline.toggleUpscale(); return nil
            case "u": self.toggleRawUSB(); return nil
            case "s":
                self.pipeline.collector.saveManual { [weak self] msg in self?.showStatus(msg, force: true) }
                return nil
            case "h":
                self.setHudPinned(!self.hudPinned)
                return nil
            default: break
            }
            if e.keyCode == 53 { // Esc: close the menu over a stream first, then leave fullscreen
                if self.pipeline.isStreaming && self.menuOverVideo {
                    self.menuOverVideo = false
                    self.updateMenuVisibility()
                    return nil
                }
                if self.isBorderlessFullscreen {
                    self.setBorderlessFullscreen(false)
                    return nil
                }
                return e
            }
            return e
        }
        attachDisplayLink(to: screen)
        if !opts.file.isEmpty {
            guard pipeline.startFile(opts.file) else { NSApp.terminate(nil); return }
            pipeline.onStreamStateChange?(true)
            showStatus("模式：" + pipeline.mode.title, force: true)
        } else if pipeline.start() {
            showStatus("模式：" + pipeline.mode.title, force: true)
        } else {
            updateMenuVisibility()
            pipeline.startWaitingForDevice()
        }
        if opts.openMenu {
            menuOverVideo = true
            updateMenuVisibility()
        }
        if opts.seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + opts.seconds) { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(ProcessInfo.processInfo.environment["CI_HEADLESS"] == "1" ? .prohibited : .regular)
app.run()
