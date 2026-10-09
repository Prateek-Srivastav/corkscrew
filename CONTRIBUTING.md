# Contributing to Corkscrew

Thanks for helping. Bug fixes, game compatibility reports, new launcher support and docs are all welcome.

## Before you start

- **Small fixes:** open a pull request directly.
- **Bigger changes** (a new launcher, a new graphics backend, changes to isolated bottles or the Wine patches): open an issue or a discussion first, so we can agree on the approach before you spend time on it.
- **Questions and "does game X work?"** go to [Discussions](https://github.com/Prateek-Srivastav/corkscrew/discussions), not Issues.
- **Security problems** go through private reporting; see [SECURITY.md](SECURITY.md). Don't open a public issue.

## What won't be accepted

These protect the project and its users, and aren't open for debate:

- **Anything that bypasses DRM, copy protection, license checks or anti-cheat**, or helps run pirated games. Corkscrew runs games you own through their normal stores and launchers.
- **Third-party binaries in the repository.** That includes anything from Apple's Game Porting Toolkit (D3DMetal), whose license doesn't allow redistribution. Components are downloaded at build time.
- **Unpinned downloads.** Every download in the build scripts is pinned by version and SHA-256 in `scripts/runtime-pins.env`.
- **Weakening isolated bottles** (the sandbox profile or prefix hardening) without a prior discussion.

## Setting up

Follow [Building](README.md#building) in the README.

If you only change `Packages/GameCore`, you don't need the Wine runtime. The tests build their own fake runtimes:

```bash
scripts/test.sh
```

To work on the app or run games, you need the full build (runtime, components and app).

## Making a change

- Keep each pull request to one change. Separate refactors from behavior changes.
- Add or update tests in `Packages/GameCore/Tests` for anything GameCore does. `scripts/test.sh` must pass; CI runs it on every pull request.
- Match the surrounding code: Swift 6 with strict concurrency, the same naming, and short comments that say *why*.
- Update the README when behavior changes: the **What works** and **Games tested** tables, and **Known issues**.
- **Wine patches** live in `scripts/build-runtime.sh` as Python edits of the extracted source. Keep them idempotent and make them fail loudly when upstream changes (see the existing `assert`s). The source is extracted once, so after changing a patch, delete `build/src/crossover-*` and rebuild the runtime.
- **New downloads** go in `scripts/runtime-pins.env` with their SHA-256, and their license goes in the README's credits table.

## Game compatibility reports

Use the **Game report** issue form. Include your Mac, macOS version, the graphics backend and settings, and what happened. A report that a game *doesn't* work is just as useful.

## Sign your commits (DCO)

Every commit must be signed off under the [Developer Certificate of Origin](https://developercertificate.org). The sign-off certifies that you wrote the change, or otherwise have the right to submit it under this project's license. Add it with `-s`:

```bash
git commit -s -m "Fix Retina mode for 32-bit games"
```

This adds a line with your name and email (from `git config user.name` and `user.email`):

```
Signed-off-by: Your Name <you@example.com>
```

Pull requests with unsigned commits can't be merged. To sign off commits you've already made, run `git rebase --signoff main`, then force-push your branch.

## License

Corkscrew is licensed under the [GNU General Public License v3.0 or later](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.
