import QtQuick
import Quickshell
import Quickshell.Io

// Lock state and the env/key index, backed by bin/secrets. The CLI owns all
// crypto and git; values only pass through here when revealed or edited,
// and passphrases/values always go over stdin, never argv.
Item {
  id: root

  // function(name, fallback) resolving a plugin setting, or null.
  property var settingFn: null

  readonly property int ttlMinutes: Math.max(0, Number(setting("ttlMinutes", 0)))
  readonly property string repoDir: String(setting("repoDir", "")).replace(/^~(?=\/|$)/, Quickshell.env("HOME"))

  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/secrets").toString().replace(/^file:\/\//, ""))

  property bool loaded: false
  property bool initialized: false
  property bool unlocked: false
  property string expires: ""
  property bool remote: false
  property int unpushed: 0
  property var entries: []

  property bool busy: false
  property string error: ""
  property string notice: ""

  signal unlockedNow()

  function setting(name, fallback) {
    var v = root.settingFn ? root.settingFn(name, fallback) : fallback
    return v === undefined || v === null || v === "" ? fallback : v
  }

  function cleanError(text) {
    var lines = String(text || "").trim().split("\n")
    return lines[lines.length - 1].replace(/^secrets: /, "") || "Something went wrong"
  }

  function say(message) {
    root.error = ""
    root.notice = message
    noticeTimer.restart()
  }

  function fail(stderr) {
    root.notice = ""
    root.error = cleanError(stderr)
  }

  function run(args, input, done) {
    var command = ["env", "SECRETS_TTL=" + (root.ttlMinutes * 60)]
    if (root.repoDir) command.push("SECRETS_DIR=" + root.repoDir)
    var proc = procComponent.createObject(root, {
      command: command.concat([root.cli]).concat(args),
      input: input === undefined || input === null ? "" : String(input),
      done: done || null
    })
    proc.running = true
  }

  // An action: busy while running, errors surface in the footer.
  function act(args, input, onSuccess) {
    root.busy = true
    root.error = ""
    run(args, input, function(code, out, err) {
      root.busy = false
      if (code !== 0) { root.fail(err); return }
      if (onSuccess) onSuccess(out)
    })
  }

  function refresh(withIndex) {
    run(["status", "--json"], "", function(code, out, err) {
      if (code !== 0) { root.fail(err); return }
      var s
      try { s = JSON.parse(out) } catch (e) { root.fail("bad status output"); return }
      var wasUnlocked = root.unlocked
      root.initialized = s.initialized === true
      root.unlocked = s.unlocked === true
      root.expires = String(s.expires || "")
      root.remote = s.remote === true
      root.unpushed = Number(s.unpushed || 0)
      root.loaded = true
      if (!root.unlocked) root.entries = []
      else if (withIndex || !wasUnlocked) root.loadIndex()
    })
  }

  function loadIndex() {
    run(["index"], "", function(code, out, err) {
      if (code !== 0) { root.fail(err); return }
      try { root.entries = JSON.parse(out) } catch (e) { root.fail("bad index output") }
    })
  }

  function init(passphrase) {
    act(["init", "--stdin"], passphrase, function() { root.refresh(true); root.unlockedNow() })
  }

  function unlock(passphrase) {
    act(["unlock", "--stdin"], passphrase, function() { root.refresh(true); root.unlockedNow() })
  }

  function lock() {
    act(["lock"], "", function() { root.refresh(false) })
  }

  // what: "value", "name" or "line" (KEY=value).
  function copy(env, key, what) {
    var args = ["copy", env, key]
    if (what === "name") args.push("--name")
    else if (what === "line") args.push("--line")
    var label = { value: key, name: key + " (name)", line: key + "=…" }[what] || key
    act(args, "", function() { root.say("Copied " + label) })
  }

  function reveal(env, key, done) {
    act(["get", env, key], "", function(out) { done(out.replace(/\n$/, "")) })
  }

  // Renaming (new env or key) writes the new entry first, then drops the old.
  function save(env, key, value, oldEnv, oldKey, done) {
    act(["set", env, key], value, function() {
      var renamed = oldKey !== "" && (oldEnv !== env || oldKey !== key)
      if (!renamed) { root.say("Saved " + key); root.refresh(true); done(); return }
      root.act(["rm", oldEnv, oldKey], "", function() { root.say("Saved " + key); root.refresh(true); done() })
    })
  }

  function remove(env, key) {
    act(["rm", env, key], "", function() { root.say("Deleted " + key); root.refresh(true) })
  }

  function sync() {
    act(["sync"], "", function() { root.say("Synced"); root.refresh(true) })
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: root.notice = ""
  }

  // Catches expiry and unlocks/locks done from a terminal.
  Timer {
    interval: 20000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Component {
    id: procComponent

    Process {
      id: proc
      property string input: ""
      property var done: null
      property int exitCode: -1
      property bool exited: false
      property int streamsDone: 0
      property string outText: ""
      property string errText: ""

      function finish() {
        if (!proc.exited || proc.streamsDone < 2) return
        if (proc.done) proc.done(proc.exitCode, proc.outText, proc.errText)
        proc.destroy()
      }

      stdinEnabled: true
      onStarted: {
        if (proc.input !== "") proc.write(proc.input + "\n")
        proc.input = ""
      }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: { proc.outText = text; proc.streamsDone++; proc.finish() }
      }
      stderr: StdioCollector {
        waitForEnd: true
        onStreamFinished: { proc.errText = text; proc.streamsDone++; proc.finish() }
      }
      onExited: function(code) {
        proc.exitCode = code
        proc.exited = true
        proc.finish()
      }
    }
  }
}
