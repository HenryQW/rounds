# Filter records by their complete first field.
# The callers own the order, record contents and persistence of each list.
ticket_rows() {
  BOUNCER_TICKET_KEY="$2" BOUNCER_TICKET_REPLACEMENT="${4-}" awk -v action="$1" '
    { separator = index($0, " |") }
    separator > 0 && substr($0, 1, separator - 1) == ENVIRON["BOUNCER_TICKET_KEY"] {
      if (action == "find") print
      if (action == "replace") print ENVIRON["BOUNCER_TICKET_REPLACEMENT"]
      next
    }
    action != "find"
  ' "$3"
}
