//
//  main.swift
//  Transport checks. Compiled and run by run.sh, never shipped in the app.
//
//  These drive a real AVAudioEngine, so they need an audio output device and
//  skip themselves on a machine without one.
//
//  The sequence below is a regression test for a specific reported bug: press J
//  to play backwards, then Space to play forwards, and the app would lose track
//  of its own playback. isPlaying went false while the audio carried on, the
//  position ticker stopped, and the playhead was thrown to the very end of the
//  clip, so the cursor vanished off screen and could not be stopped.
//
//  The cause: player.stop() flushes the scheduled buffer, which fires that
//  buffer's completion handler; the handler from the pass that was just
//  cancelled then tore down the pass that had just started. Playback passes now
//  carry a generation stamp and stale handlers are ignored.
//
//  Verified to fail against the pre-fix engine, with exactly the reported
//  symptoms, before being kept.
import AVFoundation
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !ok { failures += 1 }
}

// The work has to run on the main actor, so the main thread must stay free to
// service it. RunLoop.main.run() at the bottom does that, and unlike
// dispatchMain() it also drives the Timer that updates the playhead.
DispatchQueue.main.async { Task { @MainActor in
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let clip = AudioClip()
    clip.adopt(try! AudioClip.decode(url: dir.appendingPathComponent("test.wav")))
    let engine = PlaybackEngine()
    engine.prepare(for: clip)

    guard engine.isEngineRunning else {
        print("SKIP  transport checks  [no audio output device on this machine]")
        exit(0)
    }

    let whole = 0..<clip.frameCount

    func settle(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // Start in the middle so backwards playback has somewhere to go.
    engine.playhead = clip.frameCount / 2

    // 1. J
    engine.shuttleBackward(range: whole)
    await settle(0.25)
    check("J starts playing backwards", engine.isPlaying && engine.playingBackwards,
          "playing=\(engine.isPlaying) backwards=\(engine.playingBackwards)")
    let afterJ = engine.playhead

    // 2. Space, which replaces the backwards pass with a forwards one. This is
    //    the step that used to be destroyed by the cancelled pass's completion
    //    handler arriving late.
    engine.play(range: whole, from: engine.playhead, backwards: false)
    await settle(0.35)
    check("Space after J keeps playing, forwards",
          engine.isPlaying && !engine.playingBackwards,
          "playing=\(engine.isPlaying) backwards=\(engine.playingBackwards)")
    check("the playhead is not thrown to the end of the clip",
          engine.playhead < clip.frameCount - 1000,
          "playhead \(engine.playhead) of \(clip.frameCount)")
    check("the playhead is actually advancing",
          engine.playhead != afterJ, "\(afterJ) -> \(engine.playhead)")

    // 3. Space again: it must really stop.
    engine.pause()
    let stopped = engine.playhead
    await settle(0.3)
    check("pause stops and stays stopped", !engine.isPlaying)
    check("the playhead holds still after pausing",
          engine.playhead == stopped, "\(stopped) -> \(engine.playhead)")

    // 4. And the engine is still usable afterwards.
    engine.play(range: whole, from: 0, backwards: false)
    await settle(0.25)
    check("playback still works after all that", engine.isPlaying)
    engine.stop()
    await settle(0.15)
    check("stop leaves it stopped", !engine.isPlaying)

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
} }
RunLoop.main.run()
