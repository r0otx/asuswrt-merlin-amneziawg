#!/bin/sh
# addon/lib/install.sh — install/uninstall orchestrator.
# Module 1: provides `install_run` and `uninstall_run` as thin wrappers around
#           hooks.sh + ui.sh + state.sh. Real tunnel lifecycle is in Module 2/3.

install_run() {
    log_info "install_run: registering hooks"
    hooks_register
    log_info "install_run: mounting webui"
    ui_mount
    log_info "install_run: migrating from v1 (stub in Module 1)"
    migrate_from_v1 || true
    log_info "install complete"
}

uninstall_run() {
    log_info "uninstall_run: backing up state (stub in Module 1)"
    backup_before_remove || true
    log_info "uninstall_run: unmounting webui"
    ui_unmount
    log_info "uninstall_run: unregistering hooks"
    hooks_unregister
    log_info "uninstall complete"
}
