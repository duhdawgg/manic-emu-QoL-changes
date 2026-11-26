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
2. Automatic unsigned IPA build with GitHub Actions.
3. Remove every other system and core; run GB and GBC on mGBA.
4. Features: 2×/3×/4× rendering, per-game resolution, texture filtering,
   shader caching, cleaner audio during fast forward, Pokémon Omega Ruby fixes.
