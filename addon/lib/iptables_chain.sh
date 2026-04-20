#!/bin/sh
# addon/lib/iptables_chain.sh — idempotent chain and rule primitives.
# Public API:
#   chain_ensure      <table> <chain>
#   chain_flush       <table> <chain>
#   chain_delete      <table> <chain>
#   rule_exists       <table> <chain> <args...>    (returns 0/1)
#   rule_add_if_missing <table> <chain> <args...>
#   rule_del_if_exists  <table> <chain> <args...>
#
# All use iptables per-op (low-cost idempotence). Bulk rule sets should use
# iptables-restore in the calling layer (pbr.sh, firewall.sh).

if ! command -v log_info >/dev/null 2>&1; then
    echo "iptables_chain.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

chain_ensure() {
    _t="$1"; _c="$2"
    iptables -t "${_t}" -N "${_c}" 2>/dev/null || true
}

chain_flush() {
    _t="$1"; _c="$2"
    iptables -t "${_t}" -F "${_c}" 2>/dev/null || true
}

chain_delete() {
    _t="$1"; _c="$2"
    iptables -t "${_t}" -F "${_c}" 2>/dev/null || true
    iptables -t "${_t}" -X "${_c}" 2>/dev/null || true
}

rule_exists() {
    _t="$1"; _c="$2"; shift 2
    iptables -t "${_t}" -C "${_c}" "$@" 2>/dev/null
}

rule_add_if_missing() {
    _t="$1"; _c="$2"; shift 2
    rule_exists "${_t}" "${_c}" "$@" && return 0
    iptables -t "${_t}" -A "${_c}" "$@"
}

rule_del_if_exists() {
    _t="$1"; _c="$2"; shift 2
    rule_exists "${_t}" "${_c}" "$@" || return 0
    iptables -t "${_t}" -D "${_c}" "$@"
}
