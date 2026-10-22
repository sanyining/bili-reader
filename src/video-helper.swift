// video-helper.swift — 本地音视频文件离线读取助手（v0.4.0 新增）
//
// 为什么要有它：屏幕读取（screen-helper / audio-helper）有一个物理上限 ——
// 「录制」必须跟着播放实时走，10 分钟的视频就要等 10 分钟。用户问
// 「能不能由你把视频加速播放」：对别的 App 的播放器我们做不到（纯只读、
// 不注入键鼠），但对**本地文件**可以 —— 文件就在磁盘上，直接离线解码，
// 处理速度只取决于 CPU，与播放速度无关。10 分钟的课几十秒就能读完。
//
// 职责（两条独立通路，输出到同一个临时目录）：
//   audio  —— AVAssetReader 直接解出音轨 PCM → 混单声道 → 线性重采样 16k
//            → 写 16-bit WAV（与 audio-helper 输出同规格，可直接交给
//            SenseVoice 转写）。完整不缺段：不管视频多长，语音稿是全量的。
//   frames —— AVAssetImageGenerator 按间隔抽帧存 PNG，OCR 由上层复用
//            screen-helper 完成（本助手不重复实现 Vision）。
//
// 设计约束：
//   - 只处理本地文件（必须是存在的常规文件路径，不接受 URL/网络流）
//   - 只输出 JSON 到 stdout，日志走 stderr
//   - 不联网；抽出的帧与 wav 由调用方负责删除
//
// 用法：
//   video-helper probe   <file>
//   video-helper extract <file> <outDir> [--interval 1.5] [--max-frames 240]

import Foundation
import AVFoundation
import AppKit
import CoreMedia

// MARK: - 输出

func emit(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("{\"ok\":false,\"error\":\"encode_failed\"}")
    }
}

func emitError(_ code: String, _ message: String = "") {
    emit(["ok": false, "error": code, "message": message])
}

func stderr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func argValue(_ argv: [String], _ name: String) -> String? {
    guard let idx = argv.firstIndex(of: name), idx + 1 < argv.count else { return nil }
    return argv[idx + 1]
}

// MARK: - WAV 写出（与 audio-helper 同规格：PCM 16-bit 单声道）

func writeWav(samples: [Int16], sampleRate: Int, to path: String) throws {
    var d = Data()
    let dataSize = samples.count * MemoryLayout<Int16>.size

    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

    d.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + dataSize))
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8))
    u32(16)
    u16(1)
    u16(1)
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 2))
    u16(2)
    u16(16)
    d.append(contentsOf: Array("data".utf8))
    u32(UInt32(dataSize))
    samples.withUnsafeBytes { buf in d.append(contentsOf: buf) }

    try d.write(to: URL(fileURLWithPath: path))
}

// MARK: - 音轨提取：解码 → 混单声道 → 重采样 16k

func extractAudio(asset: AVURLAsset, outPath: String) async throws -> [String: Any] {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else {
        return ["ok": false, "error": "no_audio_track", "message": "文件里没有音频轨。"]
    }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        // 交错输出，通道数保持原样，混单声道在下面手工做（ reader 不保证降混）
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()

    var raw: [Int16] = []
    var channels = 1
    var srcRate = 44_100

    while let sb = output.copyNextSampleBuffer() {
        if let fmt = CMSampleBufferGetFormatDescription(sb),
           let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            let asbd = asbdPtr.pointee
            channels = max(1, Int(asbd.mChannelsPerFrame))
            srcRate = Int(asbd.mSampleRate)
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { continue }
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let p = ptr.bindMemory(to: Int16.self)
            raw.append(contentsOf: UnsafeBufferPointer(start: p.baseAddress!, count: length / 2))
        }
    }
    // AVAssetReader.Status 只有 unknown / reading / completed / failed / cancelled
    // （没有 .finished，写错会编译报错）
    guard reader.status == .completed else {
        return ["ok": false, "error": "read_failed",
                "message": "音轨解码未走完（status=\(reader.status.rawValue)）："
                    + "\(reader.error?.localizedDescription ?? "未知原因")"]
    }

    // 混单声道（交错格式：相邻 L/R 取平均）
    var mono: [Int16] = []
    mono.reserveCapacity(raw.count / max(1, channels))
    if channels <= 1 {
        mono = raw
    } else {
        var i = 0
        while i + channels <= raw.count {
            var sum = 0
            for c in 0..<channels { sum += Int(raw[i + c]) }
            let avg = sum / channels
            mono.append(Int16(max(-32768, min(32767, avg))))
            i += channels
        }
    }

    // 线性插值重采样到 16k（ASR 引擎要求）。语音场景线性插值足够。
    let targetRate = 16_000
    let resampled: [Int16]
    if srcRate == targetRate || mono.isEmpty {
        resampled = mono
    } else {
        let ratio = Double(srcRate) / Double(targetRate)
        let outCount = Int(Double(mono.count) / ratio)
        var out = [Int16](repeating: 0, count: outCount)
        for j in 0..<outCount {
            let pos = Double(j) * ratio
            let i0 = Int(pos)
            let i1 = min(i0 + 1, mono.count - 1)
            let frac = pos - Double(i0)
            let v = Double(mono[i0]) * (1 - frac) + Double(mono[i1]) * frac
            out[j] = Int16(max(-32768, min(32767, v.rounded())))
        }
        resampled = out
    }

    try writeWav(samples: resampled, sampleRate: targetRate, to: outPath)
    let seconds = Double(resampled.count) / Double(targetRate)

    return [
        "ok": true,
        "path": outPath,
        "sampleRate": targetRate,
        "seconds": (seconds * 100).rounded() / 100,
        "sourceRate": srcRate,
        "sourceChannels": channels,
    ]
}

// MARK: - 抽帧

func extractFrames(asset: AVURLAsset, outDir: String, interval: Double,
                   maxFrames: Int, durationSec: Double) async throws -> [[String: Any]] {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    // 容差给 interval/4：换解码关键帧，速度快很多；对字幕 OCR 来说 ±0.4s 无感
    let tol = CMTime(seconds: max(0.1, interval / 4), preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tol
    gen.requestedTimeToleranceAfter = tol

    // 实际步长：用户给的间隔与「帧数上限」约束取大者（长视频自动放稀，
    // 语音稿不受影响 —— 音频是全量的，字幕漏了也有人声兜底）
    let step = max(interval, durationSec / Double(maxFrames))
    var times: [Double] = []
    var t = 0.0
    while t < durationSec - 0.05, times.count < maxFrames {
        times.append(t)
        t += step
    }

    var frames: [[String: Any]] = []
    for (i, ts) in times.enumerated() {
        var actual = CMTime.zero
        do {
            let cg = try gen.copyCGImage(at: CMTime(seconds: ts, preferredTimescale: 600),
                                         actualTime: &actual)
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = String(format: "f%04d.png", i)
            let p = "\(outDir)/\(name)"
            try png.write(to: URL(fileURLWithPath: p))
            frames.append([
                "path": p,
                "t": (ts * 10).rounded() / 10,
                "bytes": png.count,
            ])
        } catch {
            stderr("第 \(i) 帧（\(ts)s）抽取失败：\(error.localizedDescription)")
        }
    }
    return frames
}

// MARK: - 入口

let argv = CommandLine.arguments

guard argv.count >= 2 else {
    emitError("usage", "video-helper <probe|extract> <file> [args]")
    exit(1)
}

let command = argv[1]

guard command == "probe" || command == "extract" else {
    emitError("unknown_command", command)
    exit(1)
}
guard argv.count >= 3 else {
    emitError("usage", "video-helper \(command) <本地文件路径>")
    exit(1)
}

let filePath = argv[2]

// 只接受真实存在的本地常规文件：不解析 URL、不碰网络
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else {
    emitError("file_not_found", "文件不存在或不是常规文件：\(filePath)")
    exit(1)
}

let sem = DispatchSemaphore(value: 0)
var payload: [String: Any] = ["ok": false, "error": "unknown"]

Task {
    let t0 = Date()
    do {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)

        let duration = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(duration)
        guard durationSec > 0.2 else {
            payload = ["ok": false, "error": "bad_duration", "message": "媒体时长异常（\(durationSec)s）。"]
            sem.signal()
            return
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var size: [String: Any] = [:]
        if let v = videoTracks.first {
            let dim = try await v.load(.naturalSize)
            size = ["width": Int(abs(dim.width)), "height": Int(abs(dim.height))]
        }

        if command == "probe" {
            payload = [
                "ok": true,
                "path": filePath,
                "durationSec": (durationSec * 10).rounded() / 10,
                "hasVideo": !videoTracks.isEmpty,
                "hasAudio": !audioTracks.isEmpty,
                "size": size,
                "format": "本地文件（AVFoundation 离线解码）",
            ]
            sem.signal()
            return
        }

        // ---- extract ----
        let outDir = argv[3]
        let interval = Double(argValue(argv, "--interval") ?? "1.5") ?? 1.5
        let maxFrames = Int(argValue(argv, "--max-frames") ?? "240") ?? 240
        // --no-frames：同目录已有字幕文件时，画面路不需要抽帧（省掉解码 + 写 PNG）
        let noFrames = argv.contains("--no-frames")

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var result: [String: Any] = [
            "ok": true,
            "path": filePath,
            "durationSec": (durationSec * 10).rounded() / 10,
            "hasVideo": !videoTracks.isEmpty,
            "hasAudio": !audioTracks.isEmpty,
        ]

        if !audioTracks.isEmpty {
            let audio = try await extractAudio(asset: asset, outPath: "\(outDir)/audio.wav")
            result["audio"] = audio
        }

        if !videoTracks.isEmpty && !noFrames {
            let frames = try await extractFrames(
                asset: asset, outDir: outDir,
                interval: max(0.5, interval), maxFrames: max(10, maxFrames),
                durationSec: durationSec)
            result["frames"] = frames
            result["frameCount"] = frames.count
        } else if noFrames {
            result["frames"] = []
            result["frameCount"] = 0
            result["framesSkipped"] = true
        }

        let elapsed = Date().timeIntervalSince(t0)
        result["elapsedSec"] = (elapsed * 10).rounded() / 10
        // 加速倍数：同样的内容，实时播放要 durationSec，离线解码只用了 elapsed
        result["speedup"] = (durationSec / max(0.01, elapsed) * 10).rounded() / 10

        payload = result
    } catch {
        payload = ["ok": false, "error": "extract_failed", "message": error.localizedDescription]
    }
    sem.signal()
}

sem.wait()
emit(payload)
