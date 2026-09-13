# Architecture

ChromaLib separates its public Dart contract, platform adapters, and colour
engine bridge.

`IccProfile`, `IccPixelFormat`, and `IccTransformOptions` validate the caller's
configuration. `IccTransform` owns one platform backend and supplies a
synchronous buffer conversion once platform initialization is complete.

On native platforms, Dart native assets resolve a small C API. The bridge opens
profiles in an isolated Little CMS context, selects an exact layout conversion
or compiles a colour transform, and converts bounded chunks of 65,536 pixels so
leaf FFI calls never block the VM for long.

When both endpoints contain the same built-in profile or byte-identical embedded
profiles, the bridge performs an exact component-layout conversion and does not
compile a Little CMS colour pipeline. It can change sample depth, alpha
premultiplication, and integer Lab or XYZ encoding while preserving the profile's
colour values. Identical layouts are copied byte for byte. This prevents an
identity operation from acquiring the rounding of Little CMS's floating engine.

Most conversions go through floating-point scratch buffers, with alpha handled
by the bridge. The scratch representation follows each endpoint, so 64-bit
buffers retain their declared layout at the bridge boundary. Little CMS itself
evaluates floating colour pipelines with 32-bit values; Float64 is therefore an
I/O representation rather than a promise of double-precision colour math. This
keeps alpha semantics and normalized CMYK values identical across sample
depths, and lets matrix transforms and v4 multi-process elements preserve
finite extended-range values for HDR buffers. A bounded ICC lookup table still
clips according to the range declared by that profile. Integer destinations
are clamped before premultiplication. Integer Lab and XYZ samples are decoded
to their physical component values only after premultiplied normalized storage
has been divided by alpha, and encoded before alpha is reapplied.

The built-in Gray Gamma 2.2 profile uses a D50 media white point and a 2.2
power-law tone curve. Applications can therefore convert editable grayscale
rasters through the same ICC engine without embedding a generated profile.

8-bit conversions from the built-in RGB and Gray Gamma 2.2 profiles into RGB,
gray, or Lab instead hand pixels to Little CMS's integer formatters. RGB
conversions also take that path when both profiles actually select matrix/TRC
tags for the requested intent. These formatters join curves and matrices into
an exact, table-driven transform about ten times faster than the floating path.
Premultiplied components are divided and multiplied by alpha in the bridge,
because Little CMS 2.19.1 ignores its premultiplied-alpha flag in optimized
paths. Lab input and profiles that select a higher-priority classic or floating
LUT stay on the floating path. The integer pipeline otherwise introduces
visible interpolation error in out-of-gamut Lab colours, 16-bit data, and
lookup-table transforms.

In a browser, the same C bridge and Little CMS sources are compiled with
Emscripten. The Dart adapter reuses source and destination buffers bounded to
65,536 pixels, copying one chunk at a time with `TypedArray.set` before each
transform call and bulk-copying its result back into Dart-owned memory. Peak
WebAssembly staging memory therefore does not grow with the image dimensions.
Element-wise access would cross the JavaScript boundary once per byte under
dart2wasm. The Emscripten ES module is loaded with
a dynamic `import()`, so applications need neither inline scripts nor evaluation
permissions, and the backend also initializes inside Web workers.

Little CMS source is a build input rather than a package payload. Native build
hooks use their shared cache; maintainers use a separate ignored cache when
producing browser assets. Both paths pin the upstream version, archive URL, and
SHA-256 digest in `tool/little_cms_downloader.dart`.

The Dart adapters map every public enum to an explicit bridge identifier and
verify an exported ABI version before calling the C API. A stale native asset or
WebAssembly module therefore fails initialization with a clear diagnostic.
