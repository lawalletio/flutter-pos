import AVFoundation
import Flutter

/// iOS side of `pos/sounds`. Mirrors MainActivity.kt: Dart hands over raw
/// PCM16 once, then plays cues by name.
final class Sounds {
  private let queue = DispatchQueue(label: "pos.sounds")
  private let engine = AVAudioEngine()
  private var players: [String: (node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer)] = [:]
  private var endsAt: [String: CFTimeInterval] = [:]
  private var sustains: [String: SustainClip] = [:]
  private var sustainNode: AVAudioSourceNode?

  init(messenger: FlutterBinaryMessenger) {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, options: [.mixWithOthers])
    try? session.setActive(true)
    _ = engine.mainMixerNode

    FlutterMethodChannel(name: "pos/sounds", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self,
          let args = call.arguments as? [String: Any],
          let name = args["name"] as? String
        else {
          result(FlutterError(code: "SOUND", message: "missing name", details: nil))
          return
        }
        self.queue.async {
          do {
            try self.handle(call.method, name, args)
            DispatchQueue.main.async { result(nil) }
          } catch Unimplemented.method {
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          } catch {
            NSLog("sound \(name) failed: \(error)")
            DispatchQueue.main.async {
              result(FlutterError(code: "SOUND", message: "\(error)", details: nil))
            }
          }
        }
      }
  }

  private enum Unimplemented: Error { case method }

  private func handle(_ method: String, _ name: String, _ args: [String: Any]) throws {
    let volume = Float((args["volume"] as? NSNumber)?.doubleValue ?? 1).clamped
    switch method {
    case "load":
      try load(name, pcm: bytes(args["pcm"]), rate: int(args["rate"]), channels: int(args["channels"]))
    case "play":
      try play(name, volume: volume, loop: args["loop"] as? Bool ?? false)
    case "stop":
      players[name]?.node.stop()
      endsAt[name] = 0
    case "loadSustain":
      let channels = try int(args["channels"])
      sustains[name] = try SustainClip(
        rate: Double(int(args["rate"])),
        channels: channels,
        intro: floats(bytes(args["intro"]), channels),
        loop: floats(bytes(args["loop"]), channels),
        release: floats(bytes(args["release"]), channels))
    case "startSustain":
      guard let clip = sustains[name] else { return }
      try startSustain(clip, volume: volume)
    case "stopSustain":
      sustainVoice?.stopping = true
    default:
      throw Unimplemented.method
    }
  }

  // MARK: one-shots

  private func load(_ name: String, pcm: Data, rate: Int, channels: Int) throws {
    let frames = pcm.count / 2 / channels
    if let existing = players[name], Int(existing.buffer.frameLength) == frames { return }
    if let existing = players[name] {
      existing.node.stop()
      engine.detach(existing.node)
    }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { throw SoundError("bad format \(rate)Hz x\(channels)") }
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = floats(pcm, channels)
    for c in 0..<channels {
      samples[c].withUnsafeBufferPointer {
        buffer.floatChannelData![c].update(from: $0.baseAddress!, count: frames)
      }
    }
    let node = AVAudioPlayerNode()
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    players[name] = (node, buffer)
  }

  private func play(_ name: String, volume: Float, loop: Bool) throws {
    guard let player = players[name], volume > 0 else { return }
    let (node, buffer) = player
    let now = CACurrentMediaTime()
    // Peg clicks arrive faster than the clip; let the current one finish.
    if !loop, name == "tick", now < endsAt[name] ?? 0 { return }
    try ensureRunning()
    node.stop()
    node.volume = volume
    node.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [])
    node.play()
    endsAt[name] = loop ? .infinity : now + Double(buffer.frameLength) / buffer.format.sampleRate
  }

  // The engine stops on interruptions and route changes; restart lazily.
  private func ensureRunning() throws {
    if engine.isRunning { return }
    try? AVAudioSession.sharedInstance().setActive(true)
    try engine.start()
  }

  // MARK: sustain

  private var sustainVoice: SustainVoice?

  /// Intro, then the loop until stopped, then the release crossfaded out of
  /// wherever the loop was. Rendered live so the stop lands within one render
  /// cycle instead of waiting for the 2 s loop to wrap.
  private func startSustain(_ clip: SustainClip, volume: Float) throws {
    if let old = sustainNode { engine.detach(old) }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.rate, channels: AVAudioChannelCount(clip.channels))
    else { throw SoundError("bad sustain format") }
    let voice = SustainVoice(clip)
    let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, list in
      voice.render(UnsafeMutableAudioBufferListPointer(list), Int(frameCount), isSilence)
      return noErr
    }
    node.volume = volume
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    sustainNode = node
    sustainVoice = voice
    try ensureRunning()
  }

  // MARK: PCM helpers

  private func bytes(_ value: Any?) throws -> Data {
    guard let data = value as? FlutterStandardTypedData else { throw SoundError("missing pcm") }
    return data.data
  }

  private func int(_ value: Any?) throws -> Int {
    guard let n = value as? NSNumber else { throw SoundError("missing rate/channels") }
    return n.intValue
  }

  /// Interleaved little-endian PCM16 to one Float array per channel.
  private func floats(_ pcm: Data, _ channels: Int) -> [[Float]] {
    let frames = pcm.count / 2 / channels
    var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
    pcm.withUnsafeBytes { raw in
      let s = raw.bindMemory(to: Int16.self)
      for f in 0..<frames {
        for c in 0..<channels {
          out[c][f] = Float(Int16(littleEndian: s[f * channels + c])) / 32768
        }
      }
    }
    return out
  }
}

private struct SoundError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private extension Float {
  var clamped: Float { Swift.min(Swift.max(self, 0), 1) }
}

private struct SustainClip {
  let rate: Double
  let channels: Int
  let intro: [[Float]]
  let loop: [[Float]]
  let release: [[Float]]
}

/// Playhead for one sustain, advanced on the audio render thread.
private final class SustainVoice {
  private enum Phase { case intro, loop, release, done }

  let clip: SustainClip
  // ponytail: plain Bool read from the render thread; a lost write only delays the stop one cycle.
  var stopping = false
  private var phase = Phase.intro
  private var pos = 0
  private var loopAt = 0  // loop frame the release crossfades out of
  private let fadeFrames: Int

  init(_ clip: SustainClip) {
    self.clip = clip
    fadeFrames = min(Int(clip.rate * 0.04), clip.release.first?.count ?? 0)
  }

  func render(_ out: UnsafeMutableAudioBufferListPointer, _ frames: Int, _ isSilence: UnsafeMutablePointer<ObjCBool>) {
    let channels = clip.channels
    let loopCount = clip.loop.first?.count ?? 0
    for f in 0..<frames {
      for c in 0..<channels { sample(out, c, f, next(c, loopCount)) }
      advance(loopCount)
    }
    if phase == .done { isSilence.pointee = true }
  }

  private func sample(_ out: UnsafeMutableAudioBufferListPointer, _ c: Int, _ f: Int, _ v: Float) {
    out[c].mData!.assumingMemoryBound(to: Float.self)[f] = v
  }

  private func next(_ c: Int, _ loopCount: Int) -> Float {
    switch phase {
    case .intro: return clip.intro[c][pos]
    case .loop: return clip.loop[c][pos]
    case .release:
      let tail = clip.release[c][pos]
      guard pos < fadeFrames, loopCount > 0 else { return tail }
      // 40 ms equal-power crossfade from the loop into the natural ending.
      let w = Float(sin(Double(pos) / Double(fadeFrames) * .pi / 2))
      return tail * w + clip.loop[c][(loopAt + pos) % loopCount] * (1 - w * w).squareRoot()
    case .done: return 0
    }
  }

  private func advance(_ loopCount: Int) {
    pos += 1
    switch phase {
    case .intro where pos >= clip.intro[0].count:
      pos = 0
      phase = stopping || loopCount == 0 ? .release : .loop
    case .loop:
      if pos >= loopCount { pos = 0 }
      if stopping {
        loopAt = pos
        pos = 0
        phase = .release
      }
    case .release where pos >= clip.release[0].count:
      phase = .done
    default:
      break
    }
  }
}
