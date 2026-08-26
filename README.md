# Reminder Tracker

A persistent to-do list for [Omarchy](https://omarchy.org/) that also notifies.

Omarchy's built-in `omarchy reminder` stores reminders as *transient* systemd
timers under `$XDG_RUNTIME_DIR`. They do not survive a reboot or a logout, and
they evaporate the moment they fire. That is the right design for a kitchen
timer and the wrong one for anything you actually need to remember.

This is the same idea with the storage fixed, plus the thing that falls out of
fixing it for free: a to-do list.

![Typing a reminder, with the due time resolved live](docs/preview-relative.png)

## The model

One record type: an **item** with an optional **due time**.

| | |
|---|---|
| no due time | a plain to-do — sits on the list until you deal with it |
| a due time | notifies once, then *stays on the list* |

**Firing never completes an item.** Only `rem done` or `rem rm` takes something
off the list. A notification you missed while in a meeting is a nudge you
missed, not a task that silently disappeared.

## Install

```bash
omarchy plugin add https://github.com/gumbledore/omarchy-reminder-tracker.git --enable
~/.config/omarchy/plugins/gumbledore.reminders/install.sh
```

The plugin ships the QML surfaces; `install.sh` links the `rem` CLI onto your
PATH and enables the sweeper timer that actually fires reminders. Both are
symlinked back into the cloned repo, so `omarchy plugin update` updates
everything together.

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + T", "Reminders", "rem show-overlay")
```

This coexists with the built-in reminders plugin. If you want it to *replace*
that one, disable the stock plugin yourself:

```bash
omarchy plugin disable omarchy.reminders
```

**Requires:** Omarchy with the Quickshell-based shell, plus `jq` and GNU
`date` (both already present on Arch).

## Using it

`SUPER+SHIFT+T` opens the list. The filter line is also the new-item field, so
searching and adding are the same gesture.

```
┌─ Reminders ──────────────────────────────┐
│ > cl                                     │
│   Call the clinic               OVERDUE  │
│   Clear the desk                         │
└──────────────────────────────────────────┘
 Enter  done    Ctrl+Enter  snooze    Del  drop    Ctrl+Z  undo
```

Type something nothing matches and Enter creates it instead.

### Scheduling

Everything after ` @ ` goes verbatim to GNU `date -d`, so you can write what
you mean:

```
Call the clinic @ fri 2pm
Renew the domain @ 2 weeks
Standup @ tomorrow 9am
Book flights @ next tuesday 14:00
Pay the invoice @ sep 3
Clear the desk                     <- no "@" at all: a to-do, never fires
```

The overlay resolves the expression **live as you type**, so you commit to a
real timestamp rather than to your guess about how `date` will read it:

![A weekday with no time resolves to midnight](docs/preview-weekday.png)

That matters more than it sounds. `@ friday` above is not wrong, but it means
*Friday at 00:00* — `date -d` defaults to midnight when you give it a day and
no time. Write `@ friday 2pm` if you meant the afternoon. The preview is there
so you find that out before you commit, not at midnight.

Leave the `@` off entirely and you get a to-do with no due time, which never
notifies and sits on the list until you deal with it:

![No due time makes a plain to-do](docs/preview-todo.png)

### CLI

```bash
rem                             # list open items
rem add "Call the clinic @ fri 2pm"
rem add "Clear the desk"        # no "@" -> a to-do with no due time
rem 15 "Tea"                    # bare minutes, like `omarchy reminder`
rem done 3                      # complete (archived, undoable)
rem snooze 3 2h                 # push the due time out
rem rm 3                        # drop
rem undo                        # restore the most recently closed item
rem show                        # the list, as a notification
rem ls --json                   # machine-readable
```

## How it holds up

Four decisions do most of the work, and they are the parts worth knowing about
before you trust this with anything.

**One writer.** `~/.local/state/rem/items.json` is the single source of truth
and `rem` is the only thing that writes it — `flock`, write-temp, rename. The
QML overlay and the sweeper shell out to `rem` rather than parsing the store
themselves, so locking lives in exactly one place and the UI never displays
state the store has not confirmed.

**The timer is `OnCalendar`, not monotonic.** `Persistent=true` only takes
effect on calendar timers. That is precisely what makes a reminder survive a
shutdown: systemd replays the sweep it missed while the machine was off.

**Missed reminders arrive as one notification, not an avalanche.** Come back
from three days away and you get a single *"4 reminders came due while you were
away"* — and all four are still on the list, flagged overdue, because firing
does not complete anything.

**A reminder cannot fire into a dead session.** If the shell is not running,
`rem sweep` sends nothing *and marks nothing as notified*, leaving the items for
the next sweep. Without that guard, a reminder coming due during a shell
restart would be silently consumed.

## Uninstall

```bash
systemctl --user disable --now rem-sweep.timer
rm ~/.local/bin/rem ~/.config/systemd/user/rem-sweep.{service,timer}
systemctl --user daemon-reload
omarchy plugin remove gumbledore.reminders
```

Your items stay at `~/.local/state/rem/items.json`; delete it if you want them
gone.

## Not included

No recurrence, tags, priorities, or sync. Each of those reopens decisions this
design closes cleanly — recurrence in particular changes what "done" means and
what happens to occurrences you slept through. Deliberately left out until the
simple version has earned it.

## License

MIT
