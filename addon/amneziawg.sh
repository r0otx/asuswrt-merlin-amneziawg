#!/bin/sh
# addon/amneziawg.sh — AmneziaWG Merlin addon subcommand dispatcher.
# Real logic lives in addon/lib/*.sh; this script is a thin entry point.

AWG_VERSION="0.0.0-dev"
: "${AWG_ADDON_DIR:=/jffs/addons/amneziawg}"

# Source libs. Order matters: log.sh must be first (state/hooks/ui depend on it).
. "${AWG_ADDON_DIR}/lib/log.sh"
. "${AWG_ADDON_DIR}/lib/state.sh"
. "${AWG_ADDON_DIR}/lib/hooks.sh"
. "${AWG_ADDON_DIR}/lib/ui.sh"
. "${AWG_ADDON_DIR}/lib/config.sh"
. "${AWG_ADDON_DIR}/lib/tunnel.sh"
. "${AWG_ADDON_DIR}/lib/status.sh"
. "${AWG_ADDON_DIR}/lib/watchdog.sh"
. "${AWG_ADDON_DIR}/lib/events.sh"
. "${AWG_ADDON_DIR}/lib/install.sh"
. "${AWG_ADDON_DIR}/lib/firewall.sh"
. "${AWG_ADDON_DIR}/lib/pbr.sh"
. "${AWG_ADDON_DIR}/lib/geo.sh"

print_usage() {
    cat <<EOF
Usage: ${0##*/} <subcommand> [args]

Lifecycle:
  install           - register hooks + mount webui (used from .ipk postinst)
  uninstall         - reverse install (used from .ipk prerm)
  version           - print AWG_VERSION

Tunnel:
  start             - bring awg0 up
  stop              - bring awg0 down
  restart           - stop + start
  reload            - restart only if config changed
  status            - emit status JSON and print it
  watchdog          - one periodic tick (called from cron every 60s)
  import            - parse a .conf from stdin and persist into custom_settings

Hook handlers (invoked by /jffs/scripts/* demarcated blocks):
  service_event EVENT TARGET
  firewall_start WAN_IF
  wan_event UNIT STATE
  services_start

Not implemented yet (M5/v2.x):
  update_geo, check_update, update
EOF
}

_not_implemented() {
    log_warn "subcommand '$1' is not implemented in Module 1"
    return 0
}

cmd="${1:-help}"
shift 2>/dev/null || true

case "${cmd}" in
    install)        install_run ;;
    uninstall)      uninstall_run ;;
    version)        printf '%s\n' "${AWG_VERSION}" ;;

    service_event)  event_service "$@" ;;
    firewall_start) event_firewall "$@" ;;
    wan_event)      event_wan "$@" ;;
    services_start) event_services_start ;;

    start)          tunnel_start ;;
    stop)           tunnel_stop ;;
    restart)        tunnel_restart ;;
    reload)         tunnel_reload ;;
    status)         status_emit_json; cat "${AMNEZIAWG_RUNTIME:-/tmp/amneziawg}/status.json" ;;
    watchdog)       watchdog_tick ;;
    mount_ui)       ui_mount ;;

    import)         config_import_from_stdin ;;

    update_geo|check_update|update)
        _not_implemented "${cmd}"
        ;;

    help|-h|--help)
        print_usage
        ;;
    *)
        print_usage
        exit 64
        ;;
esac
