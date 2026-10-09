# Security policy

Corkscrew runs Windows programs, and its isolated bottles are meant to contain programs you don't trust. Security reports matter here.

## Reporting a vulnerability

Report it privately through GitHub: go to the repository's **Security** tab, then **Report a vulnerability**. Don't open a public issue, discussion or pull request for it.

Please include:
- what an attacker can do, and under which conditions;
- steps or a proof of concept;
- your macOS version, Mac model, and Corkscrew version or commit.

This is a volunteer project, so there's no bug bounty. I'll aim to reply within 7 days, keep you updated, and credit you in the fix unless you'd rather not be named.

## Supported versions

Only the latest release and `main` get security fixes.

## In scope

- **Isolated bottles:** a program inside one that writes anything outside its bottle, reads your home folder, `/Users` or `/Volumes`, reaches the network while it's off, starts a program outside the runtime (directly, through LaunchServices or as a launchd job), or uses AppleEvents, the keychain or the clipboard.
- **Prefix hardening:** drive links or user folders that point outside the bottle after hardening, or a "Reset to clean" that keeps something it shouldn't.
- **`corkscrew://` links:** a web page or document using them to do more than launch or stop a game already in your library. A launch link needs the game's ID, a random UUID kept only in your library, and doesn't ask for confirmation: anything that can read your library already runs as you and could start the game itself.
- **Build and download integrity:** a way to get a component that doesn't match its pinned SHA-256 into a runtime, or into the components.
- **The Steam web helper wrapper**, and anything else in this repository that runs inside a bottle.

## Out of scope

- **Reading system files from an isolated bottle:** macOS and app files outside your home folder stay readable, by design.
- **Standard (non-isolated) bottles.** They aren't sandboxed by design: a program in one can do anything your user account can do.
- **Bugs in Wine, D3DMetal, DXMT, DXVK, MoltenVK or the games themselves.** Report those upstream, unless Corkscrew's configuration is what makes them exploitable.
- **Malware you chose to run in a standard bottle.**
