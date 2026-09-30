import 'package:flutter/material.dart';

class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.overVideo = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<String> destinations;
  final bool overVideo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: overVideo ? Colors.transparent : colors.surfaceContainerLow,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 4),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              for (final (index, label) in destinations.indexed)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: index == selectedIndex,
                    label: label,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: ValueKey('bottom-nav-$index'),
                        borderRadius: BorderRadius.circular(18),
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        overlayColor: const WidgetStatePropertyAll(
                          Colors.transparent,
                        ),
                        onTap: () => onDestinationSelected(index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          margin: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: index == selectedIndex
                                ? (overVideo
                                      ? colors.secondaryContainer.withValues(
                                          alpha: .94,
                                        )
                                      : colors.secondaryContainer)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: index == selectedIndex
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: index == selectedIndex
                                  ? colors.onSecondaryContainer
                                  : overVideo
                                  ? Colors.white
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
