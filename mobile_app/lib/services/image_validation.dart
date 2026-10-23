import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The formats the backend can decode. Training uses JPG and PNG
/// (backend/ml/image_preprocessing.py), and the upload route also accepts WebP.
const supportedImageTypes = {'.jpg', '.jpeg', '.png', '.webp'};
const maxImageBytes = 15 * 1024 * 1024;

/// Checks the app can make before spending an upload on an unusable file.
///
/// Returns null when the image is usable, or a short message to show the user.
/// These are early checks only: the backend still validates the image itself
/// and remains the final word on what it can process.
Future<String?> validateImage(String fileName, Uint8List bytes) async {
  if (bytes.isEmpty) {
    return 'This file is empty. Please select a valid image.';
  }
  if (bytes.length > maxImageBytes) {
    return 'This image is too large. Please use an image under 15 MB.';
  }

  // Some pickers return a file with no extension, so an unknown one is only a
  // failure when the name actually has one to judge.
  final dot = fileName.lastIndexOf('.');
  final type = dot == -1 ? '' : fileName.substring(dot).toLowerCase();
  if (type.isNotEmpty && !supportedImageTypes.contains(type)) {
    return 'Unsupported image format. Please use a JPG, PNG, or WebP image.';
  }

  // Decoding is the only honest way to know the bytes really are an image and
  // that it has a real width and height.
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        // A browser cannot read the size before decoding: on the web the
        // descriptor's width and height throw, so the frame is measured below.
        if (!kIsWeb && !_hasAllowedSize(descriptor.width, descriptor.height)) {
          return _tooManyPixels;
        }
        // A small decode checks readability without allocating a full camera
        // frame. The web always decodes in full and scales afterwards, so it
        // gains nothing from a target size and keeps the real one instead.
        final target = kIsWeb ? null : 512;
        final codec = await descriptor.instantiateCodec(targetWidth: target, targetHeight: target);
        try {
          if (codec.frameCount != 1) {
            return 'Animated images are not supported. Please select a single still image.';
          }
          final image = (await codec.getNextFrame()).image;
          try {
            if (kIsWeb && !_hasAllowedSize(image.width, image.height)) {
              return _tooManyPixels;
            }
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } catch (_) {
    // The details only matter while debugging; the user just needs another file.
    return 'Unable to read this image. Please select another photo.';
  }

  return null;
}

const _tooManyPixels = 'Please select an image with at most 25 million pixels.';

/// A real width and height, within the 25 million pixels the app accepts.
bool _hasAllowedSize(int width, int height) =>
    width >= 1 && height >= 1 && width * height <= 25000000;
