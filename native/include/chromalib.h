#ifndef CHROMALIB_H
#define CHROMALIB_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define CHROMALIB_EXPORT __declspec(dllexport)
#else
#define CHROMALIB_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Incremented whenever the exported bridge contract changes incompatibly. */
#define CHROMALIB_ABI_VERSION 2

/* Opaque transform compiled from embedded or built-in profiles. Profile kinds:
 * 0 = embedded bytes, 1 = sRGB, 2 = Adobe RGB (1998), 3 = ProPhoto RGB,
 * 4 = D50 XYZ, 5 = D50 Lab, 6 = D50 Gray Gamma 2.2. Colour spaces:
 * 0 = gray, 1 = RGB, 2 = CMYK, 3 = Lab, 4 = XYZ. Sample types: 0 = uint8,
 * 1 = uint16, 2 = float32, 3 = float64. Floating RGB, gray, and CMYK values
 * use zero through one; floating Lab and XYZ use their standard physical
 * ranges. */
typedef struct chromalib_transform chromalib_transform;

CHROMALIB_EXPORT chromalib_transform* chromalib_transform_create(
    int source_profile_kind, const uint8_t* source_profile_bytes,
    size_t source_profile_length, int source_color_space,
    int source_sample_type, int source_has_alpha,
    int source_premultiplied_alpha, int destination_profile_kind,
    const uint8_t* destination_profile_bytes,
    size_t destination_profile_length, int destination_color_space,
    int destination_sample_type, int destination_has_alpha,
    int destination_premultiplied_alpha, int rendering_intent,
    int black_point_compensation, int reserved);
CHROMALIB_EXPORT int chromalib_transform_is_valid(
    const chromalib_transform* transform);
CHROMALIB_EXPORT int chromalib_transform_apply(
    chromalib_transform* transform, const uint8_t* input, size_t input_length,
    uint8_t* output, size_t output_length, size_t pixel_offset,
    size_t pixel_count);
CHROMALIB_EXPORT const char* chromalib_transform_error(
    const chromalib_transform* transform);
CHROMALIB_EXPORT void chromalib_transform_destroy(
    chromalib_transform* transform);
CHROMALIB_EXPORT uint32_t chromalib_abi_version(void);
CHROMALIB_EXPORT const char* chromalib_version(void);

#ifdef __cplusplus
}
#endif

#endif
