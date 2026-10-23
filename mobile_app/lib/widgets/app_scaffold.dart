import 'package:flutter/material.dart';

import '../app_colors.dart';

/// One tab of the bottom navigation bar.
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

/// The tabs, in the order they appear at the bottom of the screen.
/// Every path here must also exist in the routes table in main.dart.
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
    path: '/about',
    label: 'About',
    icon: Icons.info_outline,
    selectedIcon: Icons.info,
  ),
];

/// The frame every screen is built inside: a plain title row on top, the
/// screen's own content in the middle, and the tabs at the bottom.
class AppNavScaffold extends StatelessWidget {
  /// Index into [appRoutes] of the tab this screen belongs to. A page opened
  /// inside a tab, such as a Guide topic, points at that tab.
  final int currentIndex;
  final String title;
  final Widget body;
  final List<Widget>? actions;

  /// True for a page opened from inside a tab, such as a Guide topic, rather
  /// than a tab itself. Its back arrow returns to the page underneath instead
  /// of Home, and tapping its own tab goes back to that tab's first page.
  final bool isSubPage;

  const AppNavScaffold({
    super.key,
    required this.currentIndex,
    required this.title,
    required this.body,
    this.actions,
    this.isSubPage = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              title: title,
              actions: actions,
              backTooltip: isSubPage ? 'Back' : 'Back to Home',
              onBack: isSubPage
                  ? () => Navigator.maybePop(context)
                  : currentIndex == 0
                      ? null
                      : () => _openTab(context, 0),
            ),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: kBorderColor)),
        ),
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: (index) => _openTab(context, index),
          destinations: [
            for (final route in appRoutes)
              NavigationDestination(
                icon: Icon(route.icon),
                selectedIcon: Icon(route.selectedIcon),
                label: route.label,
              ),
          ],
        ),
      ),
    );
  }

  /// Clears the old screens so tapping tabs never piles them up on each other.
  void _openTab(BuildContext context, int index) {
    // A tab ignores a tap on itself; a page inside it treats the tap as "back
    // to the start of this tab".
    if (index == currentIndex && !isSubPage) {
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, appRoutes[index].path, (route) => false);
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final VoidCallback? onBack;
  final String backTooltip;

  const _TopBar({
    required this.title,
    required this.actions,
    required this.onBack,
    required this.backTooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 8, 8, 8, 4),
      child: AppContentWidth(
        child: Row(
          children: [
            if (onBack != null)
              IconButton(
                tooltip: backTooltip,
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: onBack,
              ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (actions != null) ...actions!,
          ],
        ),
      ),
    );
  }
}

/// Keeps content readable on a wide window instead of stretching it edge to
/// edge. Used by the title row and the page body so both line up.
class AppContentWidth extends StatelessWidget {
  final Widget child;

  const AppContentWidth({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: child,
      ),
    );
  }
}

/// A scrollable page body with the same padding and spacing on every screen.
class AppPage extends StatelessWidget {
  final List<Widget> children;

  const AppPage({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return AppContentWidth(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        itemCount: children.length,
        itemBuilder: (context, index) => children[index],
        separatorBuilder: (context, index) => const SizedBox(height: 12),
      ),
    );
  }
}
