# Third-party notices

## AutostrongSharp (MIT)

re7mp's save re-signing (`src/save_resign.cpp` / `src/save_resign.hpp`: a save received from the other player is made to load on
your account) uses the layout of the "AutoStrong" save container that was found by **mi5hmash** in **AutostrongSharp**:

- Project: https://github.com/mi5hmash/AutostrongSharp
- Licence: MIT

re7mp's version is written again in C++ and needs no key (it copies the 8-byte account block from a save your own game wrote and
recomputes the Murmur3-32 signature at the end of the file). No AutostrongSharp code and none of its game keys are included. Because
the file layout was learned from AutostrongSharp, its licence text is given here in full, as the MIT licence asks for:

```
MIT License

Copyright (c) 2026 Michał Gębicki

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## coop-re7 / "Molded Together" by xXCroissantXx (MIT)

re7mp's door sync (`CFG.door` in `lua/re7mp.lua`, from build 9.40) and its loading gate (`CFG.busy`) are written again for re7mp's own
messages, notes and tests, **from the findings and the calls in the other developer's co-op mod** (RE7 co-op through REFramework, v0.50, commit
5520482 of their repository): the game's door states, the six-argument `requestAutoOpen`, `requestAutoClose`, `requestPush`, `unlockDoor`, the
rule that the game's own self-close is not sent as a close, the ownership of a door's self-close, and the loading flags
(`<IsSceneLoading>k__BackingField`, `RequestChapterJump`, `RequestPlayerChange`). Their code and notes are the source of those facts; the code here
is not a copy of theirs (other message format, other structure, other helpers, tests of its own). Later builds that bring over more of their
features (drawers, switches, interactions) are listed here too. Their repository is now at https://github.com/xXCroissantXx/Re7-MoldedTogether
(v0.52 at the time of writing; Kingkiller1195 is credited there as a developer of Molded Together, and the owner of this project works with its author).

- Project: https://github.com/xXCroissantXx/coop-re7
- Licence: MIT

```
MIT License

Copyright (c) 2026 xXCroissantXx

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## "Third Person Full Model Placeholders" by AfroJackX (Nexus Mods, Resident Evil 7 mod 86)

re7mp's installer (`src/installer.cpp`, from build 9.45) can set up AfroJackX's mod, **"Third Person Full Model Placeholders RT (2022)"**, for the other player's full
character models. The mod's own model, material and texture files (unchanged) are included in `modpack/third-person-full-models/`, with a `CREDITS.txt`, and (from build 10.13) packed unchanged into `re7mp.exe` itself (`modpack/third-person-full-models.zip`, made by `tools/pack_models.py`), so the exe installs them without a download. The mod's Permissions page (read 2026-11-14) says: asset use is allowed **without permission or credit** (credit is given here anyway); **not allowed:** uploading the file itself to other sites, use in anything sold (money, Steam Workshop or other platforms) or earning donation points, and converting the file to work on other games. re7mp is free, uses the assets only for Resident Evil 7 and ships them as assets inside its own folder, not as the author's archive. They must never be used for RE8 or any other game. If the exe carries no pack (an older exe, or a build made without it), the installer uses a `modpack` folder beside the exe, or the zip you downloaded yourself from the mod page.

- Page: https://www.nexusmods.com/residentevil7/mods/86 (please endorse it)
- Author: AfroJackX. The page says the models and textures come from the game's own RT / DX11 files, and credits Poppyadams for Joe's DX11 face texture (an XPS file), and alphaZomega and cheezeit for the descriptions it adapts.
- What the installer does with it: meshes and materials go under `natives\stm\coop` so your own first-person body is not replaced, textures stay at their own paths, and REFramework's Loose File Loader is switched on. Nothing in the files is modified.
- The setup follows the layout used by the Molded Together installer, which was tested with the same file.
