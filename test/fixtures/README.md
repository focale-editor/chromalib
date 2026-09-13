# ICC fixtures

srgb.icc is a compact sRGB profile used for public profile-loading tests.

hybrid_matrix_lut.icc is derived from the Little CMS 2.19.1 fuzzing corpus
profile alltags.icc. One malformed mAB channel-count byte was corrected so
Little CMS can compile its LUT. It deliberately contains both matrix/TRC and
LUT tags, which verifies that ChromaLib follows Little CMS tag precedence.
