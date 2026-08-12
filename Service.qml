import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Genesis — a voice-controlled AI agent for Omarchy.
//
// Loaded as a `service` plugin by omarchy-shell (Quattro). It is driven over
// IPC (`omarchy-shell -q genesis <method>`) by the bar widget, keybindings,
// and the wake-word listener, and renders its own listening/confirmation
// overlay.
//
// Pipeline: capture -> transcribe -> intent (rules, custom commands, then
// coding agent) -> execute (Omarchy command, plugin IPC, or agent launch).
// Destructive actions (shutdown, reboot, logout by default) always require
// confirmation first.

Item {
  id: root

  // Set by Omarchy.
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  // Prefer the shell-provided install location; fall back to the standard path.
  readonly property string pluginDir:
    manifest && manifest.__sourceDir
      ? String(manifest.__sourceDir)
      : home + "/.config/omarchy/plugins/genesis"
  // Must match CAPTURE_WAV in bin/lib.sh (the capture script writes here).
  readonly property string runtimeDir:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/" + Quickshell.env("UID")) + "/genesis"
  readonly property string wavPath: runtimeDir + "/recording.wav"
  // Must match WAKE_WORD_VENV in bin/lib.sh (the wake-word scripts live here).
  readonly property string wakeWordVenv:
    (Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")) + "/genesis/wake-word-venv"

  // True once the wake word has been set up (its venv exists), so the listening
  // overlay can skip the setup hint for people who already have it.
  property bool wakeWordInstalled: false

  // True when the voxtype dictation engine is on PATH, so click-to-talk can
  // explain why voice input is unavailable instead of recording then failing.
  property bool voxtypeInstalled: true

  FileView {
    path: root.wakeWordVenv + "/pyvenv.cfg"
    printErrors: false
    onLoaded: root.wakeWordInstalled = true
    onLoadFailed: root.wakeWordInstalled = false
  }

  Process {
    id: voxtypeCheck
    command: ["sh", "-c", "command -v voxtype >/dev/null 2>&1"]
    onExited: function(exitCode) { root.voxtypeInstalled = exitCode === 0 }
  }
  Component.onCompleted: voxtypeCheck.running = true

  function bin(name) { return pluginDir + "/bin/" + name }

  // ------------------------------------------------------------- state

  // idle | listening | thinking | confirm | result
  property string phase: "idle"
  property string statusText: ""
  // Live peak amplitude (0.0–1.0) of the mic while listening, driving the
  // level meter so the user can see that audio is actually being captured.
  property real level: 0
  // Set when the user cancels a "thinking" session; the in-flight pipeline
  // handlers check it and drop their result instead of acting on it.
  property bool cancelled: false
  // The transcript of what was heard, shown so the user can confirm the input
  // was recognized before the action runs.
  property string heardText: ""
  // Confirmation prompt that includes the heard text, so destructive actions
  // still show the user what was recognized.
  readonly property string confirmMessage:
    (heardText !== "" ? "“" + heardText + "” — " : "")
    + (pendingLabel ? pendingLabel : "Confirm") + "?"
  property string pendingAction: ""
  property string pendingLabel: ""
  property var pendingArgs: ({})

  // True while a confirm-phase recording is in flight, so the transcript is
  // interpreted as a yes/no answer rather than a fresh command.
  property bool confirmListening: false

  // Safety cap on a single listening session (seconds). A tap-to-talk session
  // ends automatically here if the user does not stop it first.
  readonly property int maxListenSeconds: 10

  // Sample the recording peak while listening; reset when the phase changes.
  onPhaseChanged: {
    if (phase === "listening") { level = 0; peakTimer.restart() }
    else { peakTimer.stop(); level = 0 }
  }

  // ------------------------------------------------------------- pipeline

  function begin() {
    cancelled = false
    if (!voxtypeInstalled) {
      phase = "result"
      statusText = "Voxtype not installed — run `omarchy voxtype install` (or Install → AI → Dictation) to use voice input"
      resultTimer.restart()
      return
    }
    confirmListening = false
    Quickshell.execDetached([bin("capture"), "start"])
    Quickshell.execDetached([bin("beep"), "start"])
    phase = "listening"
    statusText = "Listening…"
    listenTimer.restart()
  }

  function end() {
    if (phase !== "listening") return
    listenTimer.stop()
    Quickshell.execDetached([bin("beep"), "stop"])
    phase = "thinking"
    statusText = "Thinking…"
    captureStopProcess.command = [bin("capture"), "stop"]
    captureStopProcess.running = true
  }

  function toggle() {
    if (phase === "listening") end()
    else if (phase === "thinking") cancel()
    else if (phase === "confirm") confirmNo()
    else begin()
  }

  function cancel() {
    if (phase === "listening") {
      listenTimer.stop()
      Quickshell.execDetached([bin("beep"), "stop"])
      Quickshell.execDetached([bin("capture"), "stop"])
      resetIdle()
    } else if (phase === "thinking") {
      cancelled = true
      resetIdle()
    }
  }

  function submitText(text) {
    var s = String(text || "").trim()
    if (!s) return
    cancelled = false
    confirmListening = false
    phase = "thinking"
    statusText = "Thinking…"
    intentProcess.command = [bin("intent"), s]
    intentProcess.running = true
  }

  function stopConfirmListen() {
    captureStopProcess.command = [bin("capture"), "stop"]
    captureStopProcess.running = true
  }

  function onTranscribed(text) {
    if (cancelled) return
    var s = String(text || "").trim()
    if (confirmListening) {
      confirmListening = false
      interpretConfirm(s)
      return
    }
    heardText = s
    // An empty result is handled in transcribeProcess.onExited (which also
    // distinguishes a real failure from a silent recording).
    if (!s) return
    intentProcess.command = [bin("intent"), s]
    intentProcess.running = true
  }

  function onIntent(json) {
    if (cancelled) return
    var parsed
    try { parsed = JSON.parse(String(json || "")) } catch (e) { resetIdle(); return }
    var action = String(parsed.action || "unknown")
    if (action === "unknown") {
      phase = "result"
      statusText = String(parsed.label || "I didn't understand that")
      resultTimer.restart()
      return
    }
    pendingAction = action
    pendingLabel = String(parsed.label || action)
    pendingArgs = parsed.args || {}
    if (parsed.needsConfirm === true) {
      phase = "confirm"
      confirmListening = true
      Quickshell.execDetached([bin("capture"), "start"])
      confirmTimer.restart()
    } else {
      runAction()
    }
  }

  function runAction() {
    var payload = JSON.stringify({ action: pendingAction, args: pendingArgs })
    phase = "result"
    statusText = pendingLabel
    Quickshell.execDetached([bin("execute"), payload])
    resultTimer.restart()
  }

  function interpretConfirm(text) {
    var t = String(text || "").toLowerCase()
    if (/^(yes|yeah|yep|confirm|ok|okay|do it|sure|go ahead)$/.test(t)) {
      runAction()
    } else {
      resetIdle()
    }
  }

  function confirmYes() {
    confirmTimer.stop()
    confirmListening = false
    Quickshell.execDetached([bin("capture"), "stop"])
    runAction()
  }

  function confirmNo() {
    confirmTimer.stop()
    confirmListening = false
    Quickshell.execDetached([bin("capture"), "stop"])
    resetIdle()
  }

  function resetIdle() {
    listenTimer.stop()
    confirmTimer.stop()
    phase = "idle"
    statusText = ""
    heardText = ""
    confirmListening = false
  }

  // Show a pipeline failure in the overlay instead of silently resetting.
  function showError(message) {
    var msg = String(message || "").trim()
    phase = "result"
    statusText = msg !== "" ? ("Error: " + msg) : "Something went wrong"
    resultTimer.restart()
  }

  // Transcription succeeded but produced no text (silence, or the user said
  // nothing audible).
  function showEmpty() {
    phase = "result"
    statusText = "Didn't catch that"
    resultTimer.restart()
  }

  // ------------------------------------------------------------- processes

  Process {
    id: captureStopProcess
    onExited: {
      // capture stop already flushed the WAV; kick off transcription.
      transcribeProcess.command = [root.bin("transcribe"), root.wavPath]
      transcribeProcess.running = true
    }
  }

  Process {
    id: transcribeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onTranscribed(text)
    }
    stderr: StdioCollector {
      id: transcribeError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (root.cancelled) return
      if (exitCode !== 0) {
        var err = String(transcribeError.text || "").trim()
        root.showError(err !== "" ? err : "transcription failed")
      } else if (root.heardText === "" && root.phase === "thinking") {
        root.showEmpty()
      }
    }
  }

  Process {
    id: intentProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onIntent(text)
    }
    stderr: StdioCollector {
      id: intentError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (root.cancelled) return
      if (exitCode === 0) return
      var err = String(intentError.text || "").trim()
      if (err !== "") root.showError(err)
    }
  }

  Timer {
    id: listenTimer
    interval: root.maxListenSeconds * 1000
    repeat: false
    onTriggered: root.end()
  }

  Timer {
    id: confirmTimer
    interval: 6000
    repeat: false
    onTriggered: root.stopConfirmListen()
  }

  Timer {
    id: resultTimer
    interval: 3000
    repeat: false
    onTriggered: root.resetIdle()
  }

  Timer {
    id: peakTimer
    interval: 150
    repeat: true
    onTriggered: peakProcess.running = true
  }

  Process {
    id: peakProcess
    command: [root.bin("peak"), root.wavPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = parseFloat(text)
        root.level = isNaN(v) ? 0 : v
      }
    }
  }

  // ------------------------------------------------------------- IPC

  IpcHandler {
    target: "genesis"

    function begin(): string { root.begin(); return "ok" }
    function end(): string { root.end(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function text(s: string): string { root.submitText(s); return "ok" }
    function state(): string { return root.phase }
  }

  // ------------------------------------------------------------- overlay

  PanelWindow {
    visible: root.phase !== "idle"
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "genesis"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Click-through except over the interactive content, so the full-screen
    // overlay never blocks the menu/bar/desktop below it. The confirm dialog
    // (full-screen scrim) is the one phase that must swallow clicks itself.
    mask: Region { item: root.phase === "confirm" ? confirmDialog : statusPill }

    // ConfirmDialog provides its own scrim and click-outside-to-cancel.

    ConfirmDialog {
      id: confirmDialog
      anchors.fill: parent
      opened: root.phase === "confirm"
      message: root.confirmMessage
      confirmText: "Confirm"
      cancelText: "Cancel"
      onConfirmed: root.confirmYes()
      onCanceled: root.confirmNo()
    }

    // Status pill: bottom-center.
    BorderSurface {
      id: statusPill
      readonly property bool active: root.phase === "listening"
        || root.phase === "thinking"
        || root.phase === "result"

      visible: active
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(48)
      width: pillContent.implicitWidth + Style.spacing.panelPadding * 2
      height: pillContent.implicitHeight + Style.spacing.panelPadding * 2
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Math.max(Style.cornerRadius, Style.space(18))

      Column {
        id: pillContent
        anchors.centerIn: parent
        spacing: Style.spacing.sm

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.md

          Text {
            text: root.phase === "thinking" ? "✨" : (root.phase === "result" ? "󰄬" : "󰍬")
            color: root.phase === "result" ? Color.accent : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            scale: root.phase === "listening" ? 1.15 : 1

            SequentialAnimation on scale {
              running: root.phase === "listening"
              loops: Animation.Infinite
              NumberAnimation { to: 1.0; duration: 450; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.18; duration: 450; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            text: root.statusText
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }
        }

        Row {
          id: levelMeter
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.phase === "listening"
          spacing: 2
          Repeater {
            model: 12
            Rectangle {
              width: 6
              height: 8
              radius: 1
              color: index < Math.sqrt(root.level) * 12
                ? Color.accent
                : Util.alpha(Color.popups.text, 0.18)
            }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.phase === "listening" || root.phase === "thinking"
          text: "✕ Cancel"
          color: cancelHover.containsMouse ? Color.popups.text : Util.alpha(Color.popups.text, 0.62)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          MouseArea {
            id: cancelHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.cancel()
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.heardText !== ""
          text: "“" + root.heardText + "”"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.phase === "listening" && !root.wakeWordInstalled
          text: "A wake word (e.g. \"hey jarvis\") starts listening hands-free — run bin/wake-word-setup"
          color: Util.alpha(Color.popups.text, 0.62)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
