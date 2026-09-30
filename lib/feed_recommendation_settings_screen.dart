import 'package:flutter/material.dart';

import 'feed_preferences.dart';
import 'feed_recommendations.dart';
import 'local_store.dart';

class FeedRecommendationSettingsScreen extends StatefulWidget {
  const FeedRecommendationSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<FeedRecommendationSettingsScreen> createState() =>
      _FeedRecommendationSettingsScreenState();
}

class _FeedRecommendationSettingsScreenState
    extends State<FeedRecommendationSettingsScreen> {
  final _search = TextEditingController();
  late final Map<String, FeedInterest> _profile;
  late Map<String, int> _manualWeights;
  late bool _randomMode;
  String _query = '';
  bool _saving = false;
  bool _clearingExposureHistory = false;

  @override
  void initState() {
    super.initState();
    final store = widget.store;
    final preferences = store.feedRecommendationPreferences;
    _manualWeights = FeedRecommendations.groupManualWeights(
      preferences.manualWeights,
    );
    _randomMode = preferences.randomMode;
    _profile = FeedRecommendations.hierarchicalInterestProfile(
      history: store.history,
      favorites: store.favorites,
      session: store.feedSessionSignals,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  int _percent(double score) => (score / 3 * 100).round().clamp(-100, 100);

  String _signed(int value) => '${value > 0 ? '+' : ''}$value%';

  List<({FeedTopicGroup group, List<FeedTopic> topics})> get _visibleGroups {
    final query = _query.trim().toLowerCase();
    final visible = <({FeedTopicGroup group, List<FeedTopic> topics})>[];
    for (final group in FeedRecommendations.topicGroups) {
      final matchingTopics = group.topics
          .where((topic) => topic.label.toLowerCase().contains(query))
          .toList();
      if (query.isEmpty || group.label.toLowerCase().contains(query)) {
        visible.add((group: group, topics: group.topics));
      } else if (matchingTopics.isNotEmpty) {
        visible.add((group: group, topics: matchingTopics));
      }
    }
    return visible;
  }

  Future<void> _persist({
    required bool randomMode,
    required Map<String, int> manualWeights,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.store.setFeedRecommendationPreferences(
        FeedRecommendationPreferences(
          randomMode: randomMode,
          manualWeights: Map.unmodifiable(manualWeights),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          final saved = widget.store.feedRecommendationPreferences;
          _manualWeights = FeedRecommendations.groupManualWeights(
            saved.manualWeights,
          );
          _randomMode = saved.randomMode;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存猜你喜欢设置失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetRandom() async {
    if (_saving) return;
    setState(() {
      _manualWeights.clear();
      _randomMode = true;
    });
    await _persist(randomMode: true, manualWeights: const {});
  }

  Future<void> _clearExposureHistory() async {
    if (_clearingExposureHistory) return;
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除首页去重记录？'),
        content: const Text(
          '这会清除最近 30 部首页已刷短剧的去重记录，让它们之后可以重新进入推荐。最近观看、播放进度和收藏不会被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除记录'),
          ),
        ],
      ),
    );
    if (clear != true || !mounted) return;
    setState(() => _clearingExposureHistory = true);
    try {
      await widget.store.clearFeedExposureHistory();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('首页去重记录已清除，最近观看记录保留。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清除首页去重记录失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _clearingExposureHistory = false);
    }
  }

  void _previewWeight(String key, double value) {
    if (_saving) return;
    setState(() {
      _manualWeights[key] = value.round();
      _randomMode = false;
    });
  }

  Future<void> _saveWeight(String key, int value) async {
    if (_saving) return;
    final weights = Map<String, int>.of(_manualWeights)..[key] = value;
    await _persist(randomMode: false, manualWeights: weights);
  }

  Future<void> _followParent(String key) async {
    if (_saving || !_manualWeights.containsKey(key)) return;
    final weights = Map<String, int>.of(_manualWeights)..remove(key);
    setState(() => _manualWeights = weights);
    await _persist(randomMode: false, manualWeights: weights);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final groups = _visibleGroups;
    final topicCount = groups.fold<int>(
      0,
      (count, group) => count + group.topics.length,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('猜你喜欢')),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _randomMode ? '当前：全随机' : '当前：按兴趣排序',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '已收敛为 5 个大类和 25 个二级题材。默认按兴趣排序：兴趣匹配占 65%，热度与播放量合计占 10%。调整大类会影响该组题材；展开后可单独微调。权重会即时影响后续首页候选，百分比不是播放概率。首页单独保存最近 30 部的去重记录，清空最近观看不会清除它。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.start,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey(
                            'feed-recommendation-random-reset',
                          ),
                          onPressed: _saving ? null : _resetRandom,
                          icon: const Icon(Icons.shuffle_rounded),
                          label: const Text('重置为全随机'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('feed-clear-exposure-history'),
                          onPressed: _clearingExposureHistory
                              ? null
                              : _clearExposureHistory,
                          icon: const Icon(Icons.history_toggle_off_rounded),
                          label: const Text('清除首页去重记录'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: '搜索大类或二级题材',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  filled: true,
                  fillColor: colors.surfaceContainerLow,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  groups.isEmpty
                      ? '没有匹配的大类或二级题材'
                      : _query.isEmpty
                      ? '题材权重 · 5 个大类'
                      : '匹配 ${groups.length} 个大类 · $topicCount 个二级题材',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          '没有找到相关题材',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        key: const ValueKey(
                          'feed-recommendation-interest-list',
                        ),
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final item = groups[index];
                          return _groupCard(context, item.group, item.topics);
                        },
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                      ),
              ),
              if (_saving) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupCard(
    BuildContext context,
    FeedTopicGroup group,
    List<FeedTopic> topics,
  ) {
    final colors = Theme.of(context).colorScheme;
    final key = FeedRecommendations.groupWeightKey(group.id);
    final interest = _profile[key];
    final automatic = _percent(interest?.score ?? 0);
    final current = _manualWeights[key] ?? automatic;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${topics.length} 个二级题材',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(width: 10),
                Text(
                  _signed(current),
                  key: ValueKey('feed-recommendation-weight-$key'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: current < 0 ? colors.error : colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '识别 ${_signed(automatic)} · 长期 ${_signed(_percent(interest?.longTerm ?? 0))} · 本次 ${_signed(_percent(interest?.session ?? 0))}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                _weightSlider(key, current),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: colors.outlineVariant.withValues(alpha: .7),
          ),
          ExpansionTile(
            key: ValueKey('feed-topic-group-${group.id}-$_query'),
            initiallyExpanded: _query.isNotEmpty,
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            title: const Text('展开二级题材'),
            subtitle: const Text('单项设置优先于大类权重'),
            children: [
              for (final topic in topics) _topicRow(context, group, topic),
            ],
          ),
        ],
      ),
    );
  }

  Widget _topicRow(
    BuildContext context,
    FeedTopicGroup group,
    FeedTopic topic,
  ) {
    final colors = Theme.of(context).colorScheme;
    final key = FeedRecommendations.topicWeightKey(topic.id);
    final groupKey = FeedRecommendations.groupWeightKey(group.id);
    final interest = _profile[key];
    final automatic = _percent(interest?.score ?? 0);
    final inherited = _manualWeights[groupKey];
    final current = _manualWeights[key] ?? inherited ?? automatic;
    final followsGroup = !_manualWeights.containsKey(key) && inherited != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topic.label,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '识别 ${_signed(automatic)} · 长期 ${_signed(_percent(interest?.longTerm ?? 0))} · 本次 ${_signed(_percent(interest?.session ?? 0))}${followsGroup ? ' · 跟随大类' : ''}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              Text(
                _signed(current),
                key: ValueKey('feed-recommendation-weight-$key'),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: current < 0 ? colors.error : colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_manualWeights.containsKey(key))
                IconButton(
                  tooltip: '跟随大类权重',
                  onPressed: _saving ? null : () => _followParent(key),
                  icon: const Icon(Icons.subdirectory_arrow_left_rounded),
                ),
            ],
          ),
          _weightSlider(key, current),
        ],
      ),
    );
  }

  Widget _weightSlider(String key, int current) => Slider(
    min: -100,
    max: 100,
    divisions: 40,
    value: current.toDouble(),
    onChanged: _saving ? null : (value) => _previewWeight(key, value),
    onChangeEnd: _saving ? null : (value) => _saveWeight(key, value.round()),
  );
}
