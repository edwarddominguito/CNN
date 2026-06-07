import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../widgets/app_nav_scaffold.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 0,
      title: 'About',
      subtitle: 'Project configuration and commands',
      body: AppPage(
        children: [
          AppCard(
            color: const Color(0xFFEAF4EE),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Rice CNN Classifier',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'A Flutter app connected to a FastAPI backend for rice grade prediction.',
                  style: TextStyle(color: Color(0xFF536159), height: 1.45),
                ),
              ],
            ),
          ),
          AppResponsiveGrid(
            children: [
              _InfoCard(
                icon: Icons.link_outlined,
                title: 'Backend URL',
                value: ApiConfig.baseUrl,
              ),
              const _InfoCard(
                icon: Icons.memory_outlined,
                title: 'Model File',
                value: 'backend/model/rice_cnn_model.keras',
              ),
              const _InfoCard(
                icon: Icons.folder_outlined,
                title: 'Dataset Folder',
                value: 'backend/dataset',
              ),
            ],
          ),
          const AppSectionHeader(title: 'Useful Commands'),
          const AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CommandLine(command: 'python train_model.py'),
                Divider(height: 24),
                _CommandLine(
                  command:
                      'python -m uvicorn main:app --reload --host 127.0.0.1 --port 8000',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          SelectableText(
            value,
            style: const TextStyle(color: Color(0xFF536159)),
          ),
        ],
      ),
    );
  }
}

class _CommandLine extends StatelessWidget {
  final String command;

  const _CommandLine({required this.command});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.terminal, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(
            command,
            style: const TextStyle(
              color: Color(0xFF1E2722),
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}
