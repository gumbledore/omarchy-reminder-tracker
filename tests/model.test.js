// Runs the pure model helpers under node. Exit status is the verdict.
const m = require("../ReminderFlowModel.js")
const assert = require("node:assert/strict")

// notes
const big = "x".repeat(5000)
const notes = m.sanitizeNotes([
  { id: 2, title: "b", body: big, created: 1, updated: 2 },
  { id: "1", title: "<b>", body: "hi\nthere" },
  { id: "nope", title: "bad" },
  null,
  { id: 3, title: "t".repeat(300) },
  { id: 51, title: "over the slot cap" },
])
assert.equal(notes.length, 3)
assert.equal(notes[0].body.length, 4000)
assert.equal(notes[1].id, 1)
assert.equal(notes[1].title, "<b>")
assert.equal(notes[1].body, "hi\nthere")
assert.equal(notes[2].title.length, 200)
assert.equal(notes[2].body, "")
assert.deepEqual(m.sanitizeNotes("junk"), [])
assert.equal(m.sanitizeNotes(Array.from({ length: 80 }, (_, i) => ({ id: i + 1, title: "n" }))).length, 50)

const vis = m.visibleNotes(notes, "hth")
assert.deepEqual(vis.map(n => n.id), [1]) // matches body "hi there"
assert.equal(m.visibleNotes(notes, "").length, 3)
assert.equal(m.visibleNotes(notes, "zzz").length, 0)
assert.equal(m.visibleNotes(notes, "b").length, 2) // title "b" and "<b>"

// existing helpers, so a runner exists for them too
assert.equal(m.matches("Call the clinic", "clc"), true)
assert.equal(m.matches("Call the clinic", "xyz"), false)
assert.equal(m.humanDelta(-90), "1m ago")
assert.deepEqual(m.snoozeArgs(3, " 2h "), ["snooze", "3", "2h"])
console.log("model ok")
