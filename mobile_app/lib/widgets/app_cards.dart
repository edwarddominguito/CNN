import 'package:flutter/material.dart';

import '../app_colors.dart';

/// The building blocks every screen is assembled from.
///
/// Screens should combine the widgets in this file instead of drawing their
/// own containers, so padding, radius and type stay identical everywhere and
/// a new screen is a list of these rather than a new visual style.

/// The flat, hairline-bordered box that holds a piece of content.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.color = kSurface,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);

    return Material(
      color: color,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        // A card with no action should not light up under a finger.
        splashFactory: onTap == null ? NoSplash.splashFactory : null,
        child: Ink(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: kBorderColor),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A row of icon, title and one supporting line. Tapping it is optional; when
/// [onTap] is given a chevron appears so the row reads as a link.
class AppTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;
  final Color? background;
  final Widget? trailing;
  final VoidCallback? onTap;

  const AppTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconColor = kPrimaryGreen,
    this.background,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      onTap: onTap,
      color: background ?? kSurface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.titleMedium),
                const SizedBox(height: 3),
                Text(subtitle, style: textTheme.bodySmall),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          if (trailing == null && onTap != null)
            const Icon(Icons.chevron_right, size: 20, color: kMutedText),
        ],
      ),
    );
  }
}

/// Icon, title and a paragraph, stacked. The unit the Guide and About grids
/// are built from.
class AppInfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const AppInfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: kPrimaryGreen),
          const SizedBox(height: 14),
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(text, style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Shown when a screen has nothing to list yet.
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: kMutedText),
          const SizedBox(height: 14),
          Text(title, style: textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center, style: textTheme.bodySmall),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

/// Lays cards out in as many equal columns as the width allows: one on a
/// phone, more on a tablet or a wide browser window.
class AppCardGrid extends StatelessWidget {
  final List<Widget> children;
  final double minItemWidth;

  const AppCardGrid({super.key, required this.children, this.minItemWidth = 260});

  @override
  Widget build(BuildContext context) {
    const spacing = 12.0;
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // clamp needs a real upper limit, so an empty list is handled above.
        final columns =
            (constraints.maxWidth / minItemWidth).floor().clamp(1, children.length);
        final itemWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children) SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}
