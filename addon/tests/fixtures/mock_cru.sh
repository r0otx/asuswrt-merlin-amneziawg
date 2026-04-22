#!/bin/sh
# Mock cru (Merlin cron wrapper). Logs every call; always succeeds.
: "${MOCK_CRU_LOG:=${TMPDIR_TEST:-/tmp}/cru.log}"
printf '%s\n' "$*" >> "${MOCK_CRU_LOG}"
exit 0
