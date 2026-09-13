# 📰 ChromaLib changelog

## v0.1.0

* Provide native and WebAssembly ICC transforms backed by Little CMS 2.19.1.
* Support embedded ICC, sRGB, Adobe RGB (1998), ProPhoto RGB, Gray Gamma 2.2,
  D50 XYZ, and D50 Lab profiles.
* Support integer, floating-point, alpha, HDR, and reusable transform buffers.
* Accelerate 8-bit built-in RGB, grayscale, and Lab destinations while
  retaining the floating path for out-of-gamut Lab input.
* Download and verify native sources during builds without publishing them.
