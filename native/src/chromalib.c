#include "chromalib.h"

#include "lcms2.h"

#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
  CHROMALIB_GRAY = 0,
  CHROMALIB_RGB = 1,
  CHROMALIB_CMYK = 2,
  CHROMALIB_LAB = 3,
  CHROMALIB_XYZ = 4,
};

enum {
  CHROMALIB_UINT8 = 0,
  CHROMALIB_UINT16 = 1,
  CHROMALIB_FLOAT32 = 2,
  CHROMALIB_FLOAT64 = 3,
};

struct chromalib_transform {
  cmsContext context;
  cmsHTRANSFORM transform;
  /* Exact component-layout conversion for identical source and destination
   * profiles. This avoids a lossy trip through Little CMS's Float32 pipeline. */
  int identity;
  /* Whether pixels are converted through the floating scratch buffers. 8-bit
   * RGB transforms between matrix-shaper profiles instead use Little CMS's
   * optimized 8-bit formatters, whose results match the floating pipeline
   * within rounding. Other integer transforms stay floating because Little
   * CMS resamples them into lookup tables with visible interpolation error. */
  int floating;
  int source_color_space;
  int source_sample_type;
  size_t source_has_alpha;
  int source_premultiplied_alpha;
  int destination_color_space;
  int destination_sample_type;
  size_t destination_has_alpha;
  int destination_premultiplied_alpha;
  size_t source_channels;
  size_t destination_channels;
  size_t source_bytes_per_pixel;
  size_t destination_bytes_per_pixel;
  void* source_scratch;
  void* destination_scratch;
  size_t source_scratch_sample_bytes;
  size_t destination_scratch_sample_bytes;
  int source_scratch_is_double;
  int destination_scratch_is_double;
  size_t scratch_pixels;
  /* Straight-alpha copy of premultiplied 8-bit input. Little CMS 2.19.1
   * ignores PREMUL_SH in optimized 8-bit transforms, so the bridge handles
   * premultiplication itself. */
  uint8_t* integer_scratch;
  size_t integer_scratch_bytes;
  char error[512];
};

static void set_error(chromalib_transform* transform, const char* format, ...) {
  if (transform == NULL) {
    return;
  }
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(transform->error, sizeof(transform->error), format, arguments);
  va_end(arguments);
  transform->error[sizeof(transform->error) - 1] = '\0';
}

static void set_error_with_cause(chromalib_transform* transform,
                                 const char* message) {
  char cause[sizeof(transform->error)];
  memcpy(cause, transform->error, sizeof(cause));
  if (cause[0] == '\0') {
    set_error(transform, "%s.", message);
  } else {
    set_error(transform, "%s: %s", message, cause);
  }
}

static void cms_error_handler(cmsContext context, cmsUInt32Number code,
                              const char* text) {
  chromalib_transform* transform =
      (chromalib_transform*)cmsGetContextUserData(context);
  set_error(transform, "Little CMS error %u: %s", (unsigned int)code,
            text == NULL ? "unknown error" : text);
}

static size_t color_channels(int color_space) {
  switch (color_space) {
    case CHROMALIB_GRAY:
      return 1;
    case CHROMALIB_RGB:
    case CHROMALIB_LAB:
    case CHROMALIB_XYZ:
      return 3;
    case CHROMALIB_CMYK:
      return 4;
    default:
      return 0;
  }
}

static size_t sample_bytes(int sample_type) {
  switch (sample_type) {
    case CHROMALIB_UINT8:
      return 1;
    case CHROMALIB_UINT16:
      return 2;
    case CHROMALIB_FLOAT32:
      return 4;
    case CHROMALIB_FLOAT64:
      return 8;
    default:
      return 0;
  }
}

static cmsColorSpaceSignature color_signature(int color_space) {
  switch (color_space) {
    case CHROMALIB_GRAY:
      return cmsSigGrayData;
    case CHROMALIB_RGB:
      return cmsSigRgbData;
    case CHROMALIB_CMYK:
      return cmsSigCmykData;
    case CHROMALIB_LAB:
      return cmsSigLabData;
    case CHROMALIB_XYZ:
      return cmsSigXYZData;
    default:
      return (cmsColorSpaceSignature)0;
  }
}

static cmsUInt32Number floating_format(int color_space, int double_precision) {
  switch (color_space) {
    case CHROMALIB_GRAY:
      return double_precision ? TYPE_GRAY_DBL : TYPE_GRAY_FLT;
    case CHROMALIB_RGB:
      return double_precision ? TYPE_RGB_DBL : TYPE_RGB_FLT;
    case CHROMALIB_CMYK:
      return double_precision ? TYPE_CMYK_DBL : TYPE_CMYK_FLT;
    case CHROMALIB_LAB:
      return double_precision ? TYPE_Lab_DBL : TYPE_Lab_FLT;
    case CHROMALIB_XYZ:
      return double_precision ? TYPE_XYZ_DBL : TYPE_XYZ_FLT;
    default:
      return 0;
  }
}

static cmsUInt32Number integer_8_format(int color_space, int has_alpha) {
  switch (color_space) {
    case CHROMALIB_GRAY:
      return has_alpha ? TYPE_GRAYA_8 : TYPE_GRAY_8;
    case CHROMALIB_RGB:
      return has_alpha ? TYPE_RGBA_8 : TYPE_RGB_8;
    case CHROMALIB_LAB:
      /* Little CMS publishes ALab but accepts the same generic formatter with
       * the extra channel after Lab, which matches ChromaLib's alpha-last
       * contract. */
      return has_alpha ? TYPE_Lab_8 | EXTRA_SH(1) : TYPE_Lab_8;
    default:
      return 0;
  }
}

static int is_builtin_integer_profile(int kind) {
  return (kind >= 1 && kind <= 3) || kind == 5 || kind == 6;
}

static int is_builtin_integer_color_space(int color_space) {
  return color_space == CHROMALIB_GRAY || color_space == CHROMALIB_RGB ||
         color_space == CHROMALIB_LAB;
}

/* Tag precedence mirrors _cmsReadInputLUT and _cmsReadOutputLUT in Little CMS.
 * A profile may contain matrix/TRC tags and a higher-priority LUT at the same
 * time, so cmsIsMatrixShaper alone cannot identify the selected pipeline. */
static int uses_matrix_shaper_for_intent(cmsHPROFILE profile, int intent,
                                         int used_as_input) {
  static const cmsTagSignature input_float_tags[] = {
      cmsSigDToB0Tag, cmsSigDToB1Tag, cmsSigDToB2Tag, cmsSigDToB3Tag};
  static const cmsTagSignature input_classic_tags[] = {
      cmsSigAToB0Tag, cmsSigAToB1Tag, cmsSigAToB2Tag, cmsSigAToB1Tag};
  static const cmsTagSignature output_float_tags[] = {
      cmsSigBToD0Tag, cmsSigBToD1Tag, cmsSigBToD2Tag, cmsSigBToD3Tag};
  static const cmsTagSignature output_classic_tags[] = {
      cmsSigBToA0Tag, cmsSigBToA1Tag, cmsSigBToA2Tag, cmsSigBToA1Tag};
  const cmsTagSignature* float_tags =
      used_as_input ? input_float_tags : output_float_tags;
  const cmsTagSignature* classic_tags =
      used_as_input ? input_classic_tags : output_classic_tags;
  const cmsTagSignature fallback =
      used_as_input ? cmsSigAToB0Tag : cmsSigBToA0Tag;

  if (!cmsIsMatrixShaper(profile) || cmsIsTag(profile, float_tags[intent])) {
    return 0;
  }
  cmsTagSignature selected = classic_tags[intent];
  if (!cmsIsTag(profile, selected)) {
    selected = fallback;
  }
  return !cmsIsTag(profile, selected);
}

static cmsHPROFILE create_adobe_rgb(cmsContext context) {
  cmsCIExyY white_point = {0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries = {
      {0.6400, 0.3300, 1.0},
      {0.2100, 0.7100, 1.0},
      {0.1500, 0.0600, 1.0},
  };
  cmsToneCurve* curve = cmsBuildGamma(context, 2.19921875);
  if (curve == NULL) {
    return NULL;
  }
  cmsToneCurve* curves[3] = {curve, curve, curve};
  cmsHPROFILE profile =
      cmsCreateRGBProfileTHR(context, &white_point, &primaries, curves);
  cmsFreeToneCurve(curve);
  return profile;
}

static cmsHPROFILE create_prophoto_rgb(cmsContext context) {
  cmsCIExyY white_point = {0.3457, 0.3585, 1.0};
  cmsCIExyYTRIPLE primaries = {
      {0.7347, 0.2653, 1.0},
      {0.1596, 0.8404, 1.0},
      {0.0366, 0.0001, 1.0},
  };
  const cmsFloat64Number parameters[5] = {1.8, 1.0, 0.0, 0.0625,
                                           0.03125};
  cmsToneCurve* curve = cmsBuildParametricToneCurve(context, 4, parameters);
  if (curve == NULL) {
    return NULL;
  }
  cmsToneCurve* curves[3] = {curve, curve, curve};
  cmsHPROFILE profile =
      cmsCreateRGBProfileTHR(context, &white_point, &primaries, curves);
  cmsFreeToneCurve(curve);
  return profile;
}

static cmsHPROFILE create_gray_gamma22(cmsContext context) {
  cmsToneCurve* curve = cmsBuildGamma(context, 2.2);
  if (curve == NULL) {
    return NULL;
  }
  cmsHPROFILE profile =
      cmsCreateGrayProfileTHR(context, cmsD50_xyY(), curve);
  cmsFreeToneCurve(curve);
  return profile;
}

static cmsHPROFILE open_profile(cmsContext context, int kind,
                                const uint8_t* bytes, size_t length) {
  switch (kind) {
    case 0:
      if (bytes == NULL || length < 128 || length > UINT_MAX) {
        return NULL;
      }
      return cmsOpenProfileFromMemTHR(context, bytes, (cmsUInt32Number)length);
    case 1:
      return cmsCreate_sRGBProfileTHR(context);
    case 2:
      return create_adobe_rgb(context);
    case 3:
      return create_prophoto_rgb(context);
    case 4:
      return cmsCreateXYZProfileTHR(context);
    case 5:
      return cmsCreateLab4ProfileTHR(context, NULL);
    case 6:
      return create_gray_gamma22(context);
    default:
      return NULL;
  }
}

static int multiply_size(size_t first, size_t second, size_t* result) {
  if (first != 0 && second > SIZE_MAX / first) {
    return 0;
  }
  *result = first * second;
  return 1;
}

static double read_scalar(const uint8_t* bytes, int sample_type,
                          size_t sample_index) {
  switch (sample_type) {
    case CHROMALIB_UINT8:
      return bytes[sample_index] / 255.0;
    case CHROMALIB_UINT16: {
      const uint8_t* source = bytes + sample_index * 2;
      const uint16_t value =
          (uint16_t)(source[0] | (source[1] << 8));
      return value / 65535.0;
    }
    case CHROMALIB_FLOAT32: {
      const uint8_t* source = bytes + sample_index * 4;
      const uint32_t bits =
          (uint32_t)source[0] | ((uint32_t)source[1] << 8) |
          ((uint32_t)source[2] << 16) | ((uint32_t)source[3] << 24);
      float value;
      memcpy(&value, &bits, sizeof(value));
      return isfinite(value) ? value : 0.0;
    }
    case CHROMALIB_FLOAT64: {
      const uint8_t* source = bytes + sample_index * 8;
      const uint64_t bits =
          (uint64_t)source[0] | ((uint64_t)source[1] << 8) |
          ((uint64_t)source[2] << 16) | ((uint64_t)source[3] << 24) |
          ((uint64_t)source[4] << 32) | ((uint64_t)source[5] << 40) |
          ((uint64_t)source[6] << 48) | ((uint64_t)source[7] << 56);
      double value;
      memcpy(&value, &bits, sizeof(value));
      return isfinite(value) ? value : 0.0;
    }
    default:
      return 0.0;
  }
}

static double clamp_unit(double value) {
  if (!isfinite(value) || value <= 0.0) {
    return 0.0;
  }
  return value >= 1.0 ? 1.0 : value;
}

static void write_scalar(uint8_t* bytes, int sample_type, size_t sample_index,
                         double value) {
  switch (sample_type) {
    case CHROMALIB_UINT8: {
      const uint8_t encoded = (uint8_t)floor(clamp_unit(value) * 255.0 + 0.5);
      bytes[sample_index] = encoded;
      break;
    }
    case CHROMALIB_UINT16: {
      const uint16_t encoded =
          (uint16_t)floor(clamp_unit(value) * 65535.0 + 0.5);
      uint8_t* destination = bytes + sample_index * 2;
      destination[0] = (uint8_t)(encoded & 0xff);
      destination[1] = (uint8_t)(encoded >> 8);
      break;
    }
    case CHROMALIB_FLOAT32: {
      const float encoded = (float)(isfinite(value) ? value : 0.0);
      uint32_t bits;
      uint8_t* destination = bytes + sample_index * 4;
      memcpy(&bits, &encoded, sizeof(bits));
      destination[0] = (uint8_t)(bits & 0xff);
      destination[1] = (uint8_t)((bits >> 8) & 0xff);
      destination[2] = (uint8_t)((bits >> 16) & 0xff);
      destination[3] = (uint8_t)(bits >> 24);
      break;
    }
    case CHROMALIB_FLOAT64: {
      const double encoded = isfinite(value) ? value : 0.0;
      uint64_t bits;
      uint8_t* destination = bytes + sample_index * 8;
      memcpy(&bits, &encoded, sizeof(bits));
      destination[0] = (uint8_t)(bits & 0xff);
      destination[1] = (uint8_t)((bits >> 8) & 0xff);
      destination[2] = (uint8_t)((bits >> 16) & 0xff);
      destination[3] = (uint8_t)((bits >> 24) & 0xff);
      destination[4] = (uint8_t)((bits >> 32) & 0xff);
      destination[5] = (uint8_t)((bits >> 40) & 0xff);
      destination[6] = (uint8_t)((bits >> 48) & 0xff);
      destination[7] = (uint8_t)(bits >> 56);
      break;
    }
  }
}

static double to_lcms_value(double value, int color_space, size_t channel,
                            int sample_type) {
  if (color_space == CHROMALIB_CMYK) {
    return value * 100.0;
  }
  if (color_space == CHROMALIB_LAB && sample_type <= CHROMALIB_UINT16) {
    if (channel == 0) {
      return value * 100.0;
    }
    return value * 255.0 - 128.0;
  }
  if (color_space == CHROMALIB_XYZ && sample_type == CHROMALIB_UINT16) {
    return value * (65535.0 / 32768.0);
  }
  return value;
}

static double from_lcms_value(double value, int color_space, size_t channel,
                              int sample_type) {
  if (color_space == CHROMALIB_CMYK) {
    return value / 100.0;
  }
  if (color_space == CHROMALIB_LAB && sample_type <= CHROMALIB_UINT16) {
    if (channel == 0) {
      return value / 100.0;
    }
    return (value + 128.0) / 255.0;
  }
  if (color_space == CHROMALIB_XYZ && sample_type == CHROMALIB_UINT16) {
    return value * (32768.0 / 65535.0);
  }
  return value;
}

static void write_scratch_value(void* scratch, int double_precision,
                                size_t index, double value) {
  if (double_precision) {
    ((double*)scratch)[index] = value;
  } else {
    ((float*)scratch)[index] = (float)value;
  }
}

static double read_scratch_value(const void* scratch, int double_precision,
                                 size_t index) {
  return double_precision ? ((const double*)scratch)[index]
                          : ((const float*)scratch)[index];
}

static int ensure_scratch(chromalib_transform* transform, size_t pixel_count) {
  if (pixel_count <= transform->scratch_pixels) {
    return 1;
  }
  size_t source_values;
  size_t destination_values;
  if (!multiply_size(pixel_count, transform->source_channels, &source_values) ||
      !multiply_size(pixel_count, transform->destination_channels,
                     &destination_values)) {
    set_error(transform, "Transform scratch-buffer size overflow.");
    return 0;
  }
  size_t source_bytes;
  size_t destination_bytes;
  if (!multiply_size(source_values, transform->source_scratch_sample_bytes,
                     &source_bytes) ||
      !multiply_size(destination_values,
                     transform->destination_scratch_sample_bytes,
                     &destination_bytes)) {
    set_error(transform, "Transform scratch-buffer size overflow.");
    return 0;
  }
  void* source = realloc(transform->source_scratch, source_bytes);
  if (source == NULL) {
    set_error(transform, "Could not allocate the source transform buffer.");
    return 0;
  }
  transform->source_scratch = source;
  void* destination =
      realloc(transform->destination_scratch, destination_bytes);
  if (destination == NULL) {
    set_error(transform, "Could not allocate the destination transform buffer.");
    return 0;
  }
  transform->destination_scratch = destination;
  transform->scratch_pixels = pixel_count;
  return 1;
}

/* Built-ins share identity by kind. Embedded profiles share identity only when
 * their complete validated payloads are byte-for-byte equal. */
static int profiles_have_same_identity(
    int source_kind, const uint8_t* source_bytes, size_t source_length,
    int destination_kind, const uint8_t* destination_bytes,
    size_t destination_length) {
  if (source_kind != destination_kind) {
    return 0;
  }
  if (source_kind != 0) {
    return 1;
  }
  return source_bytes != NULL && destination_bytes != NULL &&
         source_length == destination_length &&
         memcmp(source_bytes, destination_bytes, source_length) == 0;
}

chromalib_transform* chromalib_transform_create(
    int source_profile_kind, const uint8_t* source_profile_bytes,
    size_t source_profile_length, int source_color_space,
    int source_sample_type, int source_has_alpha,
    int source_premultiplied_alpha, int destination_profile_kind,
    const uint8_t* destination_profile_bytes,
    size_t destination_profile_length, int destination_color_space,
    int destination_sample_type, int destination_has_alpha,
    int destination_premultiplied_alpha, int rendering_intent,
    int black_point_compensation, int reserved) {
  const int same_profile = profiles_have_same_identity(
      source_profile_kind, source_profile_bytes, source_profile_length,
      destination_profile_kind, destination_profile_bytes,
      destination_profile_length);
  chromalib_transform* result =
      (chromalib_transform*)calloc(1, sizeof(chromalib_transform));
  if (result == NULL) {
    return NULL;
  }
  result->source_color_space = source_color_space;
  result->source_sample_type = source_sample_type;
  result->source_has_alpha = source_has_alpha != 0;
  result->source_premultiplied_alpha = source_premultiplied_alpha != 0;
  result->destination_color_space = destination_color_space;
  result->destination_sample_type = destination_sample_type;
  result->destination_has_alpha = destination_has_alpha != 0;
  result->destination_premultiplied_alpha =
      destination_premultiplied_alpha != 0;
  result->source_channels = color_channels(source_color_space);
  result->destination_channels = color_channels(destination_color_space);
  result->source_scratch_is_double =
      source_sample_type == CHROMALIB_FLOAT64;
  result->destination_scratch_is_double =
      destination_sample_type == CHROMALIB_FLOAT64;
  result->source_scratch_sample_bytes =
      result->source_scratch_is_double ? sizeof(double) : sizeof(float);
  result->destination_scratch_sample_bytes =
      result->destination_scratch_is_double ? sizeof(double) : sizeof(float);
  const size_t source_sample_bytes = sample_bytes(source_sample_type);
  const size_t destination_sample_bytes = sample_bytes(destination_sample_type);
  if (result->source_channels == 0 || result->destination_channels == 0 ||
      source_sample_bytes == 0 || destination_sample_bytes == 0) {
    set_error(result, "Unsupported colour space or sample type.");
    return result;
  }
  if (result->source_has_alpha != result->destination_has_alpha ||
      (!result->source_has_alpha &&
       (result->source_premultiplied_alpha ||
        result->destination_premultiplied_alpha))) {
    set_error(result, "Source and destination alpha layouts are incompatible.");
    return result;
  }
  if ((source_color_space == CHROMALIB_XYZ &&
       source_sample_type == CHROMALIB_UINT8) ||
      (destination_color_space == CHROMALIB_XYZ &&
       destination_sample_type == CHROMALIB_UINT8)) {
    set_error(result, "XYZ pixels do not support an 8-bit representation.");
    return result;
  }
  if (!multiply_size(result->source_channels + result->source_has_alpha,
                     source_sample_bytes,
                     &result->source_bytes_per_pixel) ||
      !multiply_size(
          result->destination_channels + result->destination_has_alpha,
          destination_sample_bytes, &result->destination_bytes_per_pixel)) {
    set_error(result, "Pixel-format size overflow.");
    return result;
  }

  result->context = cmsCreateContext(NULL, result);
  if (result->context == NULL) {
    set_error(result, "Could not create a Little CMS context.");
    return result;
  }
  /* Reserved for compatible extensions of the bridge contract. */
  (void)reserved;
  cmsSetLogErrorHandlerTHR(result->context, cms_error_handler);
  cmsHPROFILE source_profile =
      open_profile(result->context, source_profile_kind, source_profile_bytes,
                   source_profile_length);
  cmsHPROFILE destination_profile = NULL;
  if (source_profile == NULL) {
    set_error_with_cause(result, "Could not open the source ICC profile");
  } else {
    result->error[0] = '\0';
    destination_profile = open_profile(
        result->context, destination_profile_kind, destination_profile_bytes,
        destination_profile_length);
    if (destination_profile == NULL) {
      set_error_with_cause(result,
                           "Could not open the destination ICC profile");
    }
  }
  if (source_profile == NULL || destination_profile == NULL) {
    /* The diagnostic has already been recorded. */
  } else if (cmsGetColorSpace(source_profile) !=
                 color_signature(source_color_space) ||
             cmsGetColorSpace(destination_profile) !=
                 color_signature(destination_color_space)) {
    set_error(result, "A profile does not match its pixel colour space.");
  } else if (rendering_intent < INTENT_PERCEPTUAL ||
             rendering_intent > INTENT_ABSOLUTE_COLORIMETRIC) {
    set_error(result, "Unsupported ICC rendering intent.");
  } else if (same_profile) {
    result->identity = 1;
  } else {
    cmsUInt32Number flags = 0;
    cmsUInt32Number source_format;
    cmsUInt32Number destination_format;
    if (black_point_compensation) {
      flags |= cmsFLAGS_BLACKPOINTCOMPENSATION;
    }
    const int optimized_rgb =
        source_color_space == CHROMALIB_RGB &&
        destination_color_space == CHROMALIB_RGB &&
        uses_matrix_shaper_for_intent(source_profile, rendering_intent, 1) &&
        uses_matrix_shaper_for_intent(destination_profile, rendering_intent,
                                      0);
    const int optimized_builtin =
        is_builtin_integer_profile(source_profile_kind) &&
        is_builtin_integer_profile(destination_profile_kind) &&
        is_builtin_integer_color_space(source_color_space) &&
        is_builtin_integer_color_space(destination_color_space) &&
        source_color_space != CHROMALIB_LAB;
    result->floating =
        !(source_sample_type == CHROMALIB_UINT8 &&
          destination_sample_type == CHROMALIB_UINT8 &&
          (optimized_rgb || optimized_builtin));
    if (result->floating) {
      /* Alpha is handled by the bridge; only colour components reach LCMS. */
      source_format = floating_format(
          source_color_space, result->source_scratch_is_double);
      destination_format = floating_format(
          destination_color_space, result->destination_scratch_is_double);
    } else {
      /* Premultiplied pixels are converted to straight alpha by the bridge. */
      source_format = integer_8_format(
          source_color_space, result->source_has_alpha);
      destination_format = integer_8_format(
          destination_color_space, result->destination_has_alpha);
      if (result->source_has_alpha) {
        flags |= cmsFLAGS_COPY_ALPHA;
      }
    }
    result->error[0] = '\0';
    result->transform = cmsCreateTransformTHR(
        result->context, source_profile, source_format, destination_profile,
        destination_format, (cmsUInt32Number)rendering_intent, flags);
    if (result->transform == NULL) {
      set_error_with_cause(result,
                           "Little CMS could not compile the transform");
    }
  }
  if (source_profile != NULL) {
    cmsCloseProfile(source_profile);
  }
  if (destination_profile != NULL) {
    cmsCloseProfile(destination_profile);
  }
  return result;
}

int chromalib_transform_is_valid(const chromalib_transform* transform) {
  return transform != NULL &&
         (transform->identity || transform->transform != NULL);
}

static int ensure_integer_scratch(chromalib_transform* transform,
                                  size_t pixel_count) {
  size_t bytes;
  if (!multiply_size(pixel_count, transform->source_bytes_per_pixel, &bytes)) {
    set_error(transform, "Transform scratch-buffer size overflow.");
    return 0;
  }
  if (bytes <= transform->integer_scratch_bytes) {
    return 1;
  }
  uint8_t* scratch = (uint8_t*)realloc(transform->integer_scratch, bytes);
  if (scratch == NULL) {
    set_error(transform, "Could not allocate the source transform buffer.");
    return 0;
  }
  transform->integer_scratch = scratch;
  transform->integer_scratch_bytes = bytes;
  return 1;
}

/* Divides premultiplied 8-bit process components by alpha. */
static void unpremultiply_8(const uint8_t* source, uint8_t* destination,
                            size_t pixel_count, size_t color_channels) {
  const size_t stride = color_channels + 1;
  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    const uint8_t* input = source + pixel * stride;
    uint8_t* output = destination + pixel * stride;
    const unsigned alpha = input[color_channels];
    for (size_t channel = 0; channel < color_channels; ++channel) {
      unsigned value = 0;
      if (alpha != 0) {
        value = (input[channel] * 255u + alpha / 2) / alpha;
        if (value > 255u) {
          value = 255u;
        }
      }
      output[channel] = (uint8_t)value;
    }
    output[color_channels] = (uint8_t)alpha;
  }
}

/* Multiplies straight 8-bit process components by alpha. */
static void premultiply_8(uint8_t* pixels, size_t pixel_count,
                          size_t color_channels) {
  const size_t stride = color_channels + 1;
  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    uint8_t* components = pixels + pixel * stride;
    const unsigned alpha = components[color_channels];
    if (alpha == 255u) {
      continue;
    }
    for (size_t channel = 0; channel < color_channels; ++channel) {
      components[channel] =
          (uint8_t)((components[channel] * alpha + 127u) / 255u);
    }
  }
}

static void apply_floating(chromalib_transform* transform,
                           const uint8_t* source, uint8_t* destination,
                           size_t pixel_count) {
  const size_t source_stride =
      transform->source_channels + transform->source_has_alpha;
  const size_t destination_stride =
      transform->destination_channels + transform->destination_has_alpha;
  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    double alpha = 1.0;
    if (transform->source_has_alpha) {
      alpha = clamp_unit(read_scalar(source, transform->source_sample_type,
                                     pixel * source_stride +
                                         transform->source_channels));
    }
    for (size_t channel = 0; channel < transform->source_channels; ++channel) {
      double value = read_scalar(source, transform->source_sample_type,
                                 pixel * source_stride + channel);
      if (transform->source_premultiplied_alpha) {
        value = alpha <= 0.0 ? 0.0 : value / alpha;
      }
      write_scratch_value(
          transform->source_scratch, transform->source_scratch_is_double,
          pixel * transform->source_channels + channel,
          to_lcms_value(value, transform->source_color_space, channel,
                        transform->source_sample_type));
    }
  }

  cmsDoTransform(transform->transform, transform->source_scratch,
                 transform->destination_scratch,
                 (cmsUInt32Number)pixel_count);

  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    double alpha = 1.0;
    if (transform->source_has_alpha) {
      alpha = clamp_unit(read_scalar(source, transform->source_sample_type,
                                     pixel * source_stride +
                                         transform->source_channels));
    }
    for (size_t channel = 0; channel < transform->destination_channels;
         ++channel) {
      double value = from_lcms_value(
          read_scratch_value(
              transform->destination_scratch,
              transform->destination_scratch_is_double,
              pixel * transform->destination_channels + channel),
          transform->destination_color_space, channel,
          transform->destination_sample_type);
      if (transform->destination_premultiplied_alpha) {
        /* Integer samples cannot carry extended range, so clamp before
         * premultiplying to keep every component within alpha. */
        if (transform->destination_sample_type <= CHROMALIB_UINT16) {
          value = clamp_unit(value);
        }
        value *= alpha;
      }
      write_scalar(destination, transform->destination_sample_type,
                   pixel * destination_stride + channel, value);
    }
    if (transform->destination_has_alpha) {
      write_scalar(destination, transform->destination_sample_type,
                   pixel * destination_stride +
                       transform->destination_channels,
                   alpha);
    }
  }
}

/* Converts storage, alpha, and physical component conventions without changing
 * colour values. Profiles have already been opened and validated as equal. */
static void apply_identity(const chromalib_transform* transform,
                           const uint8_t* source, uint8_t* destination,
                           size_t pixel_count) {
  const size_t source_stride =
      transform->source_channels + transform->source_has_alpha;
  const size_t destination_stride =
      transform->destination_channels + transform->destination_has_alpha;
  const int same_layout =
      transform->source_color_space == transform->destination_color_space &&
      transform->source_sample_type == transform->destination_sample_type &&
      transform->source_has_alpha == transform->destination_has_alpha &&
      transform->source_premultiplied_alpha ==
          transform->destination_premultiplied_alpha;
  if (same_layout) {
    memcpy(destination, source,
           pixel_count * transform->source_bytes_per_pixel);
    return;
  }

  for (size_t pixel = 0; pixel < pixel_count; ++pixel) {
    double alpha = 1.0;
    if (transform->source_has_alpha) {
      alpha = clamp_unit(read_scalar(source, transform->source_sample_type,
                                     pixel * source_stride +
                                         transform->source_channels));
    }
    for (size_t channel = 0; channel < transform->source_channels; ++channel) {
      double value = read_scalar(source, transform->source_sample_type,
                                 pixel * source_stride + channel);
      if (transform->source_premultiplied_alpha) {
        value = alpha <= 0.0 ? 0.0 : value / alpha;
      }
      value = to_lcms_value(value, transform->source_color_space, channel,
                            transform->source_sample_type);
      value = from_lcms_value(value, transform->destination_color_space,
                              channel,
                              transform->destination_sample_type);
      if (transform->destination_premultiplied_alpha) {
        if (transform->destination_sample_type <= CHROMALIB_UINT16) {
          value = clamp_unit(value);
        }
        value *= alpha;
      }
      write_scalar(destination, transform->destination_sample_type,
                   pixel * destination_stride + channel, value);
    }
    if (transform->destination_has_alpha) {
      write_scalar(destination, transform->destination_sample_type,
                   pixel * destination_stride +
                       transform->destination_channels,
                   alpha);
    }
  }
}

int chromalib_transform_apply(chromalib_transform* transform,
                              const uint8_t* input, size_t input_length,
                              uint8_t* output, size_t output_length,
                              size_t pixel_offset, size_t pixel_count) {
  if (!chromalib_transform_is_valid(transform) || input == NULL ||
      output == NULL) {
    set_error(transform, "Cannot apply an invalid ICC transform.");
    return 0;
  }
  size_t end_pixel;
  size_t required_input;
  size_t required_output;
  if (pixel_offset > SIZE_MAX - pixel_count) {
    set_error(transform, "Pixel range overflow.");
    return 0;
  }
  end_pixel = pixel_offset + pixel_count;
  if (!multiply_size(end_pixel, transform->source_bytes_per_pixel,
                     &required_input) ||
      !multiply_size(end_pixel, transform->destination_bytes_per_pixel,
                     &required_output) ||
      required_input > input_length || required_output > output_length ||
      pixel_count > UINT_MAX) {
    set_error(transform, "Pixel range exceeds an input or output buffer.");
    return 0;
  }
  if (pixel_count == 0) {
    return 1;
  }

  const uint8_t* source =
      input + pixel_offset * transform->source_bytes_per_pixel;
  uint8_t* destination =
      output + pixel_offset * transform->destination_bytes_per_pixel;
  if (transform->identity) {
    apply_identity(transform, source, destination, pixel_count);
  } else if (transform->floating) {
    if (!ensure_scratch(transform, pixel_count)) {
      return 0;
    }
    apply_floating(transform, source, destination, pixel_count);
  } else {
    if (transform->source_premultiplied_alpha) {
      if (!ensure_integer_scratch(transform, pixel_count)) {
        return 0;
      }
      unpremultiply_8(source, transform->integer_scratch, pixel_count,
                      transform->source_channels);
      source = transform->integer_scratch;
    }
    cmsDoTransform(transform->transform, source, destination,
                   (cmsUInt32Number)pixel_count);
    if (transform->destination_premultiplied_alpha) {
      premultiply_8(destination, pixel_count,
                    transform->destination_channels);
    }
  }
  transform->error[0] = '\0';
  return 1;
}

const char* chromalib_transform_error(const chromalib_transform* transform) {
  static const char invalid[] = "Invalid ChromaLib transform.";
  return transform == NULL ? invalid : transform->error;
}

void chromalib_transform_destroy(chromalib_transform* transform) {
  if (transform == NULL) {
    return;
  }
  if (transform->transform != NULL) {
    cmsDeleteTransform(transform->transform);
  }
  free(transform->source_scratch);
  free(transform->destination_scratch);
  free(transform->integer_scratch);
  if (transform->context != NULL) {
    cmsDeleteContext(transform->context);
  }
  free(transform);
}

_Static_assert(LCMS_VERSION >= 2100 && LCMS_VERSION <= 9999,
               "The version string expects a two-digit Little CMS minor.");

/* Built from constant expressions so concurrent callers never observe a
 * partially written buffer. The patch suffix is terminated early when zero. */
static const char chromalib_version_string[] = {
    'L', 'i', 't', 't', 'l', 'e', ' ', 'C', 'M', 'S', ' ',
    (char)('0' + LCMS_VERSION / 1000), '.',
    (char)('0' + (LCMS_VERSION / 100) % 10),
    (char)('0' + (LCMS_VERSION / 10) % 10),
    (char)(LCMS_VERSION % 10 == 0 ? '\0' : '.'),
    (char)('0' + LCMS_VERSION % 10), '\0'};

const char* chromalib_version(void) { return chromalib_version_string; }

uint32_t chromalib_abi_version(void) { return CHROMALIB_ABI_VERSION; }
