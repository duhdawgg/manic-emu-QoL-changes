# manic-emu-QoL-changes

A stripped-down, performance-focused build of [Manic EMU](https://github.com/Manic-EMU/manicemu)
for three systems only:

| System | Core |
| --- | --- |
| Nintendo 3DS | Azahar (libretro) |
| Nintendo DS | melonDS DS (libretro) |
| Game Boy Advance, Game Boy Color, Game Boy | mGBA (libretro) |

Upstream Manic EMU is licensed AGPL-3.0, so this modified version is too.

## Where this code came from

- App: `Manic-EMU/manicemu` at commit `5840a80` ("Updated some resource files").
- Dependencies were git submodules upstream. They are copied in as plain folders here,
  so they can be edited and built without extra setup. Pinned commits:

| Folder | Source | Commit |
| --- | --- | --- |
| Dependencies/Libretro | Daiuno/RetroArch (manicemu branch) | d08135f |
| Dependencies/DeltaCore | Daiuno/DeltaCore (manicemu branch) | c232600 |
| Dependencies/DeltaCore/External/ZIPFoundation | rileytestut/ZIPFoundation | 9ea4da9 |
| Dependencies/CollectionViewPagingLayout | Daiuno/CollectionViewPagingLayout | 9887f57 |
| Dependencies/DNSPageView | Daiuno/DNSPageView | 7d9ba12 |
| Dependencies/IceCream | Daiuno/IceCream | cf64427 |
| Dependencies/ProHUD | Daiuno/ProHUD | 453f20a |
| Dependencies/StikJIT | StephenDev0/StikJIT | 3623e72 |
| Dependencies/SwiftCloudDrive | Daiuno/SwiftCloudDrive | 84ef625 |

- Binary files (cores, skins, databases) were Git LFS files upstream. The ones needed for
  3DS, DS and GB/GBC/GBA were downloaded and checked against their upstream SHA-256
  hashes, then stored here as normal files (no LFS). Binaries for every other system
  were left out on purpose; the code that refers to them is removed in the cleanup step.

## Plan

1. Import the full source. ✅
2. Automatic unsigned IPA build (GitHub Actions). Put `[build]` in a commit message to build. ✅
3. Cleanup: remove every other system and core, run GB and GBC on mGBA, and update the UI
   to match (same art style, no leftover icons, menus or settings for removed systems).
4. Graphics:
   - 2×/3×/4× rendering that actually works and is remembered per game.
   - Per-game resolution settings.
   - Better texture filtering.
   - Shader caching and shader preloading (3DS).
5. Audio: fewer pops, crackles and dropouts during fast forward, for every core.
6. Pokémon Omega Ruby compatibility on Azahar.

## Findings so far

- 3DS (Azahar): the resolution setting is changed while a game runs but isn't saved for
  the next launch, so every boot falls back to 1×. Several settings in `System.core/Azahar.opt`
  use old Citra names the Azahar core doesn't recognise (for example
  `citra_use_hw_shader_cache` instead of `citra_use_disk_shader_cache`), so they do nothing.
- DS (melonDS DS): the iOS build has its OpenGL renderer turned off, and that renderer is the
  only one that can upscale. The app also sends the DeSmuME resolution setting, which
  melonDS DS ignores. DS upscaling needs the core rebuilt with OpenGL ES enabled.
- GBA/GBC/GB (mGBA): 2D systems have no internal resolution; sharpness comes from
  display filters.
