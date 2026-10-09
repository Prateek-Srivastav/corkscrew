# Releasing

A release has two parts:

- **The engine pack** (`runtime-*` releases): the Wine runtime, D3DMetal, DXMT and DXVK, built on the maintainer's Mac. The app downloads it on first launch. It only changes when the runtime or components change.
- **The app** (`v*` releases): `Corkscrew-<version>.dmg`, built by GitHub Actions from a tag. Each app version points at one engine pack (`EnginePackPin.swift`).

## A new engine pack

Needed when `scripts/build-runtime.sh`, `scripts/install-components.sh` or `scripts/runtime-pins.env` change.

1. Commit the script changes. The packaging script refuses uncommitted changes in `scripts/` and `tools/`, so the published build scripts match the runtime.
2. Build the runtime and components:

   ```bash
   scripts/build-runtime.sh
   ```

   ```bash
   scripts/install-components.sh ~/Downloads/Game_Porting_Toolkit_3.0.dmg
   ```

   The pack includes D3DMetal from this image: `scripts/runtime-pins.env` pins its SHA-256 (`GPTK_DMG_SHA256`), and packaging refuses D3DMetal staged from any other image. Apple's license allows redistributing it only for non-commercial purposes, with Apple's license and acknowledgements, which the pack carries in `LICENSES/apple-game-porting-toolkit/`.

3. Run the smoke test. All backends should pass:

   ```bash
   scripts/smoke.sh
   ```

4. Pack it. The release name is the Wine version plus a revision; bump the revision for every new pack of the same Wine version:

   ```bash
   scripts/package-engine.sh 26.3.0-2
   ```

   This writes `dist/runtime-<release>/` and updates `Packages/GameCore/Sources/GameCore/Engines/EnginePackPin.swift`.
5. Commit `EnginePackPin.swift`.
6. Publish the pack and its source. `package-engine.sh` prints the exact command; it's a pre-release, so the app release stays "Latest":

   ```bash
   gh release create runtime-26.3.0-2 --prerelease --title "Engine 26.3.0-2" --notes "…" dist/runtime-26.3.0-2/*.tar.* dist/runtime-26.3.0-2/SHA256SUMS
   ```

To check a pack before publishing it, serve `dist/runtime-<release>/` locally and install from there into a scratch folder:

```bash
python3 -m http.server 8765 --directory dist/runtime-26.3.0-2
```

```bash
Packages/GameCore/.build/debug/gamecore-cli runtime download --data /tmp/corkscrew-test --url http://127.0.0.1:8765/corkscrew-engine-26.3.0-2.tar.xz
```

The app takes the same override: `-EnginePackURL <url>`.

## A new app version

1. Set the version in `project.yml` (`CFBundleShortVersionString`, and bump `CFBundleVersion`). Commit and push.
2. Make sure the engine pack in `EnginePackPin.swift` is published; the build checks.
3. Tag and push the tag:

   ```bash
   git tag v0.3.0 && git push origin v0.3.0
   ```

4. The **Release** workflow builds the DMG and creates a draft release with it. Read the notes, try the DMG, then publish the draft.

To build the DMG locally instead: `scripts/make-dmg.sh` (with `CORKSCREW_TRY_DMG=1` while the engine pack isn't published yet).

The app is ad hoc signed, so users confirm it once with **Open Anyway**. Signing with a Developer ID and notarizing would remove that step; it needs an Apple Developer Program membership.
