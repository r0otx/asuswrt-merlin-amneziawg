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

Hook handlers (invoked by /jffs/scripts/* demarcated blocks):
  service_event EVENT TARGET
  firewall_start WAN_IF
  wan_event UNIT STATE
  services_start

Not-yet-implemented subcommands (Module 2/3/4):
  start, stop, restart, status, update_geo, mount_ui, watchdog
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

    service_event)  _not_implemented service_event ;;
    firewall_start) _not_implemented firewall_start ;;
    wan_event)      _not_implemented wan_event ;;
    services_start) _not_implemented services_start ;;

    start|stop|restart|status|update_geo|mount_ui|watchdog|check_update|update)
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
