# section-span.awk: the one definition of an OpenSpec tasks.md section span,
# shared by openspec-section-brief (print, count) and openspec-section-tick (match, tick)
# so the two scripts can never disagree about what a section holds.
#
# A section runs from its "## N." heading to the next level-2 heading of any
# kind outside a ``` fence. A checkbox item is "- [ ]" or "- [x]" at any
# indent; a line inside a fence is never an item, whatever it looks like.
#
# Variables (-v):
#   n      section id: digits with an optional lowercase letter (3, 2b)
#   mode   print | count | match | tick
#   items  space-separated N.M item ids (2.3 2.10) for match and tick; empty
#          means every unticked checkbox line in the span
# Output:
#   print  the span, verbatim
#   count  "<open> <ticked>": checkbox lines in the span outside fences
#   match  one "<id> <open-count>" line per item, or "* <open-count>" when
#          items is empty; a count of 0 means nothing to tick for that id
#   tick   the whole file, with every matching unticked line ticked

BEGIN {
    head = "^##[ \t]+" n "\\."
    openpat = "^[[:blank:]]*- \\[ \\]"
    anypat  = "^[[:blank:]]*- \\[[ xX]\\]"
    m = 0
    if (items != "") {
        m = split(items, arr, " ")
        alt = ""
        for (i = 1; i <= m; i++) {
            it = arr[i]
            gsub(/\./, "[.]", it)
            alt = alt (alt == "" ? "" : "|") it
            want[arr[i]] = 0
        }
        itempat = "^[[:blank:]]*- \\[ \\][[:blank:]]+(" alt ")[[:blank:]]"
    }
}
/^```/ { infence = !infence }
!infence && /^##[ \t]/ { insec = ($0 ~ head) }
{
    hit = 0
    if (insec && !infence) {
        if (mode == "count") {
            if ($0 ~ openpat) open++
            else if ($0 ~ anypat) ticked++
        } else if (mode == "match" || mode == "tick") {
            if (items == "") {
                hit = ($0 ~ openpat)
            } else if ($0 ~ itempat) {
                line = $0
                sub(/^[[:blank:]]*- \[ \][[:blank:]]+/, "", line)
                split(line, tok, /[[:blank:]]/)
                id = tok[1]
                if (id in want) { want[id]++; hit = 1 }
            }
        }
    }
    if (mode == "print") { if (insec) print; next }
    if (mode == "tick") {
        if (hit) sub(/- \[ \]/, "- [x]")
        print
    }
    if (hit) nhit++
}
END {
    if (mode == "count") print open + 0, ticked + 0
    if (mode == "match") {
        if (items == "") print "*", nhit + 0
        else for (i = 1; i <= m; i++) print arr[i], want[arr[i]] + 0
    }
}
