---
name: submitting-freebsd-port
description: QA validation and submission of a FreeBSD port to the official ports tree via Bugzilla
---

# Submitting a FreeBSD Port

This skill covers the quality assurance steps and submission process for contributing a new port (or port update) to the FreeBSD Ports Collection via Bugzilla.

**Reference:** [Porter's Handbook — Quick Porting](https://docs.freebsd.org/en/books/porters-handbook/quick-porting/)

## Prerequisites

- A working port directory with `Makefile`, `distinfo`, `pkg-descr`, and `pkg-plist` (or `PLIST_FILES`)
- The port builds and installs correctly
- A local or upstream copy of the FreeBSD ports tree to generate diffs against

## Step 1: Clean Build Test

Start from a clean state and verify the full build-stage-package cycle:

```sh
cd /path/to/ports/category/portname
make clean
make stage
make check-plist
```

All three must pass. `check-plist` verifies that every file installed during staging is accounted for in `pkg-plist`, and that `pkg-plist` doesn't reference files that weren't installed.

## Step 2: Run portclippy

```sh
portclippy Makefile
```

Must produce **no output** and exit 0. portclippy validates Makefile variable ordering per [Chapter 15](https://docs.freebsd.org/en/books/porters-handbook/order/) of the Porter's Handbook.

**Run portclippy before portlint** — fix ordering issues first.

## Step 3: Run portlint

```sh
portlint -A
```

Fix all **FATAL** errors. Common acceptable warnings:

| Warning | Reason |
|---------|--------|
| `possible use of absolute pathname` | Intentional for data/config directories |
| `Consider to set DEVELOPER=yes` | Local development suggestion, not a port issue |
| `PORTNAME has to be set by '='` | False positive for master/slave `?=` pattern |

## Step 4: QA Checklist

Review the port manually for these common issues:

### Makefile
- [ ] `COMMENT` does not start with "A ", "An ", or "The "
- [ ] `COMMENT` has no trailing whitespace or period
- [ ] `COMMENT` is a single line, under 70 characters
- [ ] `WWW` is a valid, reachable URL
- [ ] `LICENSE` matches upstream project license
- [ ] `LICENSE_FILE` points to the actual license file in `${WRKSRC}`
- [ ] `USE_GITHUB=yes` is present when using `GH_ACCOUNT` (not just `GH_ACCOUNT`/`GH_PROJECT` alone)
- [ ] `INSTALL_DATA` used for installing config/data files (not `${CP}`)
- [ ] `USES=go:` version is not expired in the current quarterly branch
- [ ] No `work/` directory committed to version control

### RC Script (if applicable)
- [ ] `PROVIDE`, `REQUIRE`, and `KEYWORD` are correct
- [ ] No copy-paste references to other projects in comments
- [ ] Variable defaults use the port's name, not another project's
- [ ] `pidfile`, `procname`, and `command_args` are correct
- [ ] `start_precmd` creates necessary runtime directories

### pkg-plist
- [ ] No trailing blank lines
- [ ] `@sample` annotation for config files
- [ ] `@dir` with `@owner`/`@group`/`@mode` for data directories
- [ ] Owner/group/mode reset after `@dir` block (`@mode`, `@group`, `@owner` on separate lines)

### pkg-descr
- [ ] 3-5 lines of factual description
- [ ] No marketing language or superlatives
- [ ] Describes what the software does, not how great it is

### UIDs/GIDs (if the port creates a user or group)
- [ ] Entries added to root-level `UIDs` and `GIDs` files in the ports tree
- [ ] UID/GID number doesn't conflict with existing entries
- [ ] These files are included in the submission diff

## Step 5: Generate the Diff

For a **new port**, generate a diff against the base ports tree:

```sh
# If working in a git-based ports tree fork:
git diff master -- category/portname UIDs GIDs > /tmp/portname.diff

# Or from a branch:
git diff master...branch-name -- category/portname UIDs GIDs > /tmp/portname.diff
```

For a **port update**:

```sh
git diff master...branch-name -- category/portname > /tmp/portname-update.diff
```

Verify the diff looks correct:

```sh
head -50 /tmp/portname.diff
```

## Step 6: Submit to Bugzilla

1. Go to https://bugs.freebsd.org/bugzilla/
2. Click **New Bug**
3. **Product:** Ports & Packages
4. **Component:** Individual Port(s)

### Title format

- New port: `category/portname: new port: Short Description X.Y.Z`
- Update: `category/portname: update to X.Y.Z`

### Description template

```
<One-line description of the software>

- Homepage: <URL>
- License: <LICENSE>
- Version: <version>
- Build tested: FreeBSD <version> <arch>
- portclippy: clean
- portlint -A: 0 fatals, N warnings (<list acceptable ones>)
- make stage && make check-plist: clean

<Optional: 2-3 sentences about what the software does>

Includes: <RC script | sample config | man page | etc.>
```

### Attach the diff

- Click **Add an attachment**
- Upload the `.diff` file
- Description: "port diff" or "new port diff"
- Content type: auto-detect (or text/plain)

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `COMMENT` starts with article | Rewrite to start with a noun or verb |
| Missing `USE_GITHUB=yes` | Add it when using `GH_ACCOUNT` |
| Using `${CP}` for config files | Use `${INSTALL_DATA}` |
| RC script references wrong project | Search for copy-paste artifacts |
| `go:1.22` with expired Go version | Check quarterly branch for available `lang/goXXX` |
| `work/` directory in diff | Run `make clean` before generating diff |
| pkg-plist trailing blank lines | Remove them — portlint will flag this |
| Config file without `@sample` | Add `@sample etc/myapp.conf.sample` to pkg-plist |
