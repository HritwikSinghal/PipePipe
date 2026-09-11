## Long-Running Project

This project uses session-persistent tracking. At the start of every session:
1. Read `docs/progress.md` silently for a full catch-up -- do not ask the user to re-explain anything.
2. Do NOT automatically continue working -- wait for the user to indicate they want to proceed.
3. After each completed task, update `docs/progress.md` immediately (mark `[x]`, recount Status Summary, update date).
4. `docs/progress.md` is the primary task tracker. Use `tasks.md` only for ad-hoc items outside the long-running plan.
5. Whenever a change alters how this fork differs from upstream (a user-facing feature, a setting, or a build/packaging/release change), update the **"PipePipeD — changes from upstream"** section of `README.md` in the same change, and keep it in sync with `docs/progress.md`. Routine bug fixes and internal refactors that don't change fork behavior do not need a README entry.
