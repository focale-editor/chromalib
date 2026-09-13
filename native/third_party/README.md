# Native third-party sources

This directory is kept in the package so ChromaLib's build hook can watch it.

Run `dart run chromalib:prepare_library` to install the pinned Little CMS
source into this ignored `lcms2/` subdirectory before an offline native build.
