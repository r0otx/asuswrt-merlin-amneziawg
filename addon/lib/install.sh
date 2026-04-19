#!/bin/sh
# addon/lib/install.sh — install/uninstall orchestrator.

# shellcheck disable=SC2317  # exit 1 is reachable when not sourced (return fails)
if ! command -v log_info       >/dev/null 2>&1; then echo "install.sh: log.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v hooks_register >/dev/null 2>&1; then echo "install.sh: hooks.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v ui_mount       >/dev/null 2>&1; then echo "install.sh: ui.sh first" >&2; return 1 2>/dev/null || exit 1; fi

_CRON_ID="amneziawg_watchdog"
_CRON_SPEC="* * * * * /jffs/addons/amneziawg/amneziawg.sh watchdog"

_install_cron() {
    cru a "${_CRON_ID}" "${_CRON_SPEC}" 2>/dev/null || log_warn "install: cru unavailable, cron not installed"
}

_uninstall_cron() {
    cru d "${_CRON_ID}" 2>/dev/null || true
}

install_run() {
    log_info "install_run: registering hooks"
    hooks_register
    log_info "install_run: mounting webui"
    ui_mount
    log_info "install_run: installing cron watchdog"
    _install_cron
    log_info "install_run: migrating from v1 (if present)"
    migrate_from_v1 || true
    log_info "install complete"
}

uninstall_run() {
    log_info "uninstall_run: backing up state"
    backup_before_remove || true
    log_info "uninstall_run: stopping tunnel"
    if command -v tunnel_stop >/dev/null 2>&1; then
        tunnel_stop || true
    fi
    log_info "uninstall_run: removing cron"
    _uninstall_cron
    log_info "uninstall_run: unmounting webui"
    ui_unmount
    log_info "uninstall_run: unregistering hooks"
    hooks_unregister
    log_info "uninstall complete"
}
