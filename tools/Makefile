# tools/Makefile — wrapper that invokes upstream amneziawg-tools src/Makefile
# with the right cross-compile flags. Expects tools/fetch.sh to have run first.
#
# Upstream layout: wg.c compiles to binary named "wg", which we copy to "awg"
# (matching upstream's own install target behaviour).

SRC_DIR := $(CURDIR)/src
OUT_DIR ?= $(CURDIR)/../dist/$(ARCH)

.PHONY: all clean

all:
	@if [ ! -f $(SRC_DIR)/src/Makefile ] && [ ! -f $(SRC_DIR)/Makefile ]; then \
		echo "tools/src missing — run tools/fetch.sh first." >&2; \
		exit 1; \
	fi
	$(MAKE) -C $(SRC_DIR)/src \
	    CC="$(CC)" STRIP="$(STRIP)" \
	    CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS)"
	mkdir -p $(OUT_DIR)
	cp $(SRC_DIR)/src/wg $(OUT_DIR)/awg
	cp $(SRC_DIR)/src/wg-quick/linux.bash $(OUT_DIR)/awg-quick
	-$(STRIP) $(OUT_DIR)/awg
	chmod 755 $(OUT_DIR)/awg $(OUT_DIR)/awg-quick

clean:
	-$(MAKE) -C $(SRC_DIR)/src clean 2>/dev/null || true
	rm -f $(OUT_DIR)/awg $(OUT_DIR)/awg-quick
