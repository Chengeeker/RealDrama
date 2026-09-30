const maxHomeFeedCategoriesPerSource = 4096;

class FeedRecommendationPreferences {
  const FeedRecommendationPreferences({
    this.randomMode = false,
    this.manualWeights = const {},
  });

  final bool randomMode;
  final Map<String, int> manualWeights;

  FeedRecommendationPreferences copyWith({
    bool? randomMode,
    Map<String, int>? manualWeights,
  }) => FeedRecommendationPreferences(
    randomMode: randomMode ?? this.randomMode,
    manualWeights: manualWeights ?? this.manualWeights,
  );

  Map<String, Object> toJson() => {
    'randomMode': randomMode,
    'manualWeights': manualWeights,
  };

  factory FeedRecommendationPreferences.fromJson(Object? value) {
    if (value is! Map) return const FeedRecommendationPreferences();
    final weights = <String, int>{};
    final rawWeights = value['manualWeights'];
    if (rawWeights is Map) {
      for (final entry in rawWeights.entries) {
        if (entry.key is String && entry.value is int) {
          final key = (entry.key as String).trim();
          final weight = entry.value as int;
          if (key.isNotEmpty &&
              key.runes.length <= 128 &&
              weight >= -100 &&
              weight <= 100) {
            weights[key] = weight;
          }
        }
      }
    }
    return FeedRecommendationPreferences(
      randomMode: value['randomMode'] == true,
      manualWeights: Map.unmodifiable(weights),
    );
  }

  static void validateMap(Object? value, {required bool strict}) {
    if (value is! Map || value.length > 2) {
      throw const FormatException('猜你喜欢设置无效');
    }
    if (strict &&
        value.keys.any(
          (key) => !{'randomMode', 'manualWeights'}.contains(key),
        )) {
      throw const FormatException('猜你喜欢设置字段无效');
    }
    if (value['randomMode'] != null && value['randomMode'] is! bool) {
      throw const FormatException('猜你喜欢随机模式无效');
    }
    final weights = value['manualWeights'] ?? const {};
    if (weights is! Map || weights.length > 256) {
      throw const FormatException('猜你喜欢题材权重无效');
    }
    for (final entry in weights.entries) {
      if (entry.key is! String ||
          entry.value is! int ||
          (entry.key as String).trim().isEmpty ||
          (entry.key as String).runes.length > 128 ||
          (entry.value as int) < -100 ||
          (entry.value as int) > 100) {
        throw const FormatException('猜你喜欢题材权重无效');
      }
    }
  }
}

class HomeFeedSourcePreference {
  const HomeFeedSourcePreference({
    this.enabled = false,
    this.categories = const {},
    this.excludedCategories = const {},
    this.categoriesConfigured = false,
  });

  final bool enabled;
  final Map<String, String> categories;
  final Map<String, String> excludedCategories;
  final bool categoriesConfigured;

  HomeFeedSourcePreference copyWith({
    bool? enabled,
    Map<String, String>? categories,
    Map<String, String>? excludedCategories,
    bool? categoriesConfigured,
  }) => HomeFeedSourcePreference(
    enabled: enabled ?? this.enabled,
    categories: categories ?? this.categories,
    excludedCategories: excludedCategories ?? this.excludedCategories,
    categoriesConfigured: categoriesConfigured ?? this.categoriesConfigured,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'categories': categories,
    'excludedCategories': excludedCategories,
    'categoriesConfigured': categoriesConfigured,
  };

  factory HomeFeedSourcePreference.fromJson(Object? value) {
    if (value is! Map) return const HomeFeedSourcePreference();
    final categories = <String, String>{};
    final excludedCategories = <String, String>{};
    for (final (field, target) in [
      ('categories', categories),
      ('excludedCategories', excludedCategories),
    ]) {
      if (value[field] is! Map) continue;
      for (final entry in (value[field] as Map).entries) {
        if (entry.key is String && entry.value is String) {
          final id = (entry.key as String).trim();
          final name = (entry.value as String).trim();
          if (id.isNotEmpty && name.isNotEmpty) target[id] = name;
        }
      }
    }
    return HomeFeedSourcePreference(
      enabled: value['enabled'] == true,
      categories: Map.unmodifiable(categories),
      excludedCategories: Map.unmodifiable(excludedCategories),
      categoriesConfigured: value['categoriesConfigured'] == true,
    );
  }

  static void validateMap(Object? value, {required bool strict}) {
    if (value is! Map || value.length > 32) {
      throw const FormatException('首页偏好站源设置无效');
    }
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('首页偏好站源设置无效');
      }
      final source = entry.key as String;
      final preference = entry.value as Map;
      final categories = preference['categories'] ?? const {};
      final excludedCategories = preference['excludedCategories'] ?? const {};
      if (source.length > 64 ||
          preference['enabled'] is! bool ||
          categories is! Map ||
          categories.length > maxHomeFeedCategoriesPerSource ||
          excludedCategories is! Map ||
          excludedCategories.length > maxHomeFeedCategoriesPerSource) {
        throw const FormatException('首页偏好站源设置无效');
      }
      if (strict &&
          preference.keys.any(
            (key) => !{
              'enabled',
              'categories',
              'excludedCategories',
              'categoriesConfigured',
            }.contains(key),
          )) {
        throw const FormatException('首页偏好站源设置无效');
      }
      if (preference['categoriesConfigured'] != null &&
          preference['categoriesConfigured'] is! bool) {
        throw const FormatException('首页偏好分类状态无效');
      }
      for (final values in [categories, excludedCategories]) {
        for (final category in values.entries) {
          if (category.key is! String ||
              category.value is! String ||
              (category.key as String).trim().isEmpty ||
              (category.key as String).length > 256 ||
              (category.value as String).trim().isEmpty ||
              (category.value as String).runes.length > 100) {
            throw const FormatException('首页偏好分类设置无效');
          }
        }
      }
      if (categories.keys.any(excludedCategories.containsKey)) {
        throw const FormatException('首页偏好分类不能同时启用和排除');
      }
    }
  }
}
