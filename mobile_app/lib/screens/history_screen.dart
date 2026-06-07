import 'package:flutter/material.dart';

import '../models/prediction_history_entry.dart';
import '../services/history_service.dart';
import '../widgets/app_nav_scaffold.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final HistoryService _historyService = HistoryService();
  late Future<List<PredictionHistoryEntry>> _entriesFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture = _historyService.getEntries();
  }

  Future<void> _clearHistory() async {
    await _historyService.clear();
    setState(() {
      _entriesFuture = _historyService.getEntries();
    });
  }

  void _reload() {
    setState(() {
      _entriesFuture = _historyService.getEntries();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 2,
      title: 'History',
      subtitle: 'Recent predictions and connection failures',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _reload,
        ),
        IconButton(
          tooltip: 'Clear History',
          icon: const Icon(Icons.delete_outline),
          onPressed: _clearHistory,
        ),
      ],
      body: FutureBuilder<List<PredictionHistoryEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final entries = snapshot.data ?? const [];
          if (entries.isEmpty) {
            return AppPage(
              children: [
                EmptyState(
                  icon: Icons.history_outlined,
                  title: 'No predictions yet',
                  message:
                      'Run a rice scan and the result will appear here automatically.',
                  actionLabel: 'Start Scan',
                  onAction: () => Navigator.pushNamed(context, '/scan'),
                ),
              ],
            );
          }

          final successful = entries
              .where((entry) => entry.error == null)
              .length;
          final failed = entries.length - successful;

          return AppPage(
            children: [
              AppResponsiveGrid(
                minItemWidth: 190,
                children: [
                  _HistorySummary(
                    icon: Icons.receipt_long_outlined,
                    label: 'Total',
                    value: entries.length.toString(),
                  ),
                  _HistorySummary(
                    icon: Icons.check_circle_outline,
                    label: 'Successful',
                    value: successful.toString(),
                  ),
                  _HistorySummary(
                    icon: Icons.error_outline,
                    label: 'Failed',
                    value: failed.toString(),
                  ),
                ],
              ),
              const AppSectionHeader(title: 'Recent Activity'),
              ...entries.map((entry) => _HistoryItem(entry: entry)),
            ],
          );
        },
      ),
    );
  }
}

class _HistorySummary extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _HistorySummary({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                Text(label, style: const TextStyle(color: Color(0xFF68736D))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  final PredictionHistoryEntry entry;

  const _HistoryItem({required this.entry});

  @override
  Widget build(BuildContext context) {
    final isError = entry.error != null;

    return AppCard(
      color: isError ? const Color(0xFFFFF8F7) : Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isError
                  ? const Color(0xFFFFDAD6)
                  : const Color(0xFFDDEFE6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: isError
                  ? const Color(0xFFB3261E)
                  : const Color(0xFF256D4F),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.predictedGrade,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                    Text(
                      _formatDate(entry.createdAt),
                      style: const TextStyle(
                        color: Color(0xFF68736D),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  isError
                      ? entry.error!
                      : '${entry.confidence.toStringAsFixed(2)}% confidence',
                  style: TextStyle(
                    color: isError
                        ? const Color(0xFFB3261E)
                        : const Color(0xFF536159),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.month}/${date.day}/${date.year} $hour:$minute';
  }
}
