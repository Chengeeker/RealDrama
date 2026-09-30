import 'dart:math';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'catalog_browser.dart';
import 'models.dart';
import 'remote_widgets.dart';

class CatalogFilters extends StatefulWidget {
  const CatalogFilters({
    super.key,
    required this.categories,
    required this.category,
    required this.onCategory,
    required this.onRetry,
    this.primaryCategory,
    this.contentFormat = 'all',
    this.onContentFormat,
    this.taxonomyGroups,
    this.onTaxonomyGroup,
    this.error,
    this.trailing,
  });

  final List<CatalogCategory> categories;
  final String category;
  final String? primaryCategory;
  final String contentFormat;
  final String? error;
  final List<CatalogTaxonomyGroup>? taxonomyGroups;
  final ValueChanged<String> onCategory;
  final ValueChanged<String>? onContentFormat;
  final ValueChanged<String>? onTaxonomyGroup;
  final VoidCallback onRetry;
  final Widget? trailing;

  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  final _anchors = <String, GlobalKey>{};

  @override
  void didUpdateWidget(covariant CatalogFilters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final anchor = _anchors[widget.category]?.currentContext;
        if (mounted && anchor != null) {
          Scrollable.ensureVisible(
            anchor,
            alignment: .4,
            duration: const Duration(milliseconds: 180),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final taxonomyGroups = widget.taxonomyGroups;
    if (!television &&
        taxonomyGroups != null &&
        taxonomyGroups.isNotEmpty &&
        widget.onTaxonomyGroup != null) {
      return _taxonomyFilters(context, taxonomyGroups);
    }
    return SizedBox(
      height: television
          ? 64
          : max(52, MediaQuery.textScalerOf(context).scale(14) + 28),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('catalog-categories'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (final entry in widget.categories)
                    Padding(
                      key: _anchors.putIfAbsent(entry.id, GlobalKey.new),
                      padding: const EdgeInsets.only(right: 6),
                      child: television
                          ? RemoteButton(
                              key: ValueKey('category-${entry.id}'),
                              label: entry.name,
                              selected: entry.id == widget.category,
                              onPressed: () => widget.onCategory(entry.id),
                            )
                          : ChoiceChip(
                              key: ValueKey('category-${entry.id}'),
                              label: Text(entry.name),
                              selected: entry.id == widget.category,
                              showCheckmark: false,
                              onSelected: (_) => widget.onCategory(entry.id),
                            ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.error != null)
            IconButton(
              tooltip: widget.error,
              onPressed: widget.onRetry,
              icon: Icon(
                Icons.refresh_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }

  Widget _taxonomyFilters(
    BuildContext context,
    List<CatalogTaxonomyGroup> groups,
  ) {
    final colors = Theme.of(context).colorScheme;
    final primaryCategory = widget.primaryCategory ?? widget.category;
    final formatGroup = groups.firstWhere(
      (entry) => entry.group.id == 'format',
    );
    final primaryGroups = groups
        .where((entry) => entry.group.id != 'format')
        .toList(growable: false);
    final activeGroup = primaryGroups.where((entry) {
      return entry.filter.id == primaryCategory ||
          entry.categories.any((category) => category.id == primaryCategory);
    }).firstOrNull;
    final showRecommendation = primaryCategory == 'app:recommendations';
    final showFormatFilters =
        (primaryCategory.isEmpty || showRecommendation) &&
        formatGroup.categories.isNotEmpty;
    final showSecondary = activeGroup != null || showFormatFilters;
    Widget chip(
      String id,
      String label,
      bool selected,
      VoidCallback onPressed, {
      String? anchorId,
    }) => Padding(
      key: _anchors.putIfAbsent(anchorId ?? id, GlobalKey.new),
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: ValueKey('category-${anchorId ?? id}'),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onPressed(),
      ),
    );

    return SizedBox(
      height: showSecondary ? 100 : 50,
      child: Column(
        children: [
          SizedBox(
            height: 50,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        chip(
                          '',
                          '全部',
                          primaryCategory.isEmpty,
                          () => widget.onCategory(''),
                        ),
                        chip(
                          'app:recommendations',
                          '推荐',
                          showRecommendation,
                          () => widget.onCategory('app:recommendations'),
                        ),
                        for (final entry in primaryGroups)
                          chip(
                            'taxonomy-group:${entry.group.id}',
                            entry.group.label,
                            activeGroup?.group.id == entry.group.id,
                            () => widget.onTaxonomyGroup!(entry.group.id),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.error != null)
                  IconButton(
                    tooltip: widget.error,
                    onPressed: widget.onRetry,
                    icon: Icon(Icons.refresh_rounded, color: colors.error),
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
          if (showFormatFilters)
            SizedBox(
              height: 50,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('catalog-content-formats'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          chip(
                            'content-format:all',
                            '全部内容形式',
                            widget.contentFormat == 'all',
                            () => widget.onContentFormat?.call('all'),
                          ),
                          for (
                            var index = 0;
                            index < formatGroup.categories.length;
                            index++
                          )
                            chip(
                              'content-format:${formatGroup.topicIds[index]}',
                              formatGroup.group.topics[index].label,
                              widget.contentFormat ==
                                  formatGroup.topicIds[index],
                              () => widget.onContentFormat?.call(
                                formatGroup.topicIds[index],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (activeGroup != null)
            SizedBox(
              height: 50,
              child: SingleChildScrollView(
                key: ValueKey('catalog-subcategories-${activeGroup.group.id}'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    chip(
                      'taxonomy-group:${activeGroup.group.id}',
                      '全部${activeGroup.group.label}',
                      widget.category == activeGroup.filter.id,
                      () => widget.onCategory(activeGroup.filter.id),
                      anchorId: 'taxonomy-parent-all:${activeGroup.group.id}',
                    ),
                    for (final category in activeGroup.categories)
                      chip(
                        category.id,
                        category.name,
                        widget.category == category.id,
                        () => widget.onCategory(category.id),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
