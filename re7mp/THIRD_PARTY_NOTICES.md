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
features (drawers, switches, interactions) are listed here too.

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
