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

function visibleItems(items, filter) {
  var list = Array.isArray(items) ? items : []
  if (isCreateIntent(filter)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (matches(list[i].text, filter)) out.push(list[i])
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
    visibleItems: visibleItems,
    humanDelta: humanDelta,
    dueLabel: dueLabel,
    snoozeArgs: snoozeArgs
  }
}
