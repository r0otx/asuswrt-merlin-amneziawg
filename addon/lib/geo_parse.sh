#!/bin/sh
# addon/lib/geo_parse.sh — pure parsers for v2fly domain-list-community format.
# Public:
#   geo_filter_domain            # stdin -> stdout, stripping regexp: and attributes
#   geo_resolve_includes <src_dir> <max_depth> <visited_csv>
#                                # stdin: filtered output of one category
#                                # stdout: fully expanded (include: replaced with target's contents)
#                                # (implemented in Task 6)

if ! command -v log_info >/dev/null 2>&1; then
    echo "geo_parse.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

geo_filter_domain() {
    # Read from stdin, write to stdout.
    # Keep lines: domain:..., full:..., include:...
    # Drop: regexp:..., comments (#...), blank/whitespace-only lines.
    # Strip trailing @attr / #comment / whitespace from domain: and full: lines.
    awk '
        /^[[:space:]]*$/     { next }
        /^[[:space:]]*#/     { next }
        /^[[:space:]]*regexp:/ { next }
        /^[[:space:]]*include:/ {
            sub(/^[[:space:]]*/, "")
            sub(/[[:space:]].*/, "")
            print
            next
        }
        /^[[:space:]]*(domain|full):/ {
            sub(/^[[:space:]]*(domain|full):/, "")
            sub(/[[:space:]]+@.*$/, "")
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
            next
        }
    '
}
