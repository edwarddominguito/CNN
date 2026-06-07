import 'package:flutter/material.dart';

import '../widgets/app_nav_scaffold.dart';

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 3,
      title: 'Guide',
      subtitle: 'Capture and dataset preparation tips',
      body: AppPage(
        children: const [
          AppSectionHeader(title: 'Photo Checklist'),
          AppResponsiveGrid(
            children: [
              _GuideCard(
                icon: Icons.wb_sunny_outlined,
                title: 'Lighting',
                text:
                    'Use bright, even light. Avoid hard shadows and colored lighting.',
              ),
              _GuideCard(
                icon: Icons.center_focus_strong_outlined,
                title: 'Framing',
                text:
                    'Fill most of the image with rice grains and keep the camera steady.',
              ),
              _GuideCard(
                icon: Icons.layers_clear_outlined,
                title: 'Background',
                text:
                    'Use a simple surface so the model learns rice quality, not table texture.',
              ),
              _GuideCard(
                icon: Icons.category_outlined,
                title: 'Classes',
                text:
                    'Keep each grade separated: Premium, Well-Milled, Regular-Milled, and Poor-Quality-Rice-Mix.',
              ),
            ],
          ),
          AppSectionHeader(title: 'Training Folder Plan'),
          _FolderPlan(),
        ],
      ),
    );
  }
}

class _GuideCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _GuideCard({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Color(0xFF256D4F)),
          SizedBox(height: 14),
          Text(title, style: TextStyle(fontWeight: FontWeight.w900)),
          SizedBox(height: 6),
          Text(text, style: TextStyle(color: Color(0xFF68736D), height: 1.4)),
        ],
      ),
    );
  }
}

class _FolderPlan extends StatelessWidget {
  const _FolderPlan();

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('train', 'Most images used for learning.'),
      ('validation', 'Images used to tune training while it runs.'),
      ('test', 'Images kept aside for final evaluation.'),
    ];

    return AppCard(
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            _FolderRow(folder: rows[index].$1, description: rows[index].$2),
            if (index != rows.length - 1) const Divider(height: 24),
          ],
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final String folder;
  final String description;

  const _FolderRow({required this.folder, required this.description});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF4EE),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            folder,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            description,
            style: const TextStyle(color: Color(0xFF536159), height: 1.4),
          ),
        ),
      ],
    );
  }
}
