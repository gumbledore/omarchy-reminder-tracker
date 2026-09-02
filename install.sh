#!/bin/bash
#
# Link `rem` onto PATH and start the sweeper timer.
#
# `omarchy plugin add` clones this repo into ~/.config/omarchy/plugins/ and
# loads the QML, but the QML is only a view: the CLI and the systemd timer do
# the actual work, and omarchy has no hook for installing those. Hence this.
#
# Everything is symlinked back into the cloned repo, so `omarchy plugin update`
# updates the CLI and the units along with the QML.

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rem"

say() { printf '  %s\n' "$*"; }

command -v jq >/dev/null || { echo "install.sh: jq is required" >&2; exit 1; }

mkdir -p "$BIN_DIR" "$UNIT_DIR"
# The store holds only your own text, but it is yours: private directory, and
# `rem` refuses to use it if it is ever anything else.
if [[ -L $STATE_DIR ]]; then
  echo "install.sh: $STATE_DIR is a symlink; rem will refuse it. Remove it first" >&2
  exit 1
fi
mkdir -p -m 700 "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Never clobber a real file with a symlink, whichever of ours it is.
for target in "$BIN_DIR/rem" "$UNIT_DIR/rem-sweep.service" "$UNIT_DIR/rem-sweep.timer"; do
  if [[ -e $target && ! -L $target ]]; then
    echo "install.sh: $target exists and is not a symlink; move it aside first" >&2
    exit 1
  fi
done

# --- the CLI ---------------------------------------------------------------

ln -sfn "$REPO_DIR/bin/rem" "$BIN_DIR/rem"
say "linked $BIN_DIR/rem"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "NOTE: $BIN_DIR is not on your PATH — add it to your shell profile" ;;
esac

# --- the sweeper -----------------------------------------------------------

ln -sfn "$REPO_DIR/systemd/rem-sweep.service" "$UNIT_DIR/rem-sweep.service"
ln -sfn "$REPO_DIR/systemd/rem-sweep.timer" "$UNIT_DIR/rem-sweep.timer"
systemctl --user daemon-reload
systemctl --user enable --now rem-sweep.timer
say "enabled rem-sweep.timer (fires due reminders every minute)"

# --- keybinding hint -------------------------------------------------------

cat <<'EOF'

  Done. Two things left, both yours to decide:

    1. Bind a key to open the list. In ~/.config/hypr/bindings.lua:
         o.bind("SUPER + SHIFT + T", "Reminders", "rem show-overlay")

    2. This plugin coexists with omarchy's built-in reminders rather than
       replacing it. To make the swap, disable the stock one:
         omarchy plugin disable omarchy.reminders

  Try it:  rem add "Ship the thing @ friday 2pm"  &&  rem
EOF
