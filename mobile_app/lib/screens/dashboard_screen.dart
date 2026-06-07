import 'package:flutter/material.dart';

import '../services/rice_api_service.dart';
import '../widgets/app_nav_scaffold.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final RiceApiService _apiService = RiceApiService();
  late Future<_DashboardData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_DashboardData> _loadData() async {
    final isOnline = await _apiService.checkBackendStatus();
    final metrics = isOnline
        ? await _apiService.getMetrics()
        : <String, dynamic>{};
    return _DashboardData(isOnline: isOnline, metrics: metrics);
  }

  void _refresh() {
    setState(() {
      _dataFuture = _loadData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 4,
      title: 'Dashboard',
      subtitle: 'Backend status, model state, and metrics',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _refresh,
        ),
      ],
      body: FutureBuilder<_DashboardData>(
        future: _dataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final data =
              snapshot.data ??
              const _DashboardData(isOnline: false, metrics: {});
          return AppPage(
            children: [
              _StatusCard(isOnline: data.isOnline, metrics: data.metrics),
              AppResponsiveGrid(
                minItemWidth: 210,
                children: [
                  _MetricCard(
                    label: 'Accuracy',
                    value: _value(data.metrics, 'accuracy'),
                  ),
                  _MetricCard(
                    label: 'Precision',
                    value: _value(data.metrics, 'precision'),
                  ),
                  _MetricCard(
                    label: 'Recall',
                    value: _value(data.metrics, 'recall'),
                  ),
                  _MetricCard(
                    label: 'F1 Score',
                    value: _value(data.metrics, 'f1_score'),
                  ),
                ],
              ),
              _ClassList(metrics: data.metrics),
            ],
          );
        },
      ),
    );
  }

  String _value(Map<String, dynamic> metrics, String key) {
    final value = metrics[key];
    if (value == null) return 'N/A';
    if (value is num) return value.toStringAsFixed(2);
    return value.toString();
  }
}

class _StatusCard extends StatelessWidget {
  final bool isOnline;
  final Map<String, dynamic> metrics;

  const _StatusCard({required this.isOnline, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final modelAvailable = metrics['model_available'] == true;
    final message = metrics['message']?.toString();

    return AppCard(
      color: isOnline ? const Color(0xFFEAF4EE) : const Color(0xFFFFF5F4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 700;
          final status = Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isOnline
                      ? const Color(0xFFDDEFE6)
                      : const Color(0xFFFFDAD6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isOnline ? Icons.cloud_done : Icons.cloud_off,
                  color: isOnline
                      ? const Color(0xFF256D4F)
                      : const Color(0xFFB3261E),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOnline ? 'Backend Connected' : 'Backend Offline',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isOnline
                          ? 'FastAPI is reachable on port 8000.'
                          : 'Start FastAPI before scanning rice images.',
                      style: const TextStyle(color: Color(0xFF536159)),
                    ),
                  ],
                ),
              ),
            ],
          );

          final model = _ModelBadge(
            label: modelAvailable ? 'Trained model loaded' : 'Demo mode',
            icon: modelAvailable ? Icons.model_training : Icons.warning_amber,
            color: modelAvailable
                ? const Color(0xFF256D4F)
                : const Color(0xFF8A6500),
          );

          if (!isWide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                status,
                const SizedBox(height: 14),
                model,
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    message,
                    style: const TextStyle(color: Color(0xFF536159)),
                  ),
                ],
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: status),
              const SizedBox(width: 18),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  model,
                  if (message != null) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: 320,
                      child: Text(
                        message,
                        textAlign: TextAlign.right,
                        style: const TextStyle(color: Color(0xFF536159)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ModelBadge extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _ModelBadge({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;

  const _MetricCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final hasValue = value != 'N/A';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasValue ? Icons.trending_up : Icons.remove_circle_outline,
                size: 18,
                color: hasValue
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFF68736D),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Color(0xFF68736D)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _ClassList extends StatelessWidget {
  final Map<String, dynamic> metrics;

  const _ClassList({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final rawClasses = metrics['classes'];
    final classes = rawClasses is List
        ? rawClasses.map((e) => e.toString()).toList()
        : <String>[];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Configured Classes',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          if (classes.isEmpty)
            const Text(
              'No class list available. Start the backend to load class names.',
              style: TextStyle(color: Color(0xFF68736D)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final className in classes)
                  Chip(
                    avatar: const Icon(Icons.label_outline, size: 18),
                    label: Text(className),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DashboardData {
  final bool isOnline;
  final Map<String, dynamic> metrics;

  const _DashboardData({required this.isOnline, required this.metrics});
}
