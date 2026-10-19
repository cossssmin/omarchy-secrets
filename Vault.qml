import QtQuick
import Quickshell
import Quickshell.Io

// Lock state and the env/key index, backed by bin/secrets. The CLI owns all
// crypto, git and settings (~/.config/secrets/config); values only pass
// through here when revealed or edited, and passphrases/values always go
// over stdin, never argv.
Item {
  id: root

  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/secrets").toString().replace(/^file:\/\//, ""))

  property bool loaded: false
  property bool initialized: false
  property bool unlocked: false
  property string expires: ""
  property bool remote: false
  property int unpushed: 0
  property bool trusted: true
  property var entries: []
  // dir, ttl (seconds), sync ("github" | "local"), lockOnScreenLock, remote
  property var config: ({})

  property bool busy: false
  property bool syncing: false
  property string error: ""
  property string notice: ""

  signal unlockedNow()

  onBusyChanged: if (!busy) root.syncing = false

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
    var proc = procComponent.createObject(root, {
      command: [root.cli].concat(args),
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
      // A refused save leaves the recipients error up; drop it once trusted.
      if (!root.trusted && s.trusted !== false) root.error = ""
      root.trusted = s.trusted !== false
      root.loaded = true
      // Nothing else can watch the lock screen for us, so this poll does.
      if (root.unlocked && s.lockOnScreenLock && s.screenLocked) { root.lock(); return }
      if (!root.unlocked) root.entries = []
      else if (withIndex || !wasUnlocked) root.loadIndex()
    })
  }

  function loadConfig() {
    run(["config"], "", function(code, out, err) {
      if (code !== 0) { root.fail(err); return }
      try { root.config = JSON.parse(out) } catch (e) { root.fail("bad config output") }
    })
  }

  // Applies [[name, value], ...] one at a time, stopping at the first error.
  function saveConfig(changes, done) {
    if (changes.length === 0) {
      root.say("Settings saved")
      root.loadConfig()
      root.refresh(true)
      done()
      return
    }
    act(["config", "set", changes[0][0], String(changes[0][1])], "", function() {
      root.saveConfig(changes.slice(1), done)
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

  function renameEnv(from, to, done) {
    act(["mv", from, to], "", function() { root.say("Renamed " + from + " to " + to); root.refresh(true); done() })
  }

  function remove(env, key) {
    act(["rm", env, key], "", function() { root.say("Deleted " + key); root.refresh(true) })
  }

  function sync() {
    root.syncing = true
    act(["sync"], "", function() { root.say("Synced"); root.refresh(true) })
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: root.notice = ""
  }

  Component.onCompleted: root.loadConfig()

  // Catches expiry, screen locks, and unlocks/locks done from a terminal.
  Timer {
    interval: 5000
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
