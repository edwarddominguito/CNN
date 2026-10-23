import 'dart:io';

import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../content/rice_grades.dart';
import '../models/prediction_history_entry.dart';
import '../services/rice_api_service.dart';
import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';

/// The list of past predictions, newest first.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final RiceApiService _apiService = RiceApiService();

  List<PredictionHistoryEntry> entries = [];
  Directory? photoFolder; // where this device keeps History photos, if anywhere
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadHistory();
    loadPhotoFolder();
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
  }

  /// Photos are an extra, so the list never waits for them: the rows show as
  /// soon as History loads, and the thumbnails once the folder is known.
  Future<void> loadPhotoFolder() async {
    final folder = await _apiService.photoFolder();
    if (!mounted) {
      return;
    }

    setState(() => photoFolder = folder);
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
          _HistoryItem(
            entry: entry,
            photo: RiceApiService.photoFile(photoFolder, entry.imagePath),
          ),
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
  final File? photo;

  const _HistoryItem({required this.entry, required this.photo});

  @override
  Widget build(BuildContext context) {
    final isError = entry.error != null;
    final photo = this.photo;

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
      onTap: isError || photo == null ? null : () => _openPhoto(context, entry, photo),
    );
  }
}

/// A History photo at thumbnail size, or a plain placeholder when this device
/// has none for the row: on the web, for an older row, or after the file was
/// removed.
class _Thumbnail extends StatelessWidget {
  final File? photo;

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

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        photo,
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        // Decoded small: a full camera photo for every row would hold tens of
        // megabytes in memory for no visible gain.
        cacheWidth: 160,
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );
  }
}

/// Opens [photo] on its own page, the way Guide topics open. A second tap that
/// lands while the page is still opening is ignored.
void _openPhoto(BuildContext context, PredictionHistoryEntry entry, File photo) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) {
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => AppNavScaffold(
        currentIndex: 2,
        title: gradeDisplayName(entry.predictedGrade),
        isSubPage: true,
        body: AppPage(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                photo,
                cacheWidth: 1080, // the same ceiling as the Scan preview
                errorBuilder: (context, error, stackTrace) => const AppEmptyState(
                  icon: Icons.broken_image_outlined,
                  title: 'Photo unavailable',
                  message: 'This photo is no longer on this device.',
                ),
              ),
            ),
            Text(
              '${entry.confidence.toStringAsFixed(2)}% confidence · ${_formatDate(entry.createdAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}
