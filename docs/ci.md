---
id: "KAN0R9YJSz0Bmf"
slug: "DOCS-CI"
type: "guide"
version: "1.3"
path: "docs/ci.md"
title: "CI on Fly.io: brd-build"
summary: "CI on Fly.io: the brd-build app runs scripts/ci.sh once per deploy as its release command; setup, results and limits."
tags: ["ci", "fly.io", "brd-build"]
group: "operations"
language: "en"
audience: ["Operator", "developer", "agent"]
---

# CI on Fly.io: `brd-build`

GitHub Actions never assigned a runner to this repository: every run failed before any step ran,
with no logs, which is an account-level block. The suite now runs on Fly.io instead. Each
deploy of the Fly app **`brd-build`** builds the pinned toolchain image, then runs
`scripts/ci.sh` **once**, as the deploy's release command, on a temporary Machine. A failing job
fails the deploy.

```
git push ──► Fly GitHub integration ──► fly deploy (brd-build)
                                           │
                                           ├─ build fly/Dockerfile  (every pin from scripts/versions.env)
                                           ├─ release_command: scripts/ci.sh   ◄── one temporary Machine,
                                           │     performance-8x · 32 GB · 20 GB RAM disk, destroyed after;
                                           │     a non-zero exit stops the deploy
                                           └─ app Machine: fly/status.sh  (toolchain report, stops when idle)
```

Fly documents the release command as running "in a temporary Machine using the newly built image,
once per deploy attempt", where "a non-zero exit status from this command will stop the
deployment" ([configuration reference](https://docs.fly.io/reference/configuration)). That is
exactly a run-once CI machine.

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [Parity](parity.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [The files](#files)
- [The jobs](#jobs)
- [One-time setup (the Operator)](#one-time-setup-operator)
- [Reading a result](#reading-result)
- [Run it elsewhere](#run-elsewhere)
- [Limits](#limits)

<a id="files"></a>

## The files

| File | Role |
|---|---|
| [`scripts/ci.sh`](../scripts/ci.sh) | The suite: the jobs of the former workflow, run in sequence. Every job runs even after one fails, then a summary prints, and the exit status is the number of failed jobs. The same script runs on a laptop, in Docker and on Fly. |
| [`fly/Dockerfile`](../fly/Dockerfile) | The image: `ubuntu:24.04` plus `scripts/setup.sh ci` (every pin, Rust nightly + Miri, libFuzzer runtime, Python 3.12/3.13/3.14/3.14t, OTP + Elixir), the tree and its fetched dependencies. The toolchain layer is rebuilt only when a pin moves. |
| [`fly.toml`](../fly.toml) | App `brd-build`: the build, the release command and its Machine size, the RAM-disk size, and the status page service. |
| [`fly/status.sh`](../fly/status.sh) | The app Machine: a page that reports the image's toolchains and jobs. A deploy re-seeds an app scaled to zero, so one Machine is always kept; `auto_stop_machines` stops it when idle. |
| [`scripts/fly-build.sh`](../scripts/fly-build.sh) | Run it by hand: `setup`, `deploy`, or `run JOB…` on a one-off Machine. |
| [`.dockerignore`](../.dockerignore) | Keeps build outputs, caches and agent worktrees out of the build context. |

<a id="jobs"></a>

## The jobs

`scripts/ci.sh --list` prints them. They are the former workflow's jobs, plus the champ oracle and
`ex/`:

| Job | Runs |
|---|---|
| `oracle` | Oracle and champ-oracle self-tests, the parity harness self-test, vectors reproducible from the oracle, the shell CLI suite. |
| `go` | vet, tests, race and fuzz smoke on Go 1.26.9; vet and tests on the 1.22.12 floor. |
| `native` | C cores (tests, gates, sanitizers), the Rust workspace (tests, clippy, alloc-check), the NIF link check. |
| `harden` | Miri (core, FFI, wasm ABI) and libFuzzer, 20 s per target. |
| `python` | pytest on CPython 3.12, 3.13, 3.14, and 3.14t with the GIL off. |
| `ts` | `npm ci`, typecheck, vitest on Node, `bun test` on Bun, a frozen-intrinsics smoke. |
| `ex` | echo_data: `--warnings-as-errors`, the suite with the NIF and pure, harden, the Hex package built alone. |
| `parity` | Every shim against the oracle, with `--require`, so a missing shim fails. |

**Pins:** the CI pins are no longer mirrored anywhere. The image reads
[`scripts/versions.env`](../scripts/versions.env) itself, so the old `PIN_*` drift check has
nothing left to compare.

<a id="one-time-setup-operator"></a>

## One-time setup (the Operator)

1. Install flyctl and log in: `fly auth login`.
2. Create the app and run the first deploy: `scripts/fly-build.sh setup`. It runs
   `fly apps create brd-build`, then `fly deploy --remote-only`. To choose the region, set
   `BRD_FLY_REGION`, or edit `primary_region` in `fly.toml`.
3. **Connect GitHub.** In the Fly dashboard, open `brd-build` → **Deployments** and connect the
   repository `jonny-novikov/brd14`. This installs Fly's GitHub App. Then, under Deployments →
   settings, turn on **auto-deploy** and choose the branch to watch.

   Fly announced this integration in October 2024 ([announcement](https://community.fly.io/t/auto-deploy-on-push-to-github/22306)).
   It watches one branch.
4. **Decline the Actions offer.** If `fly launch` offers to add a GitHub Actions workflow and a
   `FLY_API_TOKEN` secret, decline: Actions does not run on this account, which is why this file
   exists.

**Fallback trigger.** If the dashboard integration is unavailable to the account, any machine
with flyctl and a deploy token can run the same deploy:
- create the token with `fly tokens create deploy -a brd-build`;
- export it as `FLY_API_TOKEN`;
- run `scripts/fly-build.sh`, for example from a cron job or a `post-receive` hook on a mirror.

<a id="reading-result"></a>

## Reading a result

- **Pass or fail:** the deploy's status, in the dashboard's Deployments view or as the exit code
  of `fly deploy` / `scripts/fly-build.sh`.
- **The log:** `fly logs -a brd-build`. The release Machine prints a `════ ci: <job>` banner per
  job and a summary table at the end.
- **What the image is:** the app's URL serves the toolchain report from `fly/status.sh`.

<a id="run-elsewhere"></a>

## Run it elsewhere

- **On a provisioned machine:** `scripts/setup.sh ci && scripts/ci.sh [JOB…]`.
- **The Fly image, locally, through Docker:**
  ```bash
  docker build -f fly/Dockerfile -t brd-build:local .
  docker run --rm --privileged -e BRD_CI_TMPFS=20g brd-build:local scripts/ci.sh
  ```
  `--privileged` lets the script mount its RAM disk. Without it the suite runs in place.
- **Behind a TLS-intercepting proxy:** add `--secret id=proxy_ca,src=<ca.crt>` and
  `--build-arg HTTPS_PROXY=…` (plus `NO_PROXY`), and add `--network host` to both commands. Pass
  only the HTTPS proxy: such proxies typically refuse plain-HTTP requests, and apt reaches the
  Ubuntu archive directly.

<a id="limits"></a>

## Limits

| Limit | Consequence |
|---|---|
| **Root filesystem about 8 GB, slow to write.** Reported by the community ([thread](https://community.fly.io/t/is-it-possible-to-extend-the-root-volume-beyond-8gb/21055)); not in Fly's own docs. | `scripts/ci.sh` copies the tree into a RAM disk (`BRD_CI_TMPFS=20g`) before building. The release Machine therefore has 32 GB. |
| **Image at most 8 GB uncompressed** ([thread](https://community.fly.io/t/docker-image-size-limit-raised-from-2gb-to-8gb/14749)). | Measured: 6.04 GB uncompressed, 1.6 GB compressed (local `docker build`, Docker 29.8.2). That leaves about 25% headroom, so nothing goes in that the suite does not run; the `ci` tier leaves out PostgreSQL. |
| **Jobs run in sequence on one Machine**, where Actions ran them in parallel. | Wall time is the sum of the jobs. Measured once in local Docker (4 vCPUs, a 10 GB RAM disk, image at `940d391`), all green: oracle 12 s, go 89 s, native 44 s, harden 328 s, python 21 s, ts 20 s, ex 60 s, parity 40 s — 614 s in all. A performance-8x Machine has twice the CPUs; its time is not yet measured. |
| **The integration watches one branch.** | Other branches are run with `scripts/fly-build.sh`. |
| **The integration's maturity is not verified here.** This session has no Fly credentials. | The release-command semantics are documented; the push trigger is the Operator's step 3. |
| **Cost.** | Billed per second while the release Machine and the builder run. The status Machine is stopped when idle. |
