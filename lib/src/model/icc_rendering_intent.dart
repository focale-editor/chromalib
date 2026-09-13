/// Selects how colours outside the destination gamut are handled.
enum IccRenderingIntent {
  /// Favours a visually coherent result across the complete source gamut.
  perceptual,

  /// Preserves in-gamut colorimetry relative to the destination white point.
  relativeColorimetric,

  /// Favours saturation over colorimetric accuracy.
  saturation,

  /// Preserves colorimetry relative to the profiles' measured illuminants.
  absoluteColorimetric,
}
