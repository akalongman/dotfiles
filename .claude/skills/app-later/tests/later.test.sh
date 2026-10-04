#!/usr/bin/env bash
# shellcheck disable=SC1010,SC2016,SC2088
# SC1010: `done` is passed as a subcommand argument throughout.
# SC2016, SC2088: literal backticks and a literal tilde are asserted on.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="$HOME"
# shellcheck source=/dev/null
source "$REAL_HOME/.claude/scripts/tests/assert.sh"
ENGINE="$HERE/../scripts/later.sh"

# Every engine call runs with a throwaway HOME and cache, UTC, and a fixed
# clock: 2026-10-04 14:05:00 UTC.
T_HOME="$(mktemp -d)";  TMPDIRS+=("$T_HOME")
T_CACHE="$(mktemp -d)"; TMPDIRS+=("$T_CACHE")
NOW=1791122700
DAY=86400

lt() { # dir args...
    local dir="$1"; shift
    ( cd "$dir" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" bash "$ENGINE" "$@" )
}

# --- resolution, add, list -------------------------------------------

repo="$(mk_repo)"
mkdir -p "$repo/app/Http"
out="$(lt "$repo/app/Http" add check the S3 retry path)"
assert_eq "$out" "later: parked -> check the S3 retry path" "add confirms"
assert_file "$repo/NOTES.local.md" "subdirectory parks at the git toplevel"
assert_nofile "$repo/app/Http/NOTES.local.md" "no queue in the subdirectory"
assert_eq "$(sed -n 3p "$repo/NOTES.local.md")" "- [ ] check the S3 retry path (2026-10-04 14:05)" "note is stamped"
assert_eq "$(sed -n 1p "$repo/NOTES.local.md")" '# Parked notes (`/later`)' "new queue gets the heading"

git -C "$repo" worktree add -q -b feat/x "$repo/.worktrees/feat-x" >/dev/null 2>&1
mkdir -p "$repo/.worktrees/feat-x/sub"
lt "$repo/.worktrees/feat-x/sub" add from the worktree >/dev/null
assert_nofile "$repo/.worktrees/feat-x/NOTES.local.md" "worktree does not get its own queue"
assert_contains "$(cat "$repo/NOTES.local.md")" "from the worktree" "worktree parks in the main checkout"

plain="$(mktemp -d)"; TMPDIRS+=("$plain")
lt "$plain" add outside any repo >/dev/null
assert_file "$plain/NOTES.local.md" "no repository: queue in the directory itself"

# HOME is itself a repository (dotfiles): a directory under it with no
# repository of its own must not fall through to the HOME queue.
git -C "$T_HOME" init -q
mkdir -p "$T_HOME/Downloads/foo"
lt "$T_HOME/Downloads/foo" add under home >/dev/null
assert_file "$T_HOME/Downloads/foo/NOTES.local.md" "home-as-repo: queue stays in the directory"
assert_nofile "$T_HOME/NOTES.local.md" "home-as-repo: HOME queue untouched"
lt "$T_HOME" add in home itself >/dev/null
assert_file "$T_HOME/NOTES.local.md" "HOME itself uses the HOME queue"

q="$(mk_repo)"
out="$(lt "$q" add "$(printf 'line one\nline   two\t end ')")"
assert_eq "$(tail -n1 "$q/NOTES.local.md")" "- [ ] line one line two end (2026-10-04 14:05)" "whitespace and newlines collapse"
out="$(lt "$q" add '   ')"
assert_eq "$out" "later: nothing to park (empty note)" "empty note refused"
assert_eq "$(grep -c '^- \[ \]' "$q/NOTES.local.md")" "1" "empty note not written"

# Legacy and hand-edited lines, a closed line, and a file without a final newline.
l="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' \
    '- [ ] Move upload disk config to env' \
    '- [x] already done' \
    '  -  [ ]   hand edited spacing' \
    '- [ ] Recheck group lecturer policy (2026-09-22 09:00)' > "$l/NOTES.local.md"
printf '%s' '- [ ] no final newline' >> "$l/NOTES.local.md"
before="$(md5sum < "$l/NOTES.local.md")"
out="$(lt "$l" list)"
assert_eq "$(md5sum < "$l/NOTES.local.md")" "$before" "list never rewrites the file"
assert_contains "$out" "$(basename "$l"): 4 parked" "list header counts open notes only"
assert_contains "$out" " 1. Move upload disk config to env (undated)" "legacy note is undated"
assert_contains "$out" " 2. hand edited spacing (undated)" "hand-edited spacing parses"
assert_contains "$out" " 3. Recheck group lecturer policy (12d)" "age in days"
assert_contains "$out" " 4. no final newline (undated)" "last line without newline is read"
lt "$l" add appended after a missing newline >/dev/null
assert_eq "$(grep -c 'no final newline$' "$l/NOTES.local.md")" "1" "append does not glue onto the last line"
assert_contains "$(lt "$l" list)" " 5. appended after a missing newline (today)" "fresh note is today"

e="$(mk_repo)"
assert_eq "$(lt "$e" list)" "later: no parked notes" "list with no queue file"

# A stamp-shaped tail that is not a real date stays part of the text.
b="$(mk_repo)"
printf '%s\n' '- [ ] call back (2026-13-45 99:99)' > "$b/NOTES.local.md"
assert_contains "$(lt "$b" list)" " 1. call back (2026-13-45 99:99) (undated)" "invalid stamp is text"

# --- done, drop -------------------------------------------------------

d="$(mk_repo)"
printf '%s\n' '# Parked notes (`/later`)' '' '- [ ] one' '- [x] closed' '- [ ] two (2026-10-01 10:00)' '- [ ] three' > "$d/NOTES.local.md"
out="$(lt "$d" done 2)"
assert_eq "$out" "later: done -> two" "done prints the closed note"
assert_eq "$(sed -n 5p "$d/NOTES.local.md")" "- [x] two (2026-10-01 10:00)" "done ticks the box and keeps the line"
assert_contains "$(lt "$d" list)" " 2. three (undated)" "positions renumber after a close"

before="$(md5sum < "$d/NOTES.local.md")"
assert_fail "out of range exits non-zero" lt "$d" done 1 9
assert_eq "$(md5sum < "$d/NOTES.local.md")" "$before" "out of range leaves the file byte-identical"
assert_fail "zero is out of range" lt "$d" done 0
assert_fail "non-number refused" lt "$d" done 1x
assert_fail "no numbers refused" lt "$d" done
assert_fail "absurdly large number refused" lt "$d" done 99999999999999999999
assert_eq "$(md5sum < "$d/NOTES.local.md")" "$before" "refused numbers leave the file byte-identical"

out="$(lt "$d" drop 1 2)"
assert_contains "$out" "later: dropped -> one" "drop prints the first note"
assert_contains "$out" "later: dropped -> three" "drop prints the second note"
assert_eq "$(grep -c -e 'one' -e 'three' "$d/NOTES.local.md")" "0" "drop removes the lines"
assert_eq "$(grep -c '^- \[x\]' "$d/NOTES.local.md")" "2" "closed notes survive a drop"
assert_eq "$(lt "$d" list)" "later: no parked notes" "queue is empty after closing everything"
assert_eq "$(find "$d" -maxdepth 1 -name 'NOTES.local.md.*' | wc -l)" "0" "no temp file left behind"

chmod 640 "$d/NOTES.local.md"; lt "$d" add perm check >/dev/null; lt "$d" done 1 >/dev/null
assert_eq "$(stat -c %a "$d/NOTES.local.md")" "640" "rewrite keeps the file mode"

# Characters that shells, printf and awk like to interpret.
sp="$(mk_repo)"
weird='50% of C:\new\table & *.php "quoted" $HOME `tick`'
lt "$sp" add "$weird" >/dev/null
assert_contains "$(lt "$sp" list)" " 1. $weird (today)" "special characters survive add and list"
assert_eq "$(lt "$sp" done 1)" "later: done -> $weird" "special characters survive done"

# A queue that is a symlink (for example into a synced folder) stays one.
lk="$(mk_repo)"; store="$(mktemp -d)"; TMPDIRS+=("$store")
printf '%s\n' '- [ ] linked one' '- [ ] linked two' > "$store/notes.md"
ln -s "$store/notes.md" "$lk/NOTES.local.md"
lt "$lk" done 1 >/dev/null
assert_ok "symlinked queue stays a symlink" test -L "$lk/NOTES.local.md"
assert_eq "$(sed -n 1p "$store/notes.md")" "- [x] linked one" "rewrite lands in the link target"

nq="$(mk_repo)"
assert_fail "done with no queue file fails" lt "$nq" done 1
assert_nofile "$nq/NOTES.local.md" "done does not create a queue"

# Parallel writers: a rewrite racing appends must not lose a note.
r="$(mk_repo)"
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "seed $i" >/dev/null; done
for i in 1 2 3 4 5 6 7 8; do lt "$r" add "racer $i" >/dev/null & lt "$r" done 1 >/dev/null & done
wait
assert_eq "$(grep -c 'racer' "$r/NOTES.local.md")" "8" "no append lost during rewrites"
assert_eq "$(grep -c '^- \[x\]' "$r/NOTES.local.md")" "8" "every done landed"

# --- all --------------------------------------------------------------

roots="$(mktemp -d)"; TMPDIRS+=("$roots")
mkdir -p "$roots/a" "$roots/b" "$roots/c" "$roots/a/node_modules/pkg" "$roots/a/.worktrees/w" "$roots/a/vendor/x"
printf '%s\n' '- [ ] a1 (2026-09-13 14:05)' '- [ ] a2 (2026-10-04 10:00)' > "$roots/a/NOTES.local.md"
printf '%s\n' '- [ ] b1' '- [ ] b2' '- [ ] b3 (2026-10-01 10:00)' > "$roots/b/NOTES.local.md"
printf '%s\n' '- [x] all closed' > "$roots/c/NOTES.local.md"
printf '%s\n' '- [ ] hidden' | tee "$roots/a/node_modules/pkg/NOTES.local.md" "$roots/a/.worktrees/w/NOTES.local.md" > "$roots/a/vendor/x/NOTES.local.md"
all() { ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" LATER_ROOTS="$1" bash "$ENGINE" all ); }
out="$(all "$roots")"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "  3 open, oldest undated   $roots/b" "largest queue first, undated is oldest"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "  2 open, oldest 21d       $roots/a" "oldest age of a dated queue"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" "  5 open in 2 queues" "total line; closed-only and pruned queues omitted"
assert_eq "$(printf '%s\n' "$out" | wc -l)" "3" "nothing else printed"
assert_contains "$(all "$roots/a:$roots/b:/nonexistent")" "  5 open in 2 queues" "several roots, missing root ignored"
assert_eq "$(all "$roots/c")" "later: no parked notes" "no open notes anywhere"
mkdir -p "$T_HOME/proj"; printf '%s\n' '- [ ] h1' > "$T_HOME/proj/NOTES.local.md"
out="$( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" bash "$ENGINE" all )"
assert_contains "$out" "~/proj" "default root is HOME, shown with a tilde"

# A queue that is a symlink to a regular file is counted, once. The link
# target lives outside the scanned root, so it cannot count as a second queue.
lroot="$(mktemp -d)"; ltarget="$(mktemp -d)"; TMPDIRS+=("$lroot" "$ltarget")
mkdir -p "$lroot/p"; printf '%s\n' '- [ ] via link' > "$ltarget/notes.md"
ln -s "$ltarget/notes.md" "$lroot/p/NOTES.local.md"
assert_eq "$(all "$lroot")" "  1 open, oldest undated   $lroot/p"$'\n'"  1 open in 1 queues" "all counts a symlinked queue"

# --- session-start ----------------------------------------------------

hook_in() { jq -n --arg cwd "$1" --arg src "${2:-startup}" '{cwd: $cwd, source: $src, hook_event_name: "SessionStart"}'; }
ss() { # stdin: hook input; prints the user-visible message
    ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" bash "$ENGINE" session-start ) | jq -r '.systemMessage // empty'
}

s="$(mk_repo)"; mkdir -p "$s/deep/er"
printf '%s\n' '- [ ] old undated' '- [ ] old dated (2026-09-01 08:00)' '- [ ] n3' '- [ ] n4' '- [ ] n5' '- [ ] n6' > "$s/NOTES.local.md"

# First display ever: stamped notes are new, the list is due.
out="$(hook_in "$s/deep/er" | ss)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p)" "later: 6 parked in $(basename "$s"), 1 new: old dated" "count line, from a subdirectory"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "Oldest notes:" "list shown when never shown"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p)" " 1. old undated (undated)" "undated first, in file order"
assert_eq "$(printf '%s\n' "$out" | sed -n 7p)" " 6. n6 (undated)" "list capped at five, dated note sorts after undated"
assert_eq "$(printf '%s\n' "$out" | wc -l)" "7" "five list rows"

# Next display two minutes later: nothing new, list not due.
NOW=$((NOW + 120))
assert_eq "$(hook_in "$s" | ss)" "later: 6 parked in $(basename "$s")" "quiet queue shows the count only"

# A note parked now is announced once.
lt "$s" add fresh one >/dev/null
NOW=$((NOW + 3600))
assert_eq "$(hook_in "$s" | ss)" "later: 7 parked in $(basename "$s"), 1 new: fresh one" "new note announced"
NOW=$((NOW + 3600))
assert_eq "$(hook_in "$s" | ss)" "later: 7 parked in $(basename "$s")" "and only once"

# Parked in the same minute as a display, after it: still announced next time.
NOW=$((NOW + 20)); hook_in "$s" | ss >/dev/null
NOW=$((NOW + 20)); lt "$s" add same minute >/dev/null
NOW=$((NOW + 600))
assert_contains "$(hook_in "$s" | ss)" "1 new: same minute" "same-minute note is not skipped"

# More than three new notes.
for i in 1 2 3 4 5; do lt "$s" add "burst $i" >/dev/null; done
NOW=$((NOW + 600))
assert_contains "$(hook_in "$s" | ss)" "5 new: burst 1; burst 2; burst 3, +2 more" "first three named, rest counted"

# The list returns after seven days, and LATER_DIGEST_COUNT caps it.
NOW=$((NOW + 7 * DAY))
out="$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" LATER_DIGEST_COUNT=2 bash "$ENGINE" session-start ) | jq -r .systemMessage)"
assert_eq "$(printf '%s\n' "$out" | wc -l)" "4" "weekly list due again, capped by LATER_DIGEST_COUNT"

# Long notes are clipped in the display, never in the file or in `list`.
lg="$(mk_repo)"
long="$(printf 'x%.0s' $(seq 1 300))"
lt "$lg" add "$long" >/dev/null
NOW=$((NOW + 600))
out="$(hook_in "$lg" | ss)"
assert_eq "$(printf '%s\n' "$out" | sed -n 1p | wc -c)" "$(( $(printf 'later: 1 parked in %s, 1 new: ' "$(basename "$lg")" | wc -c) + 100 + 1 ))" "new note clipped to 100 characters"
assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "xxx..." "clip is marked"
assert_eq "$(printf '%s\n' "$out" | sed -n 3p | wc -c)" "$(( 4 + 100 + 8 + 1 ))" "list row clipped to 100 characters"
assert_contains "$(lt "$lg" list)" "$long" "list prints the note in full"

# Silent paths: every one exits 0 and prints nothing.
assert_eq "$(hook_in "$s" resume | ss)" "" "resume is ignored"
assert_eq "$(hook_in "$s" compact | ss)" "" "compact is ignored"
assert_eq "$(jq -n --arg cwd "$s" '{cwd: $cwd, source: "startup", agent_id: "a1"}' | ss)" "" "subagent is ignored"
assert_eq "$(printf 'not json' | ss)" "" "malformed input is ignored"
assert_eq "$(printf '' | ss)" "" "empty input is ignored"
assert_eq "$(hook_in "$e" | ss)" "" "no queue file: nothing"
assert_eq "$(hook_in "$d" | ss)" "" "no open notes: nothing"
assert_eq "$(hook_in /nonexistent/dir | ss)" "" "missing directory: nothing"
assert_eq "$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" CLAUDE_CODE_ENTRYPOINT=sdk-cli bash "$ENGINE" session-start ))" "" "headless session is ignored"
assert_ok "malformed input exits 0" bash -c "printf 'not json' | HOME='$T_HOME' XDG_CACHE_HOME='$T_CACHE' CLAUDE_CODE_ENTRYPOINT=cli bash '$ENGINE' session-start"

# Unwritable state: still displays.
ro="$(mktemp -d)"; TMPDIRS+=("$ro"); chmod 500 "$ro"
out="$(hook_in "$s" | ( cd / && HOME="$T_HOME" XDG_CACHE_HOME="$ro" CLAUDE_CODE_ENTRYPOINT=cli TZ=UTC LATER_NOW="$NOW" bash "$ENGINE" session-start ) | jq -r '.systemMessage // empty')"
assert_contains "$out" "later: 13 parked" "display works when state cannot be written"
chmod 700 "$ro"

# Corrupt state file is treated as never shown.
key="$(printf '%s' "$s/NOTES.local.md" | sha1sum | cut -d' ' -f1)"
printf 'garbage\n\n' > "$T_CACHE/later/v2/$key"
assert_contains "$(hook_in "$s" | ss)" "Oldest notes:" "corrupt state means never shown"

# --- wrapper shapes ---------------------------------------------------
WRAPPER="${LATER_WRAPPER:-$REAL_HOME/bin/later}"

w="$(mk_repo)"
wr() { ( cd "$w" && HOME="$T_HOME" XDG_CACHE_HOME="$T_CACHE" TZ=UTC LATER_NOW="$NOW" LATER_ENGINE="$ENGINE" bash "$WRAPPER" "$@" ); }
assert_eq "$(wr)" "later: no parked notes" "bare later lists"
wr first note >/dev/null
assert_eq "$(wr done with the migration, check logs)" "later: parked -> done with the migration, check logs" "done plus words is a note"
assert_eq "$(wr all hands meeting notes)" "later: parked -> all hands meeting notes" "all plus words is a note"
assert_eq "$(wr -- all)" "later: parked -> all" "double dash parks a subcommand word"
assert_eq "$(wr drop)" "later: parked -> drop" "drop with no numbers is a note"
assert_eq "$(wr done 1)" "later: done -> first note" "done with a number closes"
assert_eq "$(wr drop 1 2)" "$(printf 'later: dropped -> done with the migration, check logs\nlater: dropped -> all hands meeting notes')" "drop with numbers deletes"
assert_contains "$(LATER_ROOTS="$w" wr all)" "open in 1 queues" "all alone scans"
assert_contains "$(wr --help)" "later done <n>" "help lists the subcommands"

finish
