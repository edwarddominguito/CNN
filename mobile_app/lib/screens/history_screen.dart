import 'package:flutter/material.dart';

import '../app_colors.dart';
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
  }

  Future<void> clearHistory() async {
    await _apiService.clearHistory();
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
          onPressed: entries.isEmpty ? null : clearHistory,
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
        for (final entry in entries) _HistoryItem(entry: entry),
      ],
    );
  }
}

class _HistoryItem extends StatelessWidget {
  final PredictionHistoryEntry entry;

  const _HistoryItem({required this.entry});

  String _formatDate(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.month}/${date.day}/${date.year} $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final isError = entry.error != null;

    return AppTile(
      icon: isError ? Icons.error_outline : Icons.check_circle_outline,
      iconColor: isError ? kErrorText : kPrimaryGreen,
      background: isError ? kErrorSurface : kSurface,
      title: entry.predictedGrade,
      subtitle: isError
          ? entry.error!
          : '${entry.confidence.toStringAsFixed(2)}% confidence',
      trailing: Text(
        _formatDate(entry.createdAt),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
      ),
    );
  }
}
