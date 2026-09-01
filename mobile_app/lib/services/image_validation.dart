import 'dart:typed_data';
import 'dart:ui' as ui;

/// The formats the backend can decode. Training uses JPG and PNG
/// (backend/image_preprocessing.py), and the upload route also accepts WebP.
const supportedImageTypes = {'.jpg', '.jpeg', '.png', '.webp'};

/// Checks the app can make before spending an upload on an unusable file.
///
/// Returns null when the image is usable, or a short message to show the user.
/// These are early checks only: the backend still validates the image itself
/// and remains the final word on what it can process.
Future<String?> validateImage(String fileName, Uint8List bytes) async {
  if (bytes.isEmpty) {
    return 'This file is empty. Please select a valid image.';
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
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final width = frame.image.width;
    final height = frame.image.height;

    frame.image.dispose();
    codec.dispose();

    if (width == 0 || height == 0) {
      return 'Unable to read this image. Please select another photo.';
    }
  } catch (_) {
    // The details only matter while debugging; the user just needs another file.
    return 'Unable to read this image. Please select another photo.';
  }

  return null;
}
