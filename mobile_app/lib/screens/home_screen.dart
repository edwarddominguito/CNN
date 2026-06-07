import 'package:flutter/material.dart';

import '../widgets/app_nav_scaffold.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 0,
      title: 'Rice Grader',
      subtitle: 'CNN rice quality classification',
      showBackToHome: false,
      body: AppPage(
        children: [
          AppCard(
            color: const Color(0xFFEAF4EE),
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 720;
                final intro = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rice Grade Classification',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: const Color(0xFF1E2722),
                          ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Scan rice samples, review prediction history, and monitor whether the FastAPI model server is ready.',
                      style: TextStyle(color: Color(0xFF536159), height: 1.45),
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: () =>
                              Navigator.pushNamed(context, '/scan'),
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Start Scan'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.pushNamed(context, '/dashboard'),
                          icon: const Icon(Icons.cloud_outlined),
                          label: const Text('Check Backend'),
                        ),
                      ],
                    ),
                  ],
                );

                final summary = AppResponsiveGrid(
                  minItemWidth: 150,
                  children: const [
                    _SummaryMetric(
                      icon: Icons.category_outlined,
                      label: 'Classes',
                      value: '4',
                    ),
                    _SummaryMetric(
                      icon: Icons.image_search_outlined,
                      label: 'Workflow',
                      value: 'Scan',
                    ),
                  ],
                );

                if (!isWide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [intro, const SizedBox(height: 20), summary],
                  );
                }

                return Row(
                  children: [
                    Expanded(flex: 3, child: intro),
                    const SizedBox(width: 24),
                    Expanded(flex: 2, child: summary),
                  ],
                );
              },
            ),
          ),
          AppSectionHeader(
            title: 'Quick Actions',
            actionLabel: 'Open guide',
            actionIcon: Icons.help_outline,
            onAction: () => Navigator.pushNamed(context, '/guide'),
          ),
          AppResponsiveGrid(
            children: const [
              _HomeTile(
                icon: Icons.camera_alt_outlined,
                title: 'Scan Rice',
                subtitle: 'Upload or capture a sample and run prediction.',
                route: '/scan',
              ),
              _HomeTile(
                icon: Icons.dashboard_outlined,
                title: 'Dashboard',
                subtitle: 'Check server status, model state, and metrics.',
                route: '/dashboard',
              ),
              _HomeTile(
                icon: Icons.history_outlined,
                title: 'History',
                subtitle: 'Review recent predictions and failures.',
                route: '/history',
              ),
              _HomeTile(
                icon: Icons.info_outline,
                title: 'About',
                subtitle: 'View backend URLs and project details.',
                route: '/about',
              ),
            ],
          ),
          AppCard(
            child: Row(
              children: [
                const Icon(Icons.tips_and_updates_outlined),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'For useful predictions, train with balanced photos in each class folder before using the app for final grading.',
                    style: TextStyle(color: Color(0xFF536159), height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SummaryMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD4E6DA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 14),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          Text(label, style: const TextStyle(color: Color(0xFF68736D))),
        ],
      ),
    );
  }
}

class _HomeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  const _HomeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.pushNamed(context, route),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF4EE),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF68736D),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
