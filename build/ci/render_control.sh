#!/bin/sh
# build/ci/render_control.sh — substitutes @VERSION@, @ARCH@, @INSTALLED_SIZE@
# in a control.template, writing the resolved file.
#
# Usage: render_control.sh <template> <version> <arch> <installed_size> <out>

set -eu

TEMPLATE="$1"
VERSION="$2"
ARCH="$3"
INSTALLED_SIZE="$4"
OUT="$5"

sed \
    -e "s|@VERSION@|${VERSION}|g" \
    -e "s|@ARCH@|${ARCH}|g" \
    -e "s|@INSTALLED_SIZE@|${INSTALLED_SIZE}|g" \
    "${TEMPLATE}" > "${OUT}"
