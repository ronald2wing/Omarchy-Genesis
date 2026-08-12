import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Genesis bar widget: a microphone button whose popup menu expands under the
// icon (a bar-widget panel, like the audio/bluetooth/power panels).
//   left-click  — toggle listening (tap to talk)
//   right-click — toggle the popup menu
//
// The button only sends IPC to the always-running Genesis service; it holds no
// pipeline state of its own beyond an optimistic "active" glow that clears
// after the service's listening cap.

Panel {
  id: root
  moduleName: "genesis"
  // The service (Service.qml) owns the "genesis" IPC target; this widget must
  // not register a second handler under the same id.
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  // The plugin id "genesis" is hardcoded (matching lib.sh and Service.qml's
  // fallback) — the installed plugin lives at ~/.config/omarchy/plugins/genesis.
  readonly property string pluginDir: home + "/.config/omarchy/plugins/genesis"
  readonly property string binDir: pluginDir + "/bin"
  // Config lives outside the plugin dir (see lib.sh): writing inside the plugin
  // dir trips the shell's hot-reload watcher and closes this popup.
  readonly property string configPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/genesis/config.json"
  readonly property string logPath:
    (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/genesis/log.json"

  property bool active: false
  property string mode: "menu"
  property string askContext: "commands"
  property bool askEditing: false
  property bool askFromForm: false

  property var commandsData: []
  property var routinesData: []
  property var logData: []
  property bool agentEnabled: false

  // Command/routine editor state (empty key = adding a new entry).
  property string editingCommand: ""
  property string cfName: ""
  property string cfPhrase: ""
  property bool cfIsIpc: true
  property string cfTarget: ""
  property string cfMethod: ""
  property string cfScript: ""
  property string cfLang: "bash"
  property string editingRoutine: ""
  property string rfName: ""
  property string rfSchedule: ""
  property string rfCommand: ""
  property string rfLang: "bash"

  // Static menu entries for the root menu.
  property var menuItems: [
    { "label": "Type a command…", "action": "type", "icon": "󰍬", "sub": false },
    { "label": "Manage commands & routines", "action": "manage", "icon": "󰣏", "sub": true }
  ]

  // Manage-submenu entries; label is derived (agent state / list counts).
  property var manageItems: [
    { "action": "agent", "icon": "✨" },
    { "action": "commands", "icon": "⌘" },
    { "action": "routines", "icon": "⏰" },
    { "action": "history", "icon": "🕘" },
    { "action": "export", "icon": "📤" },
    { "action": "import", "icon": "📥" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { mode = "menu"; refresh() }

  Timer {
    id: activeReset
    interval: 10000
    repeat: false
    onTriggered: root.active = false
  }

  function toggleListening() {
    active = !active
    activeReset.restart()
    if (bar) bar.run("omarchy-shell -q genesis toggle")
  }

  function back() {
    if (mode === "type" || mode === "manage") mode = "menu"
    else if (mode === "command-form") mode = "commands"
    else if (mode === "routine-form") mode = "routines"
    else if (mode === "ask") mode = askFromForm ? (askContext === "routines" ? "routine-form" : "command-form") : askContext
    else mode = "manage"
  }
  function refresh() { configView.reload(); logView.reload() }

  function parseConfig(raw) {
    var d = {}
    try { d = JSON.parse(String(raw || "{}")) } catch (e) {}
    var cmds = []
    var cs = d.commands || {}
    for (var k in cs) cmds.push({ id: k, phrase: cs[k].phrase, spec: cs[k] })
    commandsData = cmds
    var routs = []
    var rs = d.routines || {}
    for (var k in rs) routs.push({ id: k, schedule: rs[k].schedule, spec: rs[k] })
    routinesData = routs
    agentEnabled = (d.agent && d.agent.enabled) === true
  }
  function parseLog(raw) {
    var a = []
    try { a = JSON.parse(String(raw || "[]")) } catch (e) {}
    logData = Array.isArray(a) ? a.slice().reverse() : []
  }

  function runCli(args) {
    Quickshell.execDetached([binDir + "/" + args[0]].concat(args.slice(1)))
    refreshTimer.restart()
  }
  function submitCommand() {
    var t = String(commandInput.text || "").trim()
    if (t.length === 0) { back(); return }
    Quickshell.execDetached(["omarchy-shell", "-q", "genesis", "text", t])
    root.close()
  }
  function voiceCommand() { toggleListening() }
  function toggleAgent() { runCli(["agent", "toggle"]) }
  function clearHistory() { runCli(["log", "clear"]) }
  function clearHistoryFor(key) { runCli(["log", "clear", key]) }
  function manageLabel(action) {
    if (action === "agent") return agentEnabled ? "Agent (AI): on" : "Agent (AI): off"
    if (action === "commands") return "Commands (" + commandsData.length + ")"
    if (action === "routines") return "Routines (" + routinesData.length + ")"
    if (action === "history") return "History"
    if (action === "export") return "Export config"
    return "Import config"
  }
  function manageAction(action) {
    if (action === "agent") { toggleAgent(); return }
    if (action === "export") { exportConfig(); return }
    mode = action
  }
  function exportConfig() { runCli(["config-export"]); root.close() }
  function importConfig() {
    var t = String(importInput.text || "").trim()
    if (t.length > 0) runCli(["config-import", t])
    root.close()
  }
  function importPreview() {
    var t = String(importInput.text || "").trim()
    if (t.length === 0) return ""
    var d = {}
    try { d = JSON.parse(t) } catch (e) { return "Invalid JSON" }
    var cmds = d.commands || {}
    var routs = d.routines || {}
    var ncmd = 0, nrout = 0
    for (var k in cmds) ncmd++
    for (var k in routs) nrout++
    if (ncmd === 0 && nrout === 0) return "Nothing to import"
    var lines = ["Will import " + ncmd + " command(s) and " + nrout + " routine(s):"]
  if (nrout > 0) {
    lines.push("Routines (installed as systemd timers):")
    for (var k in routs) {
      var spec = routs[k] || {}
      lines.push("  " + String(spec.schedule || "") + " → " + String(spec.run || "").slice(0, 50))
    }
  }
    return lines.join("\n")
  }
  function commandSummary(e) {
    var s = e.spec || {}
    if (s.target && s.method) return "→ " + s.target + " " + s.method
    return "run (" + (s.lang || "bash") + ")"
  }
  function commandLabel(e) { return (e.spec && e.spec.name) || e.phrase }
  function routineLabel(e) { return (e.spec && e.spec.name) || e.schedule }
  function routineSummary(e) {
    var s = e.spec || {}
    var c = String(s.run || "")
    return "run (" + (s.lang || "bash") + ")" + (c ? "  " + c : "")
  }
  function timeAgo(at) {
    var t = Date.parse(at)
    if (isNaN(t)) return ""
    var s = Math.floor((Date.now() - t) / 1000)
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }
  function fmtTime(at) {
    var m = String(at || "").match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/)
    if (!m) return String(at || "")
    return m[2] + "-" + m[3] + " " + m[4] + ":" + m[5]
  }
  function runsFor(key) {
    var runs = []
    for (var i = 0; i < logData.length; i++) {
      var d = String(logData[i].detail || "")
      var ok = null
      if (d === "ok: " + key) ok = true
      else if (d === "failed: " + key) ok = false
      else if (d === "run now: " + key) ok = null
      else continue
      runs.push({ at: String(logData[i].at || ""), ok: ok })
    }
    return runs
  }
  function lastRun(key) {
    var runs = runsFor(key)
    return runs.length > 0 ? runs[0] : null
  }
  function runHistory(key) {
    var runs = runsFor(key)
    if (runs.length === 0) return ""
    var ok = 0, fail = 0, manual = 0
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].ok === true) ok++
      else if (runs[i].ok === false) fail++
      else manual++
    }
    var lines = ["Ran " + runs.length + " time(s) — " + ok + " ok, " + fail + " failed" + (manual > 0 ? ", " + manual + " manual" : "")]
    var shown = runs.slice(0, 8)
    for (var j = 0; j < shown.length; j++) {
      var r = shown[j]
      lines.push((r.ok === true ? "✅" : r.ok === false ? "❌" : "▶") + "  " + fmtTime(r.at))
    }
    return lines.join("\n")
  }
  function lastRunMarker(key) {
    var r = lastRun(key)
    if (r === null) return ""
    if (r.ok === true) return "✅ " + timeAgo(r.at)
    if (r.ok === false) return "❌ " + timeAgo(r.at)
    return "▶ " + timeAgo(r.at)
  }
  function specFor(list, key) {
    for (var i = 0; i < list.length; i++) if (list[i].phrase === key || list[i].schedule === key) return list[i]
    return null
  }
  function openCommandForm(phrase) {
    editingCommand = phrase || ""
    var e = phrase ? specFor(commandsData, phrase) : null
    var s = (e && e.spec) || {}
    cfPhrase = phrase || ""
    cfName = s.name || ""
    if (s.run) { cfIsIpc = false; cfScript = s.run; cfLang = s.lang || "bash"; cfTarget = ""; cfMethod = "" }
    else { cfIsIpc = true; cfTarget = s.target || ""; cfMethod = s.method || ""; cfScript = "" }
    mode = "command-form"
  }
  function saveCommand() {
    var p = String(cfPhrase || "").trim()
    if (p === "") return
    var name = String(cfName || "").trim()
    if (cfIsIpc) {
      var t = String(cfTarget || "").trim(), m = String(cfMethod || "").trim()
      if (t === "" || m === "") return
      var a = ["commands", "set"]
      if (name !== "") a.push("--name", name)
      runCli(a.concat([p, t, m]))
    } else {
      var c = String(cfScript || "").trim()
      if (c === "") return
      var b = ["commands", "run"]
      if (name !== "") b.push("--name", name)
      if (cfLang !== "bash") b.push("--lang", cfLang)
      runCli(b.concat([p, c]))
    }
    if (editingCommand !== "" && editingCommand !== p) runCli(["commands", "remove", editingCommand])
    mode = "commands"
  }
  function removeCommand(phrase) { runCli(["commands", "remove", phrase]); mode = "commands" }
  function openRoutineForm(schedule) {
    editingRoutine = schedule || ""
    var e = schedule ? specFor(routinesData, schedule) : null
    var s = (e && e.spec) || {}
    rfSchedule = schedule || ""
    rfName = s.name || ""
    rfCommand = s.run || ""
    rfLang = s.lang || "bash"
    mode = "routine-form"
  }
  function saveRoutine() {
    var s = String(rfSchedule || "").trim(), c = String(rfCommand || "").trim()
    if (s === "" || c === "") return
    var name = String(rfName || "").trim()
    var a = ["routines", "set"]
    if (name !== "") a.push("--name", name)
    if (rfLang !== "bash") a.push("--lang", rfLang)
    runCli(a.concat([s, c]))
    if (editingRoutine !== "" && editingRoutine !== s) runCli(["routines", "remove", editingRoutine])
    mode = "routines"
  }
  function removeRoutine(schedule) { runCli(["routines", "remove", schedule]); mode = "routines" }
  function runCommandNow(phrase) {
    Quickshell.execDetached(["omarchy-shell", "-q", "genesis", "text", phrase])
  }
  function runRoutineNow(schedule) {
    runCli(["routines", "run", schedule])
  }
  function openAsk(context) {
    askContext = context
    askEditing = false
    askFromForm = false
    mode = "ask"
  }
  function openAddAsk(context) {
    askContext = context
    askEditing = false
    askFromForm = true
    mode = "ask"
  }
  function openEditAsk(context) {
    askContext = context
    askEditing = true
    askFromForm = true
    mode = "ask"
  }
  function submitAsk() {
    var t = String(askInput.text || "").trim()
    if (t.length === 0) { back(); return }
    // @command/@routine → always register a new entry; @updatecommand/
    // @updateroutine → update only the specific entry named before " :: ".
    var prefix
    if (askEditing) {
      var identity = askContext === "routines" ? editingRoutine : editingCommand
      prefix = (askContext === "routines" ? "@updateroutine " : "@updatecommand ") + identity + " :: "
    } else {
      prefix = askContext === "routines" ? "@routine " : "@command "
    }
    Quickshell.execDetached(["omarchy-shell", "-q", "genesis", "text", prefix + t])
    root.close()
  }
  function titleText() {
    if (mode === "type") return "Type a command"
    if (mode === "manage") return "Manage"
    if (mode === "commands") return "Commands"
    if (mode === "command-form") return editingCommand === "" ? "Add command" : "Edit command"
    if (mode === "routines") return "Routines"
    if (mode === "routine-form") return editingRoutine === "" ? "Add routine" : "Edit routine"
    if (mode === "ask") return "Ask AI"
    if (mode === "history") return "History"
    if (mode === "import") return "Import config"
    return "Genesis"
  }

  FileView {
    id: configView
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseConfig(text())
    onLoadFailed: { root.commandsData = []; root.routinesData = [] }
  }
  FileView {
    id: logView
    path: root.logPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseLog(text())
    onLoadFailed: root.logData = []
  }
  Timer {
    id: refreshTimer
    interval: 350
    repeat: false
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍬"
    active: root.active
    tooltipText: "Genesis — click to talk, right-click for menu"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggle()
      else root.toggleListening()
    }
  }

  // --- reusable popup pieces ---------------------------------------------

  // Left-aligned accent row (Add / Ask).
  component RowBtn: Rectangle {
    property string label
    signal clicked()
    width: parent.width
    height: 32
    radius: 6
    color: hover.containsMouse ? Color.menu.selectedBackground : "transparent"
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: 10
      text: label
      color: Color.menu.selectedText
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  // Centered button (Save / Send / Remove / Back).
  component Btn: Rectangle {
    property string label
    property bool filled: false
    signal clicked()
    width: parent.width
    height: 32
    radius: 6
    color: filled ? Style.selectedAccentFill : (hover.containsMouse ? Color.menu.selectedBackground : "transparent")
    Text {
      anchors.centerIn: parent
      text: label
      color: filled ? Color.menu.selectedText : Color.menu.text
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  // Labeled single-line input.
  component Input: Column {
    id: self
    property string label
    property string placeholder: ""
    property alias text: field.text
    signal edited(string value)
    width: parent.width
    spacing: Style.spacing.md
    Text {
      width: parent.width
      text: label
      color: Util.alpha(Color.menu.text, 0.6)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      width: parent.width
      height: 30
      radius: 6
      color: Util.alpha(Color.menu.text, 0.06)
      border.color: field.activeFocus ? Color.accent : Color.menu.border
      border.width: 1
      TextInput {
        id: field
        anchors.fill: parent
        anchors.margins: 6
        verticalAlignment: TextInput.AlignVCenter
        color: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        onTextEdited: self.edited(text)
      }
      Text {
        visible: field.text === "" && self.placeholder !== "" && !field.activeFocus
        anchors.fill: parent
        anchors.margins: 6
        verticalAlignment: Text.AlignVCenter
        text: self.placeholder
        color: Util.alpha(Color.menu.text, 0.4)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // Labeled multi-line text area.
  component TextArea: Column {
    id: self
    property string label
    property string placeholder: ""
    property alias text: area.text
    signal edited(string value)
    width: parent.width
    spacing: Style.spacing.md
    Text {
      width: parent.width
      text: label
      color: Util.alpha(Color.menu.text, 0.6)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      width: parent.width
      height: 72
      radius: 6
      color: Util.alpha(Color.menu.text, 0.06)
      border.color: area.activeFocus ? Color.accent : Color.menu.border
      border.width: 1
      TextEdit {
        id: area
        anchors.fill: parent
        anchors.margins: 6
        color: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        wrapMode: TextEdit.WrapAnywhere
        clip: true
        onTextEdited: self.edited(text)
      }
      Text {
        visible: area.text === "" && self.placeholder !== "" && !area.activeFocus
        anchors.fill: parent
        anchors.margins: 6
        text: self.placeholder
        color: Util.alpha(Color.menu.text, 0.4)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }
    }
  }

  // Menu item row (icon + label + chevron), used by the root menu and Manage.
  component MenuRow: Rectangle {
    id: row
    property string label
    property string icon
    property bool chevron
    signal clicked()
    width: parent.width
    height: 36
    radius: 6
    color: hover.containsMouse ? Color.menu.selectedBackground : "transparent"
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: 12
      width: 20
      text: row.icon
      color: Color.menu.selectedText
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: 42
      anchors.right: parent.right
      anchors.rightMargin: row.chevron ? 32 : 14
      text: row.label
      color: Color.menu.text
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      visible: row.chevron
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: 12
      width: 16
      text: "›"
      color: Util.alpha(Color.menu.text, 0.5)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }
    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  // Small ▶ run-now button on the right of a list row.
  component RunBtn: Rectangle {
    signal clicked()
    width: 22
    height: 22
    radius: 6
    color: hover.containsMouse ? Color.menu.selectedBackground : Util.alpha(Color.menu.text, 0.08)
    Text {
      anchors.centerIn: parent
      text: "▶"
      color: Color.menu.text
      font.family: Style.font.menuFamily
      font.pixelSize: 11
    }
    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  // List row (title + summary + last-run marker + run button).
  component ListRow: Rectangle {
    id: row
    property string label
    property string summary
    property string marker
    signal clicked()
    signal runClicked()
    width: parent.width
    height: 46
    radius: 6
    color: rowHover.containsMouse ? Color.menu.selectedBackground : "transparent"
    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
    Column {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: 12
      anchors.right: parent.right
      anchors.rightMargin: 34
      spacing: Style.spacing.hairline
      Text {
        width: parent.width
        text: row.label
        color: Color.menu.text
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: row.summary
        color: Util.alpha(Color.menu.text, 0.55)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: 32
      text: row.marker
      color: Util.alpha(Color.menu.text, 0.55)
      font.family: Style.font.menuFamily
      font.pixelSize: 10
    }
    RunBtn {
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: 6
      onClicked: row.runClicked()
    }
  }

  // Labeled segmented control (IPC/Script toggle, language picker).
  component Segmented: Column {
    id: seg
    property string label
    property var options: []
    property string value: ""
    property real cellWidth: 58
    signal picked(string v)
    width: parent.width
    spacing: Style.spacing.md
    Text {
      width: parent.width
      text: seg.label
      color: Util.alpha(Color.menu.text, 0.6)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }
    Row {
      spacing: Style.spacing.sm
      Repeater {
        model: seg.options
        delegate: Rectangle {
          width: seg.cellWidth
          height: 26
          radius: 6
          color: seg.value === modelData ? Color.menu.selectedBackground : Util.alpha(Color.menu.text, 0.06)
          Text {
            anchors.centerIn: parent
            text: modelData
            color: seg.value === modelData ? Color.menu.selectedText : Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.picked(modelData)
          }
        }
      }
    }
  }

  // Centered empty-state hint (icon + title + subtitle).
  component EmptyState: Column {
    property string icon
    property string title
    property string hint
    width: parent.width
    spacing: Style.spacing.xxs
    topPadding: Style.space(20)
    bottomPadding: Style.space(20)
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: icon
      color: Util.alpha(Color.menu.text, 0.35)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.iconLarge
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: title
      color: Util.alpha(Color.menu.text, 0.6)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: hint
      color: Util.alpha(Color.menu.text, 0.4)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      anchors.fill: parent
      spacing: Style.spacing.md

      // Header
      Row {
        width: parent.width
        height: 32
        spacing: Style.spacing.lg

        Rectangle {
          visible: root.mode !== "menu"
          width: 26
          height: 26
          radius: 6
          anchors.verticalCenter: parent.verticalCenter
          color: backHover.containsMouse ? Util.alpha(Color.menu.text, 0.08) : "transparent"
          Text {
            anchors.centerIn: parent
            text: "󰁍"
            color: Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }
          MouseArea {
            id: backHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.back()
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.titleText()
          color: root.mode === "menu" ? Color.menu.selectedText : Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
        }
      }

      // Divider
      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Color.menu.text, 0.12)
      }

      // -------- menu --------
      Repeater {
        model: root.menuItems
        delegate: MenuRow {
          visible: root.mode === "menu"
          label: modelData.label
          icon: modelData.icon
          chevron: modelData.sub
          onClicked: root.mode = modelData.action
        }
      }

      // -------- type --------
      Rectangle {
        visible: root.mode === "type"
        width: parent.width
        height: 72
        radius: 6
        color: Util.alpha(Color.menu.text, 0.06)
        border.color: commandInput.activeFocus ? Color.accent : Color.menu.border
        border.width: 1
        onVisibleChanged: if (visible) commandInput.forceActiveFocus()
        TextEdit {
          id: commandInput
          anchors.fill: parent
          anchors.margins: 8
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.WrapAnywhere
          clip: true
          Keys.onEscapePressed: root.back()
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) root.submitCommand()
          }
        }
      }
      Row {
        visible: root.mode === "type"
        width: parent.width
        spacing: Style.spacing.lg
        Btn {
          width: (parent.width - parent.spacing) / 2
          label: "🎤 Voice"
          onClicked: root.voiceCommand()
        }
        Btn {
          width: (parent.width - parent.spacing) / 2
          label: "Send"
          filled: true
          onClicked: root.submitCommand()
        }
      }

      // -------- manage --------
      Repeater {
        model: root.manageItems
        delegate: MenuRow {
          visible: root.mode === "manage"
          label: root.manageLabel(modelData.action)
          icon: modelData.icon
          chevron: modelData.action !== "agent"
          onClicked: root.manageAction(modelData.action)
        }
      }

      // -------- commands list --------
      Text {
        visible: root.mode === "commands" && root.commandsData.length > 0
        width: parent.width
        text: root.commandsData.length === 1 ? "1 command" : root.commandsData.length + " commands"
        color: Util.alpha(Color.menu.text, 0.5)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }
      Flickable {
        visible: root.mode === "commands"
        width: parent.width
        height: Math.min(cmdColumn.implicitHeight, 220)
        contentHeight: cmdColumn.implicitHeight
        clip: true
        Column {
          id: cmdColumn
          width: parent.width
          spacing: Style.spacing.xxs
          Repeater {
            model: root.commandsData
            delegate: ListRow {
              label: root.commandLabel(modelData)
              summary: root.commandSummary(modelData)
              marker: root.lastRunMarker(modelData.phrase)
              onClicked: root.openCommandForm(modelData.phrase)
              onRunClicked: root.runCommandNow(modelData.phrase)
            }
          }
        }
      }
      RowBtn {
        visible: root.mode === "commands"
        label: "＋ Add command"
        onClicked: root.openCommandForm("")
      }
      RowBtn {
        visible: root.mode === "commands"
        label: "✨ Ask AI to change commands"
        onClicked: root.openAsk("commands")
      }
      EmptyState {
        visible: root.mode === "commands" && root.commandsData.length === 0
        icon: "⌘"
        title: "No commands yet"
        hint: "Add one above, or ask the AI to make one"
      }

      // -------- command form --------
      Column {
        visible: root.mode === "command-form"
        width: parent.width
        spacing: Style.spacing.md
        Input {
          label: "Name (optional)"
          text: root.cfName
          onEdited: function(v) { root.cfName = v }
        }
        Input {
          label: "Phrase"
          placeholder: "e.g. turn off the lights"
          text: root.cfPhrase
          onEdited: function(v) { root.cfPhrase = v }
        }
        Segmented {
          label: "Type"
          options: ["IPC", "Script"]
          value: root.cfIsIpc ? "IPC" : "Script"
          cellWidth: 58
          onPicked: function(v) { root.cfIsIpc = (v === "IPC") }
        }
        Column {
          visible: root.cfIsIpc
          width: parent.width
          spacing: Style.spacing.md
          Input {
            label: "IPC target"
            placeholder: "e.g. notifications"
            text: root.cfTarget
            onEdited: function(v) { root.cfTarget = v }
          }
          Input {
            label: "Method"
            placeholder: "e.g. toggleDnd"
            text: root.cfMethod
            onEdited: function(v) { root.cfMethod = v }
          }
        }
        Column {
          visible: !root.cfIsIpc
          width: parent.width
          spacing: Style.spacing.md
          TextArea {
            label: "Command"
            placeholder: "the command or script to run"
            text: root.cfScript
            onEdited: function(v) { root.cfScript = v }
          }
          Segmented {
            label: "Language"
            options: ["bash", "python", "node", "ruby"]
            value: root.cfLang
            cellWidth: 56
            onPicked: function(v) { root.cfLang = v }
          }
        }
        Btn {
          label: "Save"
          filled: true
          onClicked: root.saveCommand()
        }
        Btn {
          visible: root.editingCommand === ""
          label: "✨ Ask AI to add"
          onClicked: root.openAddAsk("commands")
        }
        Btn {
          visible: root.editingCommand !== ""
          label: "Remove"
          onClicked: root.removeCommand(root.editingCommand)
        }
        Btn {
          visible: root.editingCommand !== ""
          label: "✨ Ask AI to update"
          onClicked: root.openEditAsk("commands")
        }
        Text {
          visible: root.editingCommand !== "" && root.runHistory(root.editingCommand) !== ""
          width: parent.width
          text: "History"
          color: Util.alpha(Color.menu.text, 0.6)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
        Flickable {
          visible: root.editingCommand !== "" && root.runHistory(root.editingCommand) !== ""
          width: parent.width
          height: Math.min(cmdHistText.implicitHeight, 120)
          contentHeight: cmdHistText.implicitHeight
          clip: true
          Text {
            id: cmdHistText
            width: parent.width
            text: root.runHistory(root.editingCommand)
            color: Util.alpha(Color.menu.text, 0.8)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
        RowBtn {
          visible: root.editingCommand !== "" && root.runHistory(root.editingCommand) !== ""
          label: "🗑 Clear history"
          onClicked: root.clearHistoryFor(root.editingCommand)
        }
      }

      // -------- routines list --------
      Text {
        visible: root.mode === "routines" && root.routinesData.length > 0
        width: parent.width
        text: root.routinesData.length === 1 ? "1 routine" : root.routinesData.length + " routines"
        color: Util.alpha(Color.menu.text, 0.5)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
      }
      Flickable {
        visible: root.mode === "routines"
        width: parent.width
        height: Math.min(routColumn.implicitHeight, 220)
        contentHeight: routColumn.implicitHeight
        clip: true
        Column {
          id: routColumn
          width: parent.width
          spacing: Style.spacing.xxs
          Repeater {
            model: root.routinesData
            delegate: ListRow {
              label: root.routineLabel(modelData)
              summary: root.routineSummary(modelData)
              marker: root.lastRunMarker(modelData.schedule)
              onClicked: root.openRoutineForm(modelData.schedule)
              onRunClicked: root.runRoutineNow(modelData.schedule)
            }
          }
        }
      }
      RowBtn {
        visible: root.mode === "routines"
        label: "＋ Add routine"
        onClicked: root.openRoutineForm("")
      }
      RowBtn {
        visible: root.mode === "routines"
        label: "✨ Ask AI to change routines"
        onClicked: root.openAsk("routines")
      }
      EmptyState {
        visible: root.mode === "routines" && root.routinesData.length === 0
        icon: "⏰"
        title: "No routines yet"
        hint: "Add one above, or ask the AI to make one"
      }

      // -------- routine form --------
      Column {
        visible: root.mode === "routine-form"
        width: parent.width
        spacing: Style.spacing.md
        Input {
          label: "Name (optional)"
          text: root.rfName
          onEdited: function(v) { root.rfName = v }
        }
        Input {
          label: "Schedule (08:00, Mon-Fri 18:00, …)"
          text: root.rfSchedule
          onEdited: function(v) { root.rfSchedule = v }
        }
        TextArea {
          label: "Command"
          placeholder: "the command to run"
          text: root.rfCommand
          onEdited: function(v) { root.rfCommand = v }
        }
        Segmented {
          label: "Language"
          options: ["bash", "python", "node", "ruby"]
          value: root.rfLang
          cellWidth: 56
          onPicked: function(v) { root.rfLang = v }
        }
        Btn {
          label: "Save"
          filled: true
          onClicked: root.saveRoutine()
        }
        Btn {
          visible: root.editingRoutine === ""
          label: "✨ Ask AI to add"
          onClicked: root.openAddAsk("routines")
        }
        Btn {
          visible: root.editingRoutine !== ""
          label: "Remove"
          onClicked: root.removeRoutine(root.editingRoutine)
        }
        Btn {
          visible: root.editingRoutine !== ""
          label: "✨ Ask AI to update"
          onClicked: root.openEditAsk("routines")
        }
        Text {
          visible: root.editingRoutine !== "" && root.runHistory(root.editingRoutine) !== ""
          width: parent.width
          text: "History"
          color: Util.alpha(Color.menu.text, 0.6)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }
        Flickable {
          visible: root.editingRoutine !== "" && root.runHistory(root.editingRoutine) !== ""
          width: parent.width
          height: Math.min(routHistText.implicitHeight, 120)
          contentHeight: routHistText.implicitHeight
          clip: true
          Text {
            id: routHistText
            width: parent.width
            text: root.runHistory(root.editingRoutine)
            color: Util.alpha(Color.menu.text, 0.8)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
        RowBtn {
          visible: root.editingRoutine !== "" && root.runHistory(root.editingRoutine) !== ""
          label: "🗑 Clear history"
          onClicked: root.clearHistoryFor(root.editingRoutine)
        }
      }

      // -------- ask AI --------
      Rectangle {
        visible: root.mode === "ask"
        width: parent.width
        height: 72
        radius: 6
        color: Util.alpha(Color.menu.text, 0.06)
        border.color: askInput.activeFocus ? Color.accent : Color.menu.border
        border.width: 1
        onVisibleChanged: if (visible) askInput.forceActiveFocus()
        TextEdit {
          id: askInput
          anchors.fill: parent
          anchors.margins: 8
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.WrapAnywhere
          clip: true
          Keys.onEscapePressed: root.back()
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) root.submitAsk()
          }
        }
      }
      Text {
        visible: root.mode === "ask"
        width: parent.width
        text: root.askEditing
          ? (root.askContext === "routines"
            ? "Describe the change to the \"" + root.editingRoutine + "\" routine — e.g. \"run it at 08:00 instead\" or \"change it to show the weather\". AI will update only that routine."
            : "Describe the change to the \"" + root.editingCommand + "\" command — e.g. \"launch kitty instead\" or \"add a --new flag\". AI will update only that command.")
          : (root.askContext === "routines"
            ? "Describe the routine you want — e.g. \"every day at 8am, tell me a joke\" or \"weekdays at 6pm, run backups\". AI will register it as a routine."
            : "Describe the command you want — e.g. \"toggle do not disturb\" or \"launch kitty\". AI will register it as a command.")
        color: Util.alpha(Color.menu.text, 0.6)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
      Row {
        visible: root.mode === "ask"
        width: parent.width
        spacing: Style.spacing.lg
        Btn {
          width: (parent.width - parent.spacing) / 2
          label: "🎤 Voice"
          onClicked: root.voiceCommand()
        }
        Btn {
          width: (parent.width - parent.spacing) / 2
          label: "Ask AI"
          filled: true
          onClicked: root.submitAsk()
        }
      }

      // -------- history --------
      Flickable {
        visible: root.mode === "history"
        width: parent.width
        height: Math.min(histText.implicitHeight, 220)
        contentHeight: histText.implicitHeight
        clip: true
        Text {
          id: histText
          width: parent.width
          text: root.logData.slice(0, 30).map(function (e) { return e.at + "  " + e.action + (e.detail ? " — " + e.detail : "") }).join("\n")
          color: Util.alpha(Color.menu.text, 0.8)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
      EmptyState {
        visible: root.mode === "history" && root.logData.length === 0
        icon: "🕘"
        title: "No history yet"
        hint: "Run a command or routine to see it here"
      }
      RowBtn {
        visible: root.mode === "history" && root.logData.length > 0
        label: "🗑 Clear history"
        onClicked: root.clearHistory()
      }

      // -------- import --------
      Rectangle {
        visible: root.mode === "import"
        width: parent.width
        height: 60
        radius: 6
        color: Util.alpha(Color.menu.text, 0.06)
        border.color: importInput.activeFocus ? Color.accent : Color.menu.border
        border.width: 1
        TextEdit {
          id: importInput
          anchors.fill: parent
          anchors.margins: 6
          color: Color.menu.text
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          wrapMode: TextEdit.WrapAnywhere
          clip: true
        }
        Text {
          visible: importInput.text === "" && !importInput.activeFocus
          anchors.fill: parent
          anchors.margins: 6
          text: "Paste commands & routines JSON…"
          color: Util.alpha(Color.menu.text, 0.4)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }
      }
      Text {
        visible: root.mode === "import"
        width: parent.width
        text: root.importPreview()
        color: Util.alpha(Color.menu.text, 0.7)
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // -------- import action --------
      Btn {
        visible: root.mode === "import"
        label: "Import"
        filled: true
        onClicked: root.importConfig()
      }
    }
  }
}
