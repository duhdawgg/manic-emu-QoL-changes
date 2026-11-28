# Manic EMU QoL build: handoff notes

A stripped-down, performance-focused fork of Manic EMU (iOS emulator, Swift + C/C++ cores).
Owner works from Windows + iPhone 17 Pro, **no Mac**: every build runs in GitHub Actions and
is sideloaded (SideStore / AltStore / Sideloadly). See `QOL.md` for provenance and the plan.

Working branch: `claude/setup` (`main` holds only the original README).

## Target lineup
| System | Core | Notes |
| --- | --- | --- |
| 3DS | Azahar (libretro) | Citra.framework stays linked but hidden: the app uses it for CIA import / title lookups even on Azahar |
| DS | melonDS DS (libretro) | DeSmuME removed |
| GBA, GBC, GB | mGBA | GB/GBC moved off Gambatte |

Core choices live in `GameType.supportCores` (`ManicEmu/ManicEmu/Sources/Tools/Extensions/GameTypeExtensions.swift`).
A game's `defaultCore` is an **index** into that list, so removed cores are left as `""` slots
(e.g. 3DS = `["", Azahar]`). Don't reorder these arrays.

## Building
- `.github/workflows/build-ipa.yml`: runs only when a commit message contains `[build]` (or
  manually). Runs on `xcode-27` (Manic uses iOS 27 SDK APIs: UIHinge, UISceneAccessory).
  Scheme `ManicEmuSideload`, unsigned, arm64. Publishes a prerelease `build-N` with the IPA.
- `.github/workflows/build-melonds.yml`: `[melonds]` in a commit message rebuilds
  `CoreSource/melonds-ds` (+ `CoreSource/melonDS`) and commits it to
  `Cores/melondsds.libretro.framework`. `[melonds-gl]` turns the OpenGL ES renderer on.
- Build results go to the `ci-logs` branch (`latest.txt`, `errors.txt`, `error-context.txt`,
  `build.log.gz`; melonDS in `melonds/`), so they can be read with plain git.
- Last good build: **build-12** (commit 576c11e). IPA verified: contains exactly the Azahar,
  melonDS DS and mGBA frameworks, byte-identical to `Cores/`.

## Gotchas already solved (don't undo)
- **R.swift on Xcode 26+:** when the R.swift plugin and the app both use RswiftResources, Xcode
  builds it for the Mac only, so the app can't import it. The sideload target no longer runs the
  plugin; CI generates `ManicEmu/ManicEmu/Resources/R.generated.swift` with rswift 7.8.0 and
  the target compiles it (the file is gitignored).
- `Package.resolved`: Daiuno/Device rewrote its history; pinned to `5f1e758` (additive change).
- `Cipher.swift` (public stub) was missing `CoverTranslate`; added as an empty key.
- Dependencies were submodules upstream (and gitignored); they're vendored here as plain folders.
  Nested `.gitignore` files hid 247 files, which were force-added; file lists match upstream exactly.
- Binaries were Git LFS upstream. Only the 3DS/DS/GB* ones were downloaded (SHA-256 checked);
  this repo stores them as normal files, no LFS.
- melonDS CI must copy `build/**/melondsds.libretro.framework/melondsds.libretro` (it once
  grabbed a 120 KB dependency dylib; now there are size/symbol/option checks).
- CMake 4 on runners needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.

## Done
- Full source import; CI IPA build; project trimmed to the three core frameworks + Citra.
- `System.swift`: only 3DS, DS, GBA, GBC, GB registered.
- Saved core that no longer ships falls back to the first available (`GlobalCoreSwitch`).
- 3DS: saved per-game resolution is passed to Azahar at boot (`citra_resolution_factor`);
  it used to be sent only at runtime, so every launch reset to 1x. Choices limited to 1x-4x.
- `System.core/Azahar.opt`: old Citra key names replaced with the names in the shipped core,
  keeping the values the core already used.

## Findings that drive the next work
- **DS upscaling:** melonDS DS's iOS build disables OpenGL, and only the GL renderer can
  upscale. The renderer targets desktop GL 3.1 (`#version 140`); iOS has GLES 3.0. Biggest
  blocker: `glColorMaski` (26 uses, not in ES 3.0); a likely route is
  `GL_EXT_shader_framebuffer_fetch` (Apple GPUs) to apply masks in the shader. Also needed:
  `glMapBuffer` → `glMapBufferRange`, `glBindFragDataLocation` → layout qualifiers, and the
  2D compositor shaders. The app also sends DeSmuME's resolution key for DS, which melonDS ignores.
- **3DS shaders:** disk shader cache (preloading) is already on by default. Background
  (async) shader compilation exists in Azahar's settings but isn't exposed through the
  libretro core: it needs an Azahar core rebuild (`Daiuno/azahar` fork exists).
- GBA/GBC/GB are 2D: no internal resolution, only display filters.

## To do (owner's priorities)
1. UI cleanup: remove icons, menus, settings and assets for removed systems/cores, keeping the art style.
2. DS upscaling (GLES port above), wired to per-game resolution.
3. Fast-forward audio: fewer pops, crackles and dropouts, for **every** core. Audio goes through
   the RetroArch fork in `Dependencies/Libretro` (iOS audio driver), so one fix should cover all.
4. Better texture filtering; async shader compilation (Azahar rebuild).
5. Pokémon Omega Ruby compatibility on Azahar.

## Working style the owner asked for
- No mistakes: verify everything you can (parse the project file, check file lists, inspect the IPA).
- Short progress notes every 5-10 minutes during long work.
- One feature per build, so failures are easy to pin down.
- Plain language and short answers; they're on a phone.
