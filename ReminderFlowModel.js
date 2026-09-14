// Pure helpers for the reminder overlay. Kept free of QML types so the
// filtering and label logic can be reasoned about (and tested) on its own.

// Subsequence match, same feel as the Omarchy menu filter: "clc" finds
// "Call the clinic".
function matches(text, filter) {
  if (!filter) return true
  var haystack = String(text || "").toLowerCase()
  var needle = String(filter).toLowerCase().replace(/\s+/g, "")
  var i = 0
  for (var c = 0; c < haystack.length && i < needle.length; c++) {
    if (haystack[c] === needle[i]) i++
  }
  return i === needle.length
}

// The text typed into the filter is also the text of a new item, so a filter
// carrying an " @ " is a create gesture, never a search.
function isCreateIntent(filter) {
  return String(filter || "").indexOf(" @ ") !== -1
}

// Caps mirrored from `rem`. The list only ever renders items that pass this,
// so a malformed or oversized record from the store cannot reach a Text.
var MAX_ITEMS = 500
var MAX_TEXT = 500

function sanitizeItems(items) {
  if (!Array.isArray(items)) return []
  var out = []
  for (var i = 0; i < items.length && out.length < MAX_ITEMS; i++) {
    var it = items[i]
    if (!it || typeof it !== "object") continue
    var id = Number(it.id)
    if (!isFinite(id)) continue
    var due = (it.due === null || it.due === undefined) ? null : Number(it.due)
    if (due !== null && !isFinite(due)) due = null
    out.push({
      id: id,
      text: String(it.text === undefined || it.text === null ? "" : it.text).slice(0, MAX_TEXT),
      due: due,
      overdue: it.overdue === true
    })
  }
  return out
}

function visibleItems(items, filter) {
  var list = Array.isArray(items) ? items : []
  if (isCreateIntent(filter)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (matches(list[i].text, filter)) out.push(list[i])
  }
  return out
}

// Notes: same idea, own caps. A note's id is its slot, so it is small and
// positive or the record is not one of ours.
var MAX_NOTES = 50
var MAX_NOTE_TITLE = 200
var MAX_NOTE_BODY = 4000

function sanitizeNotes(notes) {
  if (!Array.isArray(notes)) return []
  var out = []
  for (var i = 0; i < notes.length && out.length < MAX_NOTES; i++) {
    var n = notes[i]
    if (!n || typeof n !== "object") continue
    var id = Number(n.id)
    if (!isFinite(id) || id < 1) continue
    out.push({
      id: id,
      title: String(n.title === undefined || n.title === null ? "" : n.title).slice(0, MAX_NOTE_TITLE),
      body: String(n.body === undefined || n.body === null ? "" : n.body).slice(0, MAX_NOTE_BODY)
    })
  }
  return out
}

// The filter reaches into the body too: a note is found by what it says, not
// only by what it is called.
function visibleNotes(notes, filter) {
  var list = Array.isArray(notes) ? notes : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (matches(list[i].title + "\n" + list[i].body, filter)) out.push(list[i])
  }
  return out
}

// Relative time, matching `rem`'s own phrasing so the overlay and the CLI
// never disagree about how far off something is.
function humanDelta(seconds) {
  var s = seconds
  var past = s < 0
  if (past) s = -s

  var out
  if (s < 60) out = s + "s"
  else if (s < 3600) out = Math.floor(s / 60) + "m"
  else if (s < 86400) out = Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  else if (s < 604800) out = Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h"
  else out = Math.floor(s / 604800) + "w " + Math.floor((s % 604800) / 86400) + "d"

  return past ? out + " ago" : "in " + out
}

// Right-hand column for a row: the fact you need to triage it at a glance.
function dueLabel(item, nowSeconds) {
  if (!item || item.due === null || item.due === undefined) return ""
  if (item.overdue) return "OVERDUE"
  return humanDelta(item.due - nowSeconds)
}

function snoozeArgs(id, spec) {
  var duration = String(spec || "").trim()
  if (!duration) return []
  return ["snooze", String(id), duration]
}

if (typeof module !== "undefined") {
  module.exports = {
    matches: matches,
    isCreateIntent: isCreateIntent,
    sanitizeItems: sanitizeItems,
    visibleItems: visibleItems,
    sanitizeNotes: sanitizeNotes,
    visibleNotes: visibleNotes,
    humanDelta: humanDelta,
    dueLabel: dueLabel,
    snoozeArgs: snoozeArgs
  }
}
