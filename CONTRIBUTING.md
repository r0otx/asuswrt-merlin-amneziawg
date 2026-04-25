# Contributing to AmneziaWG (v2)

This is a v2 rewrite. v1 lives on tag `v1.1.6` / branch `legacy`. All v2 work
happens on **`v2-development`** until merged into `main`.

## TL;DR

```sh
git clone --branch v2-development \
    git@github.com:r0otx/asuswrt-merlin-amneziawg.git AmneziaGo
cd AmneziaGo
make test                           # 290 bats + 36 node, all green
make deploy ROUTER=admin@router.lan # build both arches + scp + opkg install
```

## Prerequisites

| Tool | Why | macOS | Debian/Ubuntu |
|---|---|---|---|
| Docker (with buildx) | cross-arch ipk build | `brew install --cask docker` | follow docker.com/install |
| `bats-core` | shell tests | `brew install bats-core` | `apt install bats` |
| `shellcheck` | lint | `brew install shellcheck` | `apt install shellcheck` |
| `yamllint` | CI workflow lint | `brew install yamllint` | `apt install yamllint` |
| `python3` | `lint_asp.py` (WebUI XSS check) | preinstalled | `apt install python3` |
| `node` ≥18 | WebUI tests (graceful skip otherwise) | `brew install node` | `apt install nodejs` |
| `shfmt` | optional formatter check | `brew install shfmt` | `snap install shfmt` |

## Common workflow

```sh
make test              # bats + node
make lint              # shellcheck + yamllint + lint_asp + go vet (advisory)
make build-all         # both arches via Docker buildx
make check-size        # ipk size budgets
make deploy ROUTER=... # build + scp + install on router
make undeploy ROUTER=... [PURGE=1]  # remove (preserve / wipe state)
```

## Branch + commit conventions

- **Always** branch from `v2-development`. `main` is reserved for v1 legacy.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) — enforced by `commitlint.config.js` in CI.
  - `feat(scope): ...`, `fix(scope): ...`, `docs: ...`, `test: ...`, `refactor(scope): ...`, `chore: ...`, `build(scope): ...`
  - Scopes used so far: `state`, `pbr`, `geo`, `metrics`, `dns`, `status`, `tunnel`, `watchdog`, `webui`, `install`, `amneziawg`, `changelog`, `m1` ... `m6`.
- One commit = one logical change. Use `git rebase -i` to clean up before PR.
- Do **not** add `Co-Authored-By: Claude` or similar tool-attribution trailers — see `feedback_no_claude_attribution` (project policy).

## Pull requests

```sh
git checkout -b feature/my-thing v2-development
# ... edits ...
git commit -m "feat(metrics): ..."
git push origin feature/my-thing
gh pr create --base v2-development
```

CI runs on PR (lint + bats + node + cross-arch build). All checks must be green before merge.

## Where things live

| Path | Purpose |
|---|---|
| `addon/lib/*.sh` | POSIX shell libs — sourced by `addon/amneziawg.sh` and bats tests. One responsibility per file (state, tunnel, watchdog, pbr, dns, firewall, status, geo, metrics, install, hooks, ui, log, iptables_chain, config, events, postup, postdown). |
| `addon/amneziawg.sh` | Main subcommand dispatcher (entrypoint). |
| `addon/tests/*.bats` | Backend tests with stateful mocks (`addon/tests/fixtures/`). |
| `addon/webui/` | ASP page + vanilla JS + CSS. |
| `addon/webui/tests/` | Node `--test` for client-side parser/validator/AWG.* helpers. |
| `addon/etc/amneziawg/` | Files installed into `/opt/etc/amneziawg/` on the router. |
| `build/` | Docker cross-build, ipk packaging, CI helpers. |
| `scripts/install-online.sh` | Production installer (downloads from GitHub Releases, verifies SHA256 + cosign signature). |
| `scripts/install-local.sh` | Dev installer (scp + opkg from local `dist/`). |
| `docs/superpowers/specs/` | Per-module design specs (M1 ... M6). |
| `docs/superpowers/plans/` | Per-module implementation plans. |

## Testing on a real router

You need:

- Asuswrt-Merlin firmware (≥ 384.15) with `am_addons` enabled and `jffs2_scripts=1`.
- Entware installed on USB (`amtm` → Install Entware).
- SSH access to the router.

Workflow:

```sh
# One-shot deploy (uses scripts/install-local.sh under the hood)
make deploy ROUTER=admin@192.168.1.1

# Iterate: edit code -> make deploy ROUTER=... -> test in WebUI
# WebUI: https://<router>/Advanced_AmneziaWG.asp

# When done
make undeploy ROUTER=admin@192.168.1.1                # keep state
make undeploy ROUTER=admin@192.168.1.1 PURGE=1        # wipe state
```

Diagnostics on the router:

```sh
tail /tmp/amneziawg.log
/jffs/addons/amneziawg/amneziawg.sh status
iptables -t mangle -S AMNEZIAWG
ipset list -n | grep awg
ip rule | grep -E 'prio (97|98|99)'
```

## Don't

- Don't push directly to `main` — that's v1 history.
- Don't bump `/VERSION` casually — that's a release action, do it in a dedicated `chore: bump VERSION` commit alongside the tag.
- Don't add files that increase `addon_all.ipk` by >100 KB without discussion (current 48 KB, cap 200 KB).
- Don't disable `--no-verify` on commits or `make lint` checks. Fix the underlying issue.
- Don't introduce `bashisms` (`[[ ]]`, `function foo()`, arrays, `local` outside test stubs) — target is busybox `/bin/sh` ash.
- Don't pin third-party URLs at random — `addon/etc/amneziawg/sources.env` lives at the centre of M5 fetch logic; coordinate any change.

## Questions / blockers

Open a draft PR or a GitHub Issue. Reference the relevant module spec
(`docs/superpowers/specs/2026-04-DD-module-N-*.md`) so reviewers have context.
