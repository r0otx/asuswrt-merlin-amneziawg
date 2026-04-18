# Root Makefile — orchestrates the whole v2 build.
# Upstream amneziawg-go's original Makefile is preserved as Makefile.upstream
# and invoked via `make -f Makefile.upstream amneziawg-go` when needed.

REPO_ROOT := $(shell pwd)
include build/versions.env
export

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN { FS=":.*##"; printf "Targets:\n" } \
	      /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: version
version: ## Render /VERSION into derived files
	./build/version.sh

.PHONY: lint
lint: ## Run lint.yml equivalents locally
	shellcheck -S style addon/amneziawg.sh addon/lib/*.sh addon/scripts/*.sh \
	           build/*.sh build/ci/*.sh scripts/*.sh
	shfmt -d -i 2 -ci addon/ build/ scripts/
	go vet ./...
	yamllint .github/workflows/

.PHONY: test
test: ## Run Go + bats tests
	go test -race ./...
	bats addon/tests/

.PHONY: daemon
daemon: ## Build amneziawg-go binary natively (upstream Makefile)
	$(MAKE) -f Makefile.upstream amneziawg-go

.PHONY: build-docker-aarch64
build-docker-aarch64: ## Build aarch64 ipks via Docker
	docker build --platform linux/arm64 \
	             -f build/docker/Dockerfile.aarch64 \
	             --build-arg SOURCE_DATE_EPOCH=$(shell git log -1 --format=%ct) \
	             -t amneziago-builder:aarch64 .
	docker run --rm \
	           -v "$(REPO_ROOT)/dist/aarch64:/out" \
	           amneziago-builder:aarch64

.PHONY: build-docker-armv7
build-docker-armv7: ## Build armv7sf ipks via Docker
	docker build --platform linux/arm/v7 \
	             -f build/docker/Dockerfile.armv7 \
	             --build-arg SOURCE_DATE_EPOCH=$(shell git log -1 --format=%ct) \
	             -t amneziago-builder:armv7 .
	docker run --rm \
	           -v "$(REPO_ROOT)/dist/armv7:/out" \
	           amneziago-builder:armv7

.PHONY: build-all
build-all: build-docker-aarch64 build-docker-armv7 ## Build all ipks for both arches

.PHONY: check-size
check-size: ## Verify size budgets
	./build/ci/check_size.sh

.PHONY: check-reproducible
check-reproducible: ## Verify double-build determinism
	./build/ci/check_reproducible.sh

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf dist/ build/cache/ amneziawg-go

.PHONY: clean-all
clean-all: clean ## Remove everything including Docker images
	docker image rm -f amneziago-builder:aarch64 amneziago-builder:armv7 2>/dev/null || true
