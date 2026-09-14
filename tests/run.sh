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

echo "notes"
rm -rf "$XDG_STATE_HOME"
NOTES="$XDG_STATE_HOME/rem/notes.json"
"$REM" note add "Wifi" "pw: hunter2" >/dev/null
"$REM" note add "Snippet" $'line one\nline two' >/dev/null
check "first note takes slot 1" '[[ $("$REM" note ls --json | jq ".notes[0].id") == 1 ]]'
check "second note takes slot 2" '[[ $("$REM" note ls --json | jq ".notes[1].id") == 2 ]]'
check "count reported" '[[ $("$REM" note ls --json | jq .count) == 2 ]]'
check "notes store is 600" '[[ $(stat -c %a "$NOTES") == 600 ]]'
check "body keeps newlines" '[[ $("$REM" note ls --json | jq -r ".notes[1].body") == $'"'"'line one\nline two'"'"' ]]'
check "show prints title, blank, body" '[[ $("$REM" note show 2) == $'"'"'Snippet\n\nline one\nline two'"'"' ]]'
check "show, ls and ls --json agree" '[[ $("$REM" note show 2 | head -1) == Snippet && $("$REM" note ls | awk "\$1 == 2 {print \$NF}") == Snippet && $("$REM" note ls --json | jq -r ".notes[] | select(.id == 2) | .title") == Snippet && $("$REM" note ls --json | jq -r ".notes[] | select(.id == 2) | .body") == "$("$REM" note show 2 | tail -n +3)" ]]'
check "ls lists in slot order" '[[ $("$REM" note ls | awk "{print \$1}" | tr "\n" " ") == "1 2 " ]]'
check "ls shows titles" '[[ $("$REM" note ls) == *Wifi* && $("$REM" note) == *Snippet* ]]'
"$REM" note rm 1 >/dev/null
check "rm frees the slot" '[[ $("$REM" note ls --json | jq .count) == 1 ]]'
"$REM" note add "Again" "x" >/dev/null
check "add reuses lowest free slot" '[[ $("$REM" note ls --json | jq -r ".notes[] | select(.title == \"Again\") | .id") == 1 ]]'
check "rm of empty slot refused" '! "$REM" note rm 7 2>/dev/null'
check "bad slot refused" '! "$REM" note rm 0 2>/dev/null && ! "$REM" note show 51 2>/dev/null && ! "$REM" note show abc 2>/dev/null'
check "title over 200 refused" '! "$REM" note add "$(head -c 201 /dev/zero | tr "\0" t)" "b" 2>/dev/null'
check "body over 4000 refused" '! "$REM" note add "t" "$(head -c 4001 /dev/zero | tr "\0" b)" 2>/dev/null'
check "title control chars cleaned" '"$REM" note add "$(printf "a\tb")" "c" >/dev/null && "$REM" note ls --json | jq -e ".notes[] | select(.title == \"a b\")" >/dev/null'
check "empty title refused" '! "$REM" note add "" "body" 2>/dev/null'
check "add without EDITOR and one arg fails" '! env -u EDITOR "$REM" note add "only title" 2>"$tmp/err" && grep -q "set \$EDITOR" "$tmp/err"'
check "add without EDITOR and no args fails" '! EDITOR= "$REM" note add 2>"$tmp/err" && grep -q "set \$EDITOR" "$tmp/err"'
check "edit without EDITOR fails" '! env -u EDITOR "$REM" note edit 1 2>"$tmp/err" && grep -q "set \$EDITOR" "$tmp/err"'
# A scripted editor stands in for a human: it rewrites the file it is handed.
# Its argument proves $EDITOR is word-split like git does it.
printf '#!/bin/bash\n[[ $1 == --flag ]] || exit 9\nprintf "%%s" "$FAKE_NOTE" >"$2"\n' >"$stub/fakeeditor"
chmod +x "$stub/fakeeditor"
export EDITOR="$stub/fakeeditor --flag"
check "add via editor, title only prefilled" 'FAKE_NOTE=$'"'"'Prefilled\n\nbody here\n'"'"' "$REM" note add "Prefilled" >/dev/null && [[ $("$REM" note ls --json | jq -r ".notes[] | select(.title == \"Prefilled\") | .body") == "body here" ]]'
check "add via editor, no args" 'FAKE_NOTE=$'"'"'  Fresh  \n\nline\n\nmore\n\n'"'"' "$REM" note add >/dev/null && [[ $("$REM" note ls --json | jq -r ".notes[] | select(.title == \"Fresh\") | .body") == $'"'"'line\n\nmore'"'"' ]]'
check "second line without a blank is body, not title" 'FAKE_NOTE=$'"'"'Tight\nright under it'"'"' "$REM" note add >/dev/null && [[ $("$REM" note ls --json | jq -r ".notes[] | select(.title == \"Tight\") | .body") == "right under it" ]]'
check "empty editor file cancels add" 'FAKE_NOTE="" "$REM" note add >/dev/null && [[ $("$REM" note ls --json | jq .count) == 6 ]]'
check "edit via editor" 'FAKE_NOTE=$'"'"'Renamed\n\nnew body'"'"' "$REM" note edit 1 >/dev/null && [[ $("$REM" note show 1) == $'"'"'Renamed\n\nnew body'"'"' ]]'
check "empty editor file leaves edit unchanged" 'FAKE_NOTE="" "$REM" note edit 1 >/dev/null && [[ $("$REM" note show 1) == $'"'"'Renamed\n\nnew body'"'"' ]]'
check "editor failure leaves note unchanged" '! EDITOR="$stub/fakeeditor --wrong" "$REM" note edit 1 2>/dev/null && [[ $("$REM" note show 1) == $'"'"'Renamed\n\nnew body'"'"' ]]'
check "no temp files left after editing" '[[ -z $(ls -A "$XDG_STATE_HOME/rem" | grep -v "^notes.json$") ]]'
unset EDITOR
rm -f "$NOTES"
for i in $(seq 50); do "$REM" note add "n$i" "b" >/dev/null; done
check "fifty notes fit" '[[ $("$REM" note ls --json | jq .count) == 50 ]]'
check "fifty-first refused naming cap" '! "$REM" note add "n51" "b" 2>"$tmp/err" && grep -q 50 "$tmp/err"'
check "items store untouched by notes" '[[ ! -e $XDG_STATE_HOME/rem/items.json ]]'

echo "note refusals"
echo 'not json' >"$NOTES"
check "corrupt notes refused, not clobbered" '! "$REM" note ls >/dev/null 2>&1 && [[ $(cat "$NOTES") == "not json" ]]'
check "corrupt notes leave reminders working" '"$REM" add "still fine" >/dev/null && [[ $("$REM" ls) == *"still fine"* ]]'
echo '[{"id":1,"title":5,"body":"","created":0,"updated":0}]' >"$NOTES"
check "wrong note types rejected" '! "$REM" note ls >/dev/null 2>&1'
head -c $((300 * 1024)) /dev/zero >"$NOTES"
check "oversized notes store rejected" '! "$REM" note ls >/dev/null 2>&1'
rm -f "$NOTES"; ln -s /etc/hostname "$NOTES"
check "symlinked notes store refused" '! "$REM" note ls >/dev/null 2>&1 && ! "$REM" note add t b >/dev/null 2>&1 && [[ -L $NOTES ]]'
rm -f "$NOTES"; mkfifo "$NOTES"
check "FIFO notes store refused" '! "$REM" note ls >/dev/null 2>&1'
rm -f "$NOTES"
foreign=""
for f in /etc/hostname /etc/os-release /etc/passwd; do
  [[ -f $f && $(stat -c %u "$f") != $(id -u) ]] && { foreign=$f; break; }
done
if [[ -n $foreign ]] && ln "$foreign" "$NOTES" 2>/dev/null; then
  check "foreign-owned notes store refused" '! "$REM" note ls >/dev/null 2>&1'
  rm -f "$NOTES"
else
  echo "  skip foreign-owned notes store (cannot hard-link a foreign file here)"
fi
rm -f "$NOTES"; touch "$NOTES"; ln "$NOTES" "$tmp/notes-alias"
check "hard-linked notes store refused" '! "$REM" note ls >/dev/null 2>&1'
rm -f "$NOTES" "$tmp/notes-alias"

echo "model"
if command -v node >/dev/null; then
  check "js model notes" 'node "$here/model.test.js"'
else
  echo "  skip js model (no node)"
fi

echo
echo "$pass passed, $fail failed"
((fail == 0))
