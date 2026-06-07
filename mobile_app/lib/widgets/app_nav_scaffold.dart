import 'package:flutter/material.dart';

class AppRoute {
  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const AppRoute({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });
}

const appRoutes = [
  AppRoute(
    path: '/',
    label: 'Home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
  ),
  AppRoute(
    path: '/scan',
    label: 'Scan',
    icon: Icons.camera_alt_outlined,
    selectedIcon: Icons.camera_alt,
  ),
  AppRoute(
    path: '/history',
    label: 'History',
    icon: Icons.history_outlined,
    selectedIcon: Icons.history,
  ),
  AppRoute(
    path: '/guide',
    label: 'Guide',
    icon: Icons.help_outline,
    selectedIcon: Icons.help,
  ),
  AppRoute(
    path: '/dashboard',
    label: 'Dashboard',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
  ),
];

class AppNavScaffold extends StatelessWidget {
  final int currentIndex;
  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget>? actions;
  final bool showBackToHome;

  const AppNavScaffold({
    super.key,
    required this.currentIndex,
    required this.title,
    this.subtitle,
    required this.body,
    this.actions,
    this.showBackToHome = true,
  });

  @override
  Widget build(BuildContext context) {
    final content = SafeArea(
      child: Column(
        children: [
          _TopBar(
            title: title,
            subtitle: subtitle,
            actions: actions,
            showBackToHome: showBackToHome && currentIndex != 0,
            onBack: () => _goTo(context, 0),
          ),
          Expanded(child: body),
        ],
      ),
    );

    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) => _goTo(context, index),
        destinations: [
          for (final route in appRoutes)
            NavigationDestination(
              icon: Icon(route.icon),
              selectedIcon: Icon(route.selectedIcon),
              label: route.label,
            ),
        ],
      ),
    );
  }

  void _goTo(BuildContext context, int index) {
    if (index == currentIndex) return;
    Navigator.pushNamedAndRemoveUntil(
      context,
      appRoutes[index].path,
      (route) => false,
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget>? actions;
  final bool showBackToHome;
  final VoidCallback onBack;

  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.showBackToHome,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8F6),
        border: Border(bottom: BorderSide(color: Color(0xFFE0E5DF))),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Row(
            children: [
              if (showBackToHome) ...[
                IconButton(
                  tooltip: 'Back to Home',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF1E2722),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF68736D),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (actions != null) ...actions!,
            ],
          ),
        ),
      ),
    );
  }
}

class AppPage extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  const AppPage({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: ListView.separated(
          padding: padding,
          itemBuilder: (context, index) => children[index],
          separatorBuilder: (context, index) => const SizedBox(height: 16),
          itemCount: children.length,
        ),
      ),
    );
  }
}

class AppResponsiveGrid extends StatelessWidget {
  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  final double runSpacing;

  const AppResponsiveGrid({
    super.key,
    required this.children,
    this.minItemWidth = 260,
    this.spacing = 16,
    this.runSpacing = 16,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / minItemWidth).floor().clamp(
          1,
          children.length,
        );
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth.toDouble(), child: child),
          ],
        );
      },
    );
  }
}

class AppSectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  const AppSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
        ),
        if (actionLabel != null && onAction != null)
          TextButton.icon(
            onPressed: onAction,
            icon: Icon(actionIcon ?? Icons.chevron_right, size: 18),
            label: Text(actionLabel!),
          ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF68736D), height: 1.4),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5DF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }
}
