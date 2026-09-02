#!/bin/bash
# Smoke and hardening tests for `rem`, against a throwaway XDG_STATE_HOME.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REM="$here/../bin/rem"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
STORE="$XDG_STATE_HOME/rem/items.json"

pass=0 fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "round trip"
"$REM" add "Call the clinic @ +2 hours" >/dev/null
"$REM" add "Clear the desk" >/dev/null
check "two items listed" '[[ $("$REM" ls --json | jq .count) == 2 ]]'
check "state dir is 700" '[[ $(stat -c %a "$XDG_STATE_HOME/rem") == 700 ]]'
check "store is 600" '[[ $(stat -c %a "$STORE") == 600 ]]'
check "no temp files left" '[[ -z $(ls -A "$XDG_STATE_HOME/rem" | grep -v "^items.json$") ]]'
"$REM" done 1 >/dev/null
check "done archives" '[[ $(jq ".archive | length" "$STORE") == 1 ]]'
"$REM" undo >/dev/null
check "undo restores" '[[ $(jq ".items | length" "$STORE") == 2 ]]'
"$REM" snooze 1 2h >/dev/null
check "snooze sets due" '[[ $(jq ".items[] | select(.id == 1) | .due" "$STORE") -gt $(date +%s) ]]'
check "bare minutes" '"$REM" 5 "Tea" >/dev/null && [[ $("$REM" ls --json | jq .count) == 3 ]]'

echo "caps and input"
long=$(head -c 600 /dev/zero | tr "\0" x)
check "text over 500 chars refused" '! "$REM" add "$long" 2>/dev/null'
check "parse reports too long" '[[ $("$REM" parse "$long" | jq -r .ok) == false ]]'
check "control chars stripped" '"$REM" add "$(printf "tab\there")" >/dev/null && "$REM" ls --json | jq -e ".items[] | select(.text == \"tab here\")" >/dev/null'
check "bad id refused" '! "$REM" done "1e3" 2>/dev/null && ! "$REM" snooze "{\"a\":1}" 2h 2>/dev/null'
check "flag-looking text is content" '"$REM" add "--exec" >/dev/null && "$REM" ls --json | jq -e ".items[] | select(.text == \"--exec\")" >/dev/null'
check "unparseable time refused" '! "$REM" add "x @ not a time at all" 2>/dev/null'

# Fill to the item cap using a jq-built store, then check add refuses.
jq --argjson n 500 '.items = [range($n) | {id: ., text: "i\(.)", created: 0, due: null, notified: false}] | .nextId = 501' "$STORE" >"$tmp/full.json"
cp "$tmp/full.json" "$STORE"
check "item cap enforced" '! "$REM" add "one more" 2>/dev/null'
check "ls --json bounded by cap" '[[ $("$REM" ls --json | jq ".items | length") == 500 ]]'
jq '.archive = [range(300) | {id: ., text: "a\(.)", created: 0, due: null, closed: ., outcome: "done"}]' "$STORE" >"$tmp/arch.json"
cp "$tmp/arch.json" "$STORE"
"$REM" rm 1 >/dev/null
check "archive trimmed to 200" '[[ $(jq ".archive | length" "$STORE") == 200 ]]'
jq '.items[0].text = (.items[0].text + ("y" * 2000))' "$tmp/full.json" >"$STORE" 2>/dev/null
check "oversized stored text clipped on output" '[[ $("$REM" ls --json | jq -r ".items[0].text | length") -le 500 ]]'

echo "locking"
rm -f "$STORE"
stub="$tmp/stub"; mkdir -p "$stub"
printf '#!/bin/bash\nexit 0\n' >"$stub/pgrep"
printf '#!/bin/bash\nsetsid sleep 30 >/dev/null 2>&1 &\n' >"$stub/omarchy-notification-send"
chmod +x "$stub"/*
PATH="$stub:$PATH" "$REM" show >/dev/null
check "lock not inherited by notification children" 'timeout 3 "$REM" add "after show" >/dev/null'
"$REM" add "fires @ -1 minute" >/dev/null
PATH="$stub:$PATH" "$REM" sweep
check "lock not inherited by sweep children" 'timeout 3 "$REM" add "after sweep" >/dev/null'

echo "refusals"
echo 'not json' >"$STORE"
check "corrupt store reported, not clobbered" '! "$REM" ls >/dev/null 2>&1 && [[ $(cat "$STORE") == "not json" ]]'
echo '{"version":1,"nextId":1,"items":[{"id":"x"}],"archive":[]}' >"$STORE"
check "wrong item types rejected" '! "$REM" ls >/dev/null 2>&1'
head -c $((3 * 1024 * 1024)) /dev/zero >"$STORE"
check "oversized store rejected" '! "$REM" ls >/dev/null 2>&1'
rm -f "$STORE"; ln -s /etc/hostname "$STORE"
check "symlinked store refused" '! "$REM" ls >/dev/null 2>&1 && ! "$REM" add x >/dev/null 2>&1'
check "symlink target untouched" '[[ -L $STORE ]]'
rm -f "$STORE"; mkfifo "$STORE"
check "FIFO store refused without blocking" '! "$REM" ls >/dev/null 2>&1'
rm -rf "$XDG_STATE_HOME/rem"; mkdir -p "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$XDG_STATE_HOME/rem"
check "symlinked state dir refused" '! "$REM" add x >/dev/null 2>&1 && [[ -z $(ls -A "$tmp/elsewhere") ]]'
rm -f "$XDG_STATE_HOME/rem"; mkdir -m 755 "$XDG_STATE_HOME/rem"
"$REM" add x >/dev/null
check "lax dir mode tightened" '[[ $(stat -c %a "$XDG_STATE_HOME/rem") == 700 ]]'
check "parse never creates state" 'rm -rf "$XDG_STATE_HOME"; "$REM" parse "a @ tomorrow" >/dev/null; [[ ! -e $XDG_STATE_HOME ]]'

echo
echo "$pass passed, $fail failed"
((fail == 0))
