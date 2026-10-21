# Third-party notices

AutoApply includes material adapted from the third-party projects listed below.

## career-ops

- Source: career-ops (github.com/career-ops-hq/career-ops)
- License: MIT
- Used in:
  - `engine/autoapply/liveness.py`: the closed-posting phrase list, the conditional-clause guard ("... until the position has been filled" is not a closure), the anti-bot guard, and the ATS API rules (a Lever API 404 is not authoritative; Ashby is checked at board level). Ported to Python from `liveness-core.mjs` and `liveness-api.mjs`.
  - `engine/autoapply/legitimacy.py`: the posting-legitimacy signal set (candidate-paid fees, an agency posting with no employer named, a repost pattern that needs a minimum span and title identity, JD vagueness). Adapted from `modes/oferta-signals/21-candidate-paid-fees.md`, `modes/oferta-signals/10-agency-licensing-check.md` and `detect-reposts.mjs`.

```
MIT License

Copyright (c) 2026 Santiago Fernández de Valderrama

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
