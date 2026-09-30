import 'dart:math' as math;

import 'models.dart';

class FeedWatchSignal {
  const FeedWatchSignal({
    required this.drama,
    required this.value,
    this.isLike = false,
  });

  final Drama drama;
  final double value;
  final bool isLike;
}

class FeedInterest {
  const FeedInterest({
    required this.tag,
    required this.longTerm,
    required this.session,
    required this.score,
  });

  final String tag;
  final double longTerm;
  final double session;
  final double score;
}

class FeedTopic {
  const FeedTopic({
    required this.id,
    required this.label,
    required this.aliases,
  });

  final String id;
  final String label;
  final List<String> aliases;
}

class FeedTopicGroup {
  const FeedTopicGroup({
    required this.id,
    required this.label,
    required this.topics,
  });

  final String id;
  final String label;
  final List<FeedTopic> topics;
}

class FeedRecommendations {
  const FeedRecommendations._();

  static const topicGroups = <FeedTopicGroup>[
    FeedTopicGroup(
      id: 'format',
      label: '内容形式',
      topics: [
        FeedTopic(id: 'live', label: '真人剧', aliases: ['真人剧', '真人短剧', '真人']),
        FeedTopic(id: 'manga', label: '漫剧', aliases: ['漫剧', '动画剧', '动漫短剧']),
        FeedTopic(
          id: 'ai',
          label: 'AI剧',
          aliases: ['AI剧', 'AI短剧', 'AI真人剧', 'AI漫剧'],
        ),
      ],
    ),
    FeedTopicGroup(
      id: 'setting',
      label: '故事题材',
      topics: [
        FeedTopic(id: 'urban', label: '都市生活', aliases: ['都市生活', '都市', '现代']),
        FeedTopic(
          id: 'ancient',
          label: '古装宫廷',
          aliases: ['古装宫廷', '古装', '宫廷', '古代'],
        ),
        FeedTopic(id: 'xianxia', label: '东方仙侠', aliases: ['东方仙侠', '仙侠']),
        FeedTopic(id: 'fantasy', label: '传统玄幻', aliases: ['传统玄幻', '玄幻', '奇幻']),
        FeedTopic(
          id: 'rural_era',
          label: '年代乡村',
          aliases: ['年代乡村', '年代', '乡村', '农村'],
        ),
        FeedTopic(
          id: 'mystery',
          label: '悬疑推理',
          aliases: ['悬疑推理', '悬疑', '推理', '犯罪', '惊悚', '恐怖'],
        ),
        FeedTopic(
          id: 'workplace',
          label: '职场商战',
          aliases: ['职场商战', '职场', '商战', '创业'],
        ),
        FeedTopic(
          id: 'campus',
          label: '校园成长',
          aliases: ['校园成长', '校园', '青春', '成长'],
        ),
        FeedTopic(
          id: 'family',
          label: '家庭现实',
          aliases: ['家庭现实', '家庭', '亲情', '现实'],
        ),
        FeedTopic(
          id: 'adventure',
          label: '冒险动作',
          aliases: ['冒险动作', '冒险', '动作', '武侠', '战争'],
        ),
      ],
    ),
    FeedTopicGroup(
      id: 'plot',
      label: '剧情套路',
      topics: [
        FeedTopic(id: 'rebirth', label: '重生逆袭', aliases: ['重生逆袭', '重生', '逆袭']),
        FeedTopic(id: 'revenge', label: '复仇打脸', aliases: ['复仇打脸', '复仇', '打脸']),
        FeedTopic(
          id: 'transmigration',
          label: '穿越系统',
          aliases: ['穿越系统', '穿越', '系统'],
        ),
        FeedTopic(
          id: 'wealth_romance',
          label: '豪门婚恋',
          aliases: ['豪门婚恋', '豪门', '闪婚', '先婚后爱', '婚恋'],
        ),
        FeedTopic(id: 'son_in_law', label: '赘婿逆袭', aliases: ['赘婿逆袭', '赘婿']),
        FeedTopic(id: 'palace', label: '宫斗宅斗', aliases: ['宫斗宅斗', '宫斗', '宅斗']),
      ],
    ),
    FeedTopicGroup(
      id: 'mood',
      label: '情感风格',
      topics: [
        FeedTopic(
          id: 'romance',
          label: '甜宠爱情',
          aliases: ['甜宠爱情', '甜宠', '爱情', '恋爱', '言情'],
        ),
        FeedTopic(id: 'tragic', label: '虐恋情感', aliases: ['虐恋情感', '虐恋', '虐心']),
        FeedTopic(
          id: 'comedy',
          label: '搞笑喜剧',
          aliases: ['搞笑喜剧', '搞笑', '喜剧', '轻喜'],
        ),
        FeedTopic(
          id: 'healing',
          label: '治愈温情',
          aliases: ['治愈温情', '治愈', '温情', '温馨'],
        ),
        FeedTopic(id: 'passion', label: '热血爽感', aliases: ['热血爽感', '热血', '爽剧']),
      ],
    ),
    FeedTopicGroup(
      id: 'other',
      label: '其他',
      topics: [
        FeedTopic(id: 'other', label: '其他 / 未归类', aliases: ['其他', '其它', '未知']),
      ],
    ),
  ];

  static final _topicAliasIndex = [
    for (final group in topicGroups)
      for (final topic in group.topics)
        (
          group: group,
          topic: topic,
          aliases: topic.aliases.map(_normalize).toList(),
        ),
  ];

  static List<FeedInterest> interestProfile({
    required Iterable<WatchEntry> history,
    required Iterable<Drama> favorites,
    required Iterable<FeedWatchSignal> session,
  }) {
    final longTermSignals = <FeedWatchSignal>[
      for (final entry in history)
        FeedWatchSignal(drama: entry.drama, value: _watchValue(entry)),
      for (final drama in favorites) FeedWatchSignal(drama: drama, value: 1.2),
    ];
    final longTerm = _interestWeights(longTermSignals);
    final recent = _interestWeights(session.toList());
    final tags = {...longTerm.keys, ...recent.keys}.toList()..sort();
    final profile = [
      for (final tag in tags)
        FeedInterest(
          tag: tag,
          longTerm: longTerm[tag] ?? 0,
          session: recent[tag] ?? 0,
          score: .6 * (longTerm[tag] ?? 0) + .4 * (recent[tag] ?? 0),
        ),
    ];
    profile.sort((a, b) {
      final difference = b.score.abs().compareTo(a.score.abs());
      return difference == 0 ? a.tag.compareTo(b.tag) : difference;
    });
    return profile;
  }

  static Map<String, FeedInterest> hierarchicalInterestProfile({
    required Iterable<WatchEntry> history,
    required Iterable<Drama> favorites,
    required Iterable<FeedWatchSignal> session,
  }) {
    final rawProfile = interestProfile(
      history: history,
      favorites: favorites,
      session: session,
    );
    final topicSamples = <String, List<FeedInterest>>{};
    final groupSamples = <String, Map<String, FeedInterest>>{};
    for (final interest in rawProfile) {
      final topicMatches = _topicMatches(interest.tag);
      for (final match in topicMatches) {
        topicSamples.putIfAbsent(match.topic.id, () => []).add(interest);
        groupSamples.putIfAbsent(match.group.id, () => {})[interest.tag] =
            interest;
      }
    }
    final profile = <String, FeedInterest>{};
    for (final group in topicGroups) {
      final samples = groupSamples[group.id]?.values;
      if (samples != null && samples.isNotEmpty) {
        profile[groupWeightKey(group.id)] = _averageInterest(
          groupWeightKey(group.id),
          samples,
        );
      }
      for (final topic in group.topics) {
        final topicInterests = topicSamples[topic.id];
        if (topicInterests != null && topicInterests.isNotEmpty) {
          profile[topicWeightKey(topic.id)] = _averageInterest(
            topicWeightKey(topic.id),
            topicInterests,
          );
        }
      }
    }
    return Map.unmodifiable(profile);
  }

  static Map<String, int> groupManualWeights(Map<String, int> weights) {
    final grouped = <String, int>{};
    final samples = <String, List<int>>{};
    for (final entry in weights.entries) {
      if (entry.key.startsWith('group:') || entry.key.startsWith('topic:')) {
        grouped[entry.key] = entry.value;
        continue;
      }
      for (final match in _topicMatches(entry.key)) {
        samples
            .putIfAbsent(topicWeightKey(match.topic.id), () => [])
            .add(entry.value);
      }
    }
    for (final entry in samples.entries) {
      grouped.putIfAbsent(
        entry.key,
        () =>
            (entry.value.reduce((a, b) => a + b) / entry.value.length).round(),
      );
    }
    return grouped;
  }

  static String groupWeightKey(String id) => 'group:$id';

  static String topicWeightKey(String id) => 'topic:$id';

  static List<Drama> rank({
    required Iterable<Drama> candidates,
    required Iterable<WatchEntry> history,
    required Iterable<Drama> favorites,
    required Iterable<FeedWatchSignal> session,
    required Map<String, int> exposures,
    required Iterable<Drama> recent,
    required int randomSeed,
    required Set<String> excluded,
    Map<String, int> manualWeights = const {},
    bool randomMode = false,
  }) {
    if (randomMode) {
      final randomized = <Drama>[];
      final identities = <String>{};
      for (final drama in candidates) {
        final identity = '${drama.source}:${drama.id}';
        if (excluded.contains(drama.id) ||
            excluded.contains(identity) ||
            !identities.add(identity)) {
          continue;
        }
        randomized.add(drama);
      }
      randomized.shuffle(math.Random(randomSeed));
      return randomized;
    }

    final historicalSignals = <FeedWatchSignal>[
      for (final entry in history)
        FeedWatchSignal(drama: entry.drama, value: _watchValue(entry)),
      for (final drama in favorites) FeedWatchSignal(drama: drama, value: 1.2),
    ];
    final longTerm = _interestWeights(historicalSignals);
    final sessionWeights = _interestWeights(session.toList());
    final recentItems = recent.toList(growable: false);
    final recentFeatures = [for (final drama in recentItems) _features(drama)];
    final seenFeatures = <String, int>{};
    for (final features in recentFeatures) {
      for (final feature in features) {
        seenFeatures.update(feature, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final recentIds = recentItems
        .map((drama) => '${drama.source}:${drama.id}')
        .toSet();
    final scored = <({Drama drama, double score})>[];
    for (final drama in candidates) {
      if (excluded.contains(drama.id) ||
          excluded.contains('${drama.source}:${drama.id}')) {
        continue;
      }
      final features = _features(drama);
      final longMatch = _match(features, longTerm, manualWeights);
      final sessionMatch = _match(features, sessionWeights, manualWeights);
      final heat = _heat(drama.heat, drama.views);
      final freshness = _freshness(drama.onlineDate);
      final featureNovelty = features.isEmpty
          ? 0.35
          : features
                    .map((feature) => 1 / (1 + (seenFeatures[feature] ?? 0)))
                    .fold<double>(0, (sum, value) => sum + value) /
                features.length;
      final itemNovelty =
          1 / (1 + (exposures['${drama.source}:${drama.id}'] ?? 0));
      final novelty = (featureNovelty + itemNovelty) / 2;
      final random = _stableNoise('$randomSeed:${drama.source}:${drama.id}');
      final duplicatePenalty = _duplicatePenalty(
        drama,
        features,
        recentIds,
        recentItems,
        recentFeatures,
      );
      final score =
          .38 * longMatch +
          .27 * sessionMatch +
          .10 * heat +
          .10 * freshness +
          .10 * novelty +
          .05 * random -
          duplicatePenalty;
      scored.add((drama: drama, score: score));
    }
    scored.sort((a, b) {
      final difference = b.score.compareTo(a.score);
      if (difference != 0) return difference;
      return '${a.drama.source}:${a.drama.id}'.compareTo(
        '${b.drama.source}:${b.drama.id}',
      );
    });
    return _diversify(scored);
  }

  static List<Drama> _diversify(List<({Drama drama, double score})> scored) {
    const windowSize = 24;
    final ranked = <Drama>[];
    final recentFeatures = <({Drama drama, Set<String> features})>[];
    for (var offset = 0; offset < scored.length; offset += windowSize) {
      final end = math.min(offset + windowSize, scored.length);
      final remaining = [
        for (final candidate in scored.sublist(offset, end))
          (
            drama: candidate.drama,
            score: candidate.score,
            features: _features(candidate.drama),
          ),
      ];
      while (remaining.isNotEmpty) {
        var bestIndex = 0;
        var bestScore = double.negativeInfinity;
        for (var index = 0; index < remaining.length; index++) {
          final candidate = remaining[index];
          final penalty = _sequenceDiversityPenalty(
            candidate.drama,
            candidate.features,
            recentFeatures,
          );
          final adjusted = candidate.score - penalty;
          if (adjusted > bestScore) {
            bestScore = adjusted;
            bestIndex = index;
          }
        }
        final selected = remaining.removeAt(bestIndex);
        ranked.add(selected.drama);
        recentFeatures.add((
          drama: selected.drama,
          features: selected.features,
        ));
        if (recentFeatures.length > 5) recentFeatures.removeAt(0);
      }
    }
    return ranked;
  }

  static double _sequenceDiversityPenalty(
    Drama candidate,
    Set<String> features,
    Iterable<({Drama drama, Set<String> features})> recent,
  ) {
    var penalty = 0.0;
    for (final previous in recent) {
      if (candidate.source == previous.drama.source &&
          candidate.title == previous.drama.title) {
        return 1;
      }
      final overlap = features.intersection(previous.features).length;
      if (overlap >= 2) {
        penalty = math.max(penalty, .16);
      } else if (overlap == 1 && candidate.source == previous.drama.source) {
        penalty = math.max(penalty, .08);
      }
    }
    return penalty;
  }

  static double _watchValue(WatchEntry entry) {
    if (entry.duration <= 0 || entry.position <= 0) return 0;
    final ratio = (entry.position / entry.duration).clamp(0, 1).toDouble();
    var value = switch (ratio) {
      < .05 => -1.2,
      < .20 => -.7,
      < .50 => -.2,
      < .80 => .45,
      _ => .85,
    };
    if (ratio >= .98) value += .45;
    if (entry.episode >= 3) value += .6;
    if (entry.episode >= 5) value += .9;
    final ageDays = DateTime.now().difference(entry.updatedAt).inDays;
    value *= ageDays <= 30
        ? 1
        : ageDays <= 180
        ? .7
        : .4;
    return value.clamp(-2, 3).toDouble();
  }

  static Map<String, double> _interestWeights(List<FeedWatchSignal> signals) {
    final totals = <String, double>{};
    final counts = <String, double>{};
    for (final signal in signals) {
      for (final feature in _features(signal.drama)) {
        totals.update(
          feature,
          (value) => value + signal.value,
          ifAbsent: () => signal.value,
        );
        counts.update(feature, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    return {
      for (final entry in totals.entries)
        entry.key: (entry.value / math.sqrt(counts[entry.key]!))
            .clamp(-3, 3)
            .toDouble(),
    };
  }

  static double _match(
    Set<String> features,
    Map<String, double> weights,
    Map<String, int> manualWeights,
  ) {
    if (features.isEmpty) return .35;
    if (weights.isEmpty &&
        !features.any(
          (feature) => _manualWeight(feature, manualWeights) != null,
        )) {
      return .35;
    }
    var total = 0.0;
    for (final feature in features) {
      total += _manualWeight(feature, manualWeights) ?? weights[feature] ?? 0;
    }
    final average = total / features.length;
    return ((average + 3) / 6).clamp(0, 1).toDouble();
  }

  static double? _manualWeight(String feature, Map<String, int> weights) {
    final topicOverrides = <int>[];
    final groupOverrides = <int>[];
    for (final match in _topicMatches(feature)) {
      final topic = weights[topicWeightKey(match.topic.id)];
      if (topic != null) {
        topicOverrides.add(topic);
      } else {
        final group = weights[groupWeightKey(match.group.id)];
        if (group != null) groupOverrides.add(group);
      }
    }
    final overrides = topicOverrides.isNotEmpty
        ? topicOverrides
        : groupOverrides;
    if (overrides.isNotEmpty) {
      return overrides.reduce((a, b) => a + b) / overrides.length * .03;
    }
    final legacy = weights[feature];
    return legacy == null ? null : legacy.clamp(-100, 100) * .03;
  }

  static FeedInterest _averageInterest(
    String key,
    Iterable<FeedInterest> source,
  ) {
    final interests = source.toList();
    final longTerm =
        interests.fold<double>(0, (sum, interest) => sum + interest.longTerm) /
        interests.length;
    final session =
        interests.fold<double>(0, (sum, interest) => sum + interest.session) /
        interests.length;
    return FeedInterest(
      tag: key,
      longTerm: longTerm,
      session: session,
      score: .6 * longTerm + .4 * session,
    );
  }

  static List<({FeedTopicGroup group, FeedTopic topic})> _topicMatches(
    String value,
  ) {
    final normalized = _normalize(value);
    if (normalized.isEmpty) return const [];
    final matches = <({FeedTopicGroup group, FeedTopic topic})>[];
    for (final entry in _topicAliasIndex) {
      if (entry.aliases.any(
        (candidate) =>
            normalized == candidate || normalized.contains(candidate),
      )) {
        matches.add((group: entry.group, topic: entry.topic));
      }
    }
    if (matches.isNotEmpty) return matches;
    final otherGroup = topicGroups.last;
    return [(group: otherGroup, topic: otherGroup.topics.single)];
  }

  static ({FeedTopicGroup group, FeedTopic topic}) topicFor(String value) {
    final normalized = _normalize(value);
    final matches = _topicMatches(value);
    if (matches.isEmpty) {
      final other = topicGroups.last;
      return (group: other, topic: other.topics.single);
    }
    var best = matches.first;
    var bestLength = 0;
    for (final match in matches) {
      for (final alias in match.topic.aliases) {
        final candidate = _normalize(alias);
        if ((normalized == candidate || normalized.contains(candidate)) &&
            candidate.length > bestLength) {
          best = match;
          bestLength = candidate.length;
        }
      }
    }
    return best;
  }

  static bool matchesTopic(Drama drama, String topicId) {
    for (final value in [drama.category, ...drama.tags]) {
      if (value.trim().isEmpty) continue;
      if (_topicMatches(value).any((match) => match.topic.id == topicId)) {
        return true;
      }
    }
    return false;
  }

  static bool matchesTopicGroup(Drama drama, String groupId) {
    for (final value in [drama.category, ...drama.tags]) {
      if (value.trim().isEmpty) continue;
      if (_topicMatches(value).any((match) => match.group.id == groupId)) {
        return true;
      }
    }
    return false;
  }

  static ({Set<String> topics, Set<String> groups}) taxonomyFor(Drama drama) {
    final topics = <String>{};
    final groups = <String>{};
    for (final value in [drama.category, ...drama.tags]) {
      if (value.trim().isEmpty) continue;
      for (final match in _topicMatches(value)) {
        topics.add(match.topic.id);
        groups.add(match.group.id);
      }
    }
    return (topics: topics, groups: groups);
  }

  static Set<String> _features(Drama drama) {
    final values = <String>{
      if (drama.category.isNotEmpty) drama.category.trim(),
      ...drama.tags.map((tag) => tag.trim()),
    }..removeWhere((value) => value.isEmpty || value == '短剧');
    final title = drama.title.length <= 128
        ? drama.title
        : drama.title.substring(0, 128);
    final description = drama.description.length <= 192
        ? drama.description
        : drama.description.substring(0, 192);
    final text = '$title $description';
    const keywords = [
      '重生',
      '逆袭',
      '复仇',
      '穿越',
      '系统',
      '闪婚',
      '豪门',
      '先婚后爱',
      '甜宠',
      '虐恋',
      '悬疑',
      '治愈',
      '搞笑',
      '仙侠',
      '宫斗',
      '年代',
      '商战',
      '赘婿',
      '职场',
      '家庭',
      '校园',
      '成长',
      '都市',
      '古装',
      '奇幻',
      '漫剧',
      'AI剧',
      'AI短剧',
      'AI漫剧',
      '真人剧',
      '东方仙侠',
      '乡村',
      '传统玄幻',
      '冒险',
    ];
    for (final keyword in keywords) {
      if (text.contains(keyword)) values.add(keyword);
    }
    return values;
  }

  static bool matchesCategory(Drama drama, Iterable<String> categories) {
    final selected = categories
        .map(_normalize)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (selected.isEmpty) return false;
    final labels = <String>{
      drama.category,
      ...drama.tags,
      ..._features(drama),
    }.map(_normalize).where((value) => value.isNotEmpty).toSet();
    final text = _normalize('${drama.title} ${drama.description}');
    for (final category in selected) {
      if (labels.contains(category) || text.contains(category)) return true;
      if (category == 'ai剧' &&
          (labels.contains('ai短剧') ||
              labels.contains('ai漫剧') ||
              text.contains('ai短剧') ||
              text.contains('ai漫剧'))) {
        return true;
      }
      if (category == '漫剧' &&
          (labels.contains('ai漫剧') || text.contains('ai漫剧'))) {
        return true;
      }
    }
    return false;
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[·•_\-—]'), '')
      .replaceAll('ai短剧', 'ai剧')
      .replaceAll('ai漫剧', '漫剧');

  static double _heat(String heat, String views) {
    final heatValue = _parseCount(heat);
    final viewValue = _parseCount(views);
    final primary = heatValue ?? viewValue;
    if (primary == null) return .35;
    return (math.log(1 + primary) / math.log(1 + 100000000))
        .clamp(0, 1)
        .toDouble();
  }

  static double? _parseCount(String value) {
    final match = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*([万亿kKwW]?)',
    ).firstMatch(value);
    if (match == null) return null;
    final amount = double.tryParse(match.group(1)!);
    if (amount == null) return null;
    final multiplier = switch (match.group(2)?.toLowerCase()) {
      '万' || 'w' => 10000.0,
      '亿' => 100000000.0,
      'k' => 1000.0,
      _ => 1.0,
    };
    return amount * multiplier;
  }

  static double _freshness(String value) {
    final date = DateTime.tryParse(value);
    if (date == null) return .35;
    final days = DateTime.now().difference(date).inDays;
    if (days <= 0) return 1;
    if (days >= 365) return 0;
    return 1 - days / 365;
  }

  static double _duplicatePenalty(
    Drama drama,
    Set<String> features,
    Set<String> recentIds,
    List<Drama> recent,
    List<Set<String>> recentFeatures,
  ) {
    if (recentIds.contains('${drama.source}:${drama.id}')) return 1.25;
    var similar = 0;
    for (var index = 0; index < recent.length; index++) {
      final item = recent[index];
      if (item.source == drama.source && item.title == drama.title) {
        similar++;
        continue;
      }
      final overlap = recentFeatures[index].intersection(features).length;
      if (overlap >= 2) similar++;
    }
    return (similar * .045).clamp(0, .20);
  }

  static double _stableNoise(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash / 0x7fffffff;
  }
}
