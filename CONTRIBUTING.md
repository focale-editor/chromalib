# Contributing to ChromaLib

Keep changes focused, document public behavior, and add tests for profile,
pixel-format, lifecycle, or source-preparation changes.

Run the standard checks before submitting a change:

```console
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
```

Rebuild Web assets when the C bridge, Little CMS version, or Emscripten version
changes:

```console
dart run tool/web_library_builder.dart
```

Do not commit `native/third_party/lcms2/`. Native builds fetch the pinned source
after checksum verification, while the package ships the resulting browser
module as Web-only assets.
