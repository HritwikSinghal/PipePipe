---
name: pipepiped-rename
description: Fork renamed PipePipe+ -> PipePipeD; new package base and Nix/CI identifiers
metadata:
  type: project
---

The PipePipe fork was renamed from **PipePipe+** to **PipePipeD** on 2026-06-01.

- App label: `PipePipeD` / `PipePipeD Debug`
- New package base: `wtf.pipepiped` (release: `wtf.pipepiped.release` via additive `applicationId` override + `.release` suffix; debug: `wtf.pipepiped.debug`)
- Nix flake apps: `pipepiped-build`, `pipepiped-debug`, `pipepiped-install`
- Release tag pattern: `pipepiped-v*` (was `plus-v*`)
- GitHub Actions `versionName` suffix: `-pipepiped.<run>`

**Why:** "plus" naming was ambiguous and the fork now diverges enough to warrant its own identity.

**How to apply:** always use `wtf.pipepiped` and `pipepiped-*` identifiers; never reference the old `plus` naming. See [[upstream-v523-rebase-toolchain]] for how these identifiers are wired through the v5.2.3-beta build.
