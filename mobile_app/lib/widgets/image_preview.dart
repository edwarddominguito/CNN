import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_colors.dart';

/// Shows the picked rice photo, or a placeholder inviting the user to pick one.
class ImagePreview extends StatelessWidget {
  final Uint8List? imageBytes;
  final String? imageName;

  const ImagePreview({super.key, required this.imageBytes, required this.imageName});

  /// Rice photos come off a phone camera at several thousand pixels wide. The
  /// preview is never wider than this, and decoding at full size would hold
  /// tens of megabytes in Flutter's image cache for no visible gain.
  static const _previewDecodeWidth = 1080;

  @override
  Widget build(BuildContext context) {
    final name = imageName;
    final bytes = imageBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 4:3 is the preferred height, not a maximum: placeholder text
              // that wraps on a narrow phone grows the box instead of
              // overflowing it.
              final preferredHeight = constraints.maxWidth * 3 / 4;

              return Container(
                width: double.infinity,
                constraints: BoxConstraints(minHeight: preferredHeight),
                decoration: BoxDecoration(
                  color: kSubtleSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kBorderColor),
                ),
                child: bytes == null
                    ? const _PreviewMessage(
                        icon: Icons.add_photo_alternate_outlined,
                        title: 'No sample loaded',
                        message: 'Use Camera or Gallery below to add a photo.',
                      )
                    : Image(
                        image: ResizeImage(
                          MemoryImage(bytes),
                          width: _previewDecodeWidth,
                          height: _previewDecodeWidth,
                          policy: ResizeImagePolicy.fit,
                        ),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: preferredHeight,
                        errorBuilder: (context, error, stackTrace) =>
                            const _PreviewMessage(
                          icon: Icons.broken_image_outlined,
                          title: 'Preview unavailable',
                          message: 'Use a JPG, PNG, or WebP image.',
                          color: kErrorText,
                        ),
                      ),
              );
            },
          ),
        ),
        if (name != null) ...[
          const SizedBox(height: 8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// The centred icon-and-text shown when there is no image to draw.
class _PreviewMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color color;

  const _PreviewMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.color = kMutedText,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: color),
            const SizedBox(height: 12),
            Text(title, style: textTheme.titleMedium?.copyWith(color: color)),
            const SizedBox(height: 4),
            Text(message, textAlign: TextAlign.center, style: textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
