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

geo_resolve_includes() {
    # Args: <src_dir> <max_depth> <visited_csv>
    # Stdin:  lines from geo_filter_domain (may contain include: directives)
    # Stdout: fully expanded (include: replaced with target's filtered+resolved contents)
    _src_dir="$1"; _max_depth="$2"; _visited="$3"
    [ -z "${_max_depth}" ] && _max_depth=3

    while IFS= read -r _line; do
        case "${_line}" in
            include:*)
                _target="${_line#include:}"
                _target="$(printf '%s' "${_target}" | tr -d ' \t')"
                # Cycle check
                case ",${_visited}," in
                    *",${_target},"*)
                        log_warn "geo_resolve_includes: cycle detected at ${_target} (visited=${_visited})"
                        continue
                        ;;
                esac
                # Depth check
                if [ "${_max_depth}" -le 0 ] 2>/dev/null; then
                    log_warn "geo_resolve_includes: depth cap hit at include:${_target}"
                    continue
                fi
                # Missing-file check
                if [ ! -f "${_src_dir}/${_target}" ]; then
                    log_warn "geo_resolve_includes: missing include target ${_src_dir}/${_target}"
                    continue
                fi
                # Recurse: filter the target and pipe into a recursive call with depth-1
                geo_filter_domain < "${_src_dir}/${_target}" | \
                    geo_resolve_includes "${_src_dir}" \
                        "$(( _max_depth - 1 ))" \
                        "${_visited},${_target}"
                ;;
            *)
                [ -n "${_line}" ] && printf '%s\n' "${_line}"
                ;;
        esac
    done
}
