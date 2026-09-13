# Third-party notices

## Little CMS 2.19.1

ChromaLib uses the unmodified Little CMS 2.19.1 source distribution under the
MIT License.

The native build hook downloads the official release archive into its shared
build cache, verifies this SHA-256 digest, and compiles it into the ChromaLib
code asset:

```text
bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8
```

`dart run chromalib:prepare_library` can install the same verified source for
offline builds. The downloaded source directory is ignored by Git and excluded
from the package archive published to pub.dev.

The browser module is compiled at release time from the same archive with the
pinned Emscripten release. The resulting WebAssembly binary contains Little
CMS and retains its MIT licensing terms.

Little CMS license:

```text
MIT License

Copyright (c) 2023 Marti Maria Saguer

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
