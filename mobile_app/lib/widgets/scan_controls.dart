import 'package:flutter/material.dart';

/// The buttons under the preview on the Scan screen: where the image comes
/// from, and the button that starts the classification.
///
/// Only built when the screen is idle, so the buttons never need a busy state.
class ScanControls extends StatelessWidget {
  final bool hasImage;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onClassify;

  const ScanControls({
    super.key,
    required this.hasImage,
    required this.onCamera,
    required this.onGallery,
    required this.onClassify,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onCamera,
                icon: const Icon(Icons.camera_alt_outlined, size: 20),
                // With an image on screen the same buttons replace it.
                label: Text(hasImage ? 'Retake' : 'Take Photo'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onGallery,
                icon: const Icon(Icons.photo_library_outlined, size: 20),
                label: Text(hasImage ? 'Choose Another' : 'Gallery'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: hasImage ? onClassify : null,
          child: const Text('Classify Rice'),
        ),
        if (!hasImage) ...[
          const SizedBox(height: 10),
          Text(
            'Add an image to enable classification.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
