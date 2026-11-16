import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../content/guide_content.dart';
import '../content/guide_topic.dart';
import '../content/rice_grades.dart';
import '../models/prediction_history_entry.dart';
import '../models/prediction_result.dart';
import '../services/rice_api_service.dart';
import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/guide_blocks.dart';
import '../widgets/prediction_result_card.dart';
import 'guide_topic_screen.dart';

/// The list of past predictions, newest first.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final RiceApiService _apiService = RiceApiService();

  List<PredictionHistoryEntry> entries = [];
  Map<String, ImageProvider> photos = {}; // the listed rows' kept photos, by name
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadHistory();
  }

  Future<void> loadHistory() async {
    setState(() {
      isLoading = true;
    });

    final loaded = await _apiService.getHistory();
    if (!mounted) {
      return;
    }

    setState(() {
      entries = loaded;
      isLoading = false;
    });
    loadPhotos(loaded);
  }

  /// Photos are an extra, so the list never waits for them: the rows show as
  /// soon as History loads, and the thumbnails once their photos are found.
  Future<void> loadPhotos(List<PredictionHistoryEntry> listed) async {
    final found = await _apiService.historyPhotos(listed);
    if (!mounted || listed != entries) {
      return; // Closed, or a newer load replaced the list meanwhile.
    }

    setState(() => photos = found);
  }

  Future<void> clearHistory() async {
    if (isLoading) return;
    setState(() => isLoading = true);
    final cleared = await _apiService.clearHistory();
    if (!mounted) {
      return; // History was closed while the clear was still running.
    }
    if (!cleared) {
      setState(() => isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not clear history. Check your connection and try again.'),
      ));
      return;
    }
    await loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 2,
      title: 'History',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: isLoading ? null : loadHistory,
        ),
        IconButton(
          tooltip: 'Clear history',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: isLoading || entries.isEmpty ? null : clearHistory,
        ),
      ],
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (entries.isEmpty) {
      return AppPage(
        children: [
          AppEmptyState(
            icon: Icons.history_outlined,
            title: 'No predictions yet',
            message: 'Run a scan and the result appears here automatically.',
            actionLabel: 'Start Scan',
            onAction: () => Navigator.pushNamed(context, '/scan'),
          ),
        ],
      );
    }

    final failed = entries.where((entry) => entry.error != null).length;

    return AppPage(
      children: [
        Text(
          failed == 0
              ? '${entries.length} saved'
              : '${entries.length} saved · $failed failed',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        for (final entry in entries)
          _HistoryItem(entry: entry, photo: photos[entry.imagePath]),
      ],
    );
  }
}

String _formatDate(DateTime date) {
  final local = date.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.month}/${local.day}/${local.year} $hour:$minute';
}

class _HistoryItem extends StatelessWidget {
  final PredictionHistoryEntry entry;

  /// The photo this prediction was made from, when this device kept it.
  final ImageProvider? photo;

  const _HistoryItem({required this.entry, required this.photo});

  @override
  Widget build(BuildContext context) {
    final isError = entry.error != null;

    return AppTile(
      // A failed scan keeps no photo, so it shows its error icon instead.
      icon: isError ? Icons.error_outline : null,
      iconColor: kErrorText,
      leading: isError ? null : _Thumbnail(photo: photo),
      background: isError ? kErrorSurface : kSurface,
      // Display only; the saved entry keeps the backend's exact label.
      title: gradeDisplayName(entry.predictedGrade),
      subtitle: isError
          ? entry.error!
          : '${entry.confidence.toStringAsFixed(2)}% confidence',
      trailing: Text(
        _formatDate(entry.createdAt),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
      ),
      // A failed scan has no result to review.
      onTap: isError ? null : () => _openPage(context, _ScanDetails(entry: entry, photo: photo)),
    );
  }
}

/// A History photo at thumbnail size, or a plain placeholder when this device
/// has none for the row: an older row, or one whose photo was removed. Tapping
/// the photo opens it full screen.
class _Thumbnail extends StatelessWidget {
  final ImageProvider? photo;

  const _Thumbnail({required this.photo});

  static const _size = 40.0;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: kSubtleSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.image_outlined, size: 20, color: kMutedText),
    );
    final photo = this.photo;
    if (photo == null) {
      return placeholder;
    }

    return Tooltip(
      message: 'View photo',
      child: GestureDetector(
        // The thumbnail opens the photo; the rest of the row opens the scan.
        onTap: () => _openPage(context, _PhotoViewer(photo: photo)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image(
            // Decoded small: a full camera photo for every row would hold tens
            // of megabytes in memory for no visible gain.
            image: ResizeImage(photo, width: 160),
            width: _size,
            height: _size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => placeholder,
          ),
        ),
      ),
    );
  }
}

/// Opens [page] over the current one, the way Guide topics open. A second tap
/// that lands while a page is still opening is ignored.
void _openPage(BuildContext context, Widget page) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) {
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => page));
}

/// One past scan to review: the photo beside the result card the Scan screen
/// showed for it, then the Guide's description of the predicted grade, so the
/// photo can be compared with what that grade may look like.
class _ScanDetails extends StatelessWidget {
  final PredictionHistoryEntry entry;
  final ImageProvider? photo;

  const _ScanDetails({required this.entry, required this.photo});

  @override
  Widget build(BuildContext context) {
    final grade = gradeForLabel(entry.predictedGrade);
    final photo = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LargePhoto(photo: this.photo),
        const SizedBox(height: 8),
        Text(
          'Scanned ${_formatDate(entry.createdAt)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PredictionResultCard(
          result: PredictionResult(
            predictedGrade: entry.predictedGrade,
            confidence: entry.confidence,
            note: entry.note,
          ),
        ),
        // Null for a label the app does not know, which then gets no description.
        if (grade != null)
          for (final block in [
            GuideHeading('About ${grade.displayName}'),
            ...gradeTopic(grade).blocks,
          ]) ...[
            const SizedBox(height: 12),
            GuideBlockView(block: block, onOpenTopic: (topic) => openGuideTopic(context, topic)),
          ],
      ],
    );

    return AppNavScaffold(
      currentIndex: 2,
      title: 'Scan Details',
      isSubPage: true,
      body: AppPage(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Side by side in a wide window, stacked on a phone, as on the
              // Scan screen.
              if (constraints.maxWidth < 860) {
                return Column(children: [photo, const SizedBox(height: 16), details]);
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: photo),
                  const SizedBox(width: 24),
                  Expanded(flex: 5, child: details),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The scan's photo in the Scan preview's 4:3 frame, shown whole so no part of
/// the sample is cropped away, or a short message when there is no photo.
/// Tapping the photo opens it full screen.
class _LargePhoto extends StatelessWidget {
  final ImageProvider? photo;

  const _LargePhoto({required this.photo});

  @override
  Widget build(BuildContext context) {
    final missing = Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, size: 28, color: kMutedText),
            const SizedBox(height: 8),
            Text(
              'No photo of this scan is kept on this device.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
    final photo = this.photo;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: kSubtleSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorderColor),
        ),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: photo == null
              ? missing
              : Tooltip(
                  message: 'View photo',
                  child: GestureDetector(
                    onTap: () => _openPage(context, _PhotoViewer(photo: photo)),
                    child: Image(
                      // The same decoding ceiling as the Scan preview.
                      image: ResizeImage(
                        photo,
                        width: 1080,
                        height: 1080,
                        policy: ResizeImagePolicy.fit,
                      ),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => missing,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// One scan's photo on a dark page, as large as it fits, to look at closely:
/// pinch or double-tap to zoom in, drag to move around. History thumbnails
/// and Scan Details both open this same page.
class _PhotoViewer extends StatefulWidget {
  final ImageProvider photo;

  const _PhotoViewer({required this.photo});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  /// The longest side the photo is decoded at. A common 12-megapixel phone
  /// photo (4032 x 3024) fits, so it shows pixel for pixel. A larger one, up to
  /// the 25 million pixels the Scan screen accepts, is reduced while decoding:
  /// at most 67 MB of memory instead of 100 MB.
  static const _largestSide = 4096;
  static const _doubleTapScale = 3.0;

  // Decoded only now that the photo is opened. History and Scan Details only
  // ever decode small copies of it.
  late final ImageProvider _fullPhoto = ResizeImage(
    widget.photo,
    width: _largestSide,
    height: _largestSide,
    policy: ResizeImagePolicy.fit,
  );
  final _zoom = TransformationController(); // how far the photo is zoomed and moved
  Offset _doubleTapPosition = Offset.zero;

  @override
  void dispose() {
    _zoom.dispose();
    // A decoded photo can take tens of megabytes, so it is released as soon as
    // the page closes instead of waiting in Flutter's image cache.
    _fullPhoto.evict();
    super.dispose();
  }

  /// True while the photo is shown larger than the whole-photo view. Pinching
  /// back out can stop a hair above 1.
  bool _isZoomedIn(Matrix4 zoom) => zoom.getMaxScaleOnAxis() > 1.01;

  void _fitToScreen() {
    _zoom.value = Matrix4.identity();
  }

  /// A double-tap zooms in on the tapped spot, or back out to the whole photo.
  void _toggleZoom() {
    if (_isZoomedIn(_zoom.value)) {
      _fitToScreen();
      return;
    }
    // Scaled up, then shifted so that the tapped spot stays where it was.
    final spot = _doubleTapPosition;
    _zoom.value = Matrix4.diagonal3Values(_doubleTapScale, _doubleTapScale, 1)
      ..setTranslationRaw(spot.dx * (1 - _doubleTapScale), spot.dy * (1 - _doubleTapScale), 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    color: Colors.white,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<Matrix4>(
                    valueListenable: _zoom,
                    // Only offered while the photo is zoomed in.
                    builder: (context, zoom, child) => _isZoomedIn(zoom)
                        ? IconButton(
                            tooltip: 'Fit to screen',
                            color: Colors.white,
                            icon: const Icon(Icons.fit_screen_outlined, size: 20),
                            onPressed: _fitToScreen,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 1, // never smaller than the whole photo
                  maxScale: 8,
                  child: Center(
                    child: Image(
                      image: _fullPhoto,
                      // Made smaller to fit when it is larger than the screen,
                      // otherwise shown at its own size: never stretched,
                      // cropped or enlarged. Only zooming in enlarges it.
                      fit: BoxFit.scaleDown,
                      // A large photo takes a moment to decode.
                      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                          frame == null ? const CircularProgressIndicator(color: Colors.white) : child,
                      // A missing, damaged or unreadable file.
                      errorBuilder: (context, error, stackTrace) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.broken_image_outlined, size: 28, color: Colors.white70),
                          const SizedBox(height: 8),
                          Text(
                            'Photo unavailable',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
