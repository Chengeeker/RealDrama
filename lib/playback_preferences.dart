const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];

enum HardwareDecoder {
  automatic('自动（安全）', 'auto-safe'),
  copy('自动（复制）', 'auto-copy'),
  mediaCodec('MediaCodec', 'mediacodec'),
  mediaCodecCopy('MediaCodec（复制）', 'mediacodec-copy'),
  d3d11('D3D11', 'd3d11va'),
  d3d11Copy('D3D11（复制）', 'd3d11va-copy');

  const HardwareDecoder(this.label, this.mpvValue);
  final String label;
  final String mpvValue;
}

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.homeQuality = 0,
    this.autoAdvance = true,
    this.preload = true,
    this.hardwareDecoding = true,
    this.hardwareDecoder = HardwareDecoder.automatic,
    this.lowMemory = false,
  });

  final double speed;
  final int quality;
  final int homeQuality;
  final bool autoAdvance;
  final bool preload;
  final bool hardwareDecoding;
  final HardwareDecoder hardwareDecoder;
  final bool lowMemory;
  int get bufferBytes => (lowMemory ? 2 : 32) * 1024 * 1024;

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    int? homeQuality,
    bool? autoAdvance,
    bool? preload,
    bool? hardwareDecoding,
    HardwareDecoder? hardwareDecoder,
    bool? lowMemory,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    homeQuality: homeQuality ?? this.homeQuality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    preload: preload ?? this.preload,
    hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
    hardwareDecoder: hardwareDecoder ?? this.hardwareDecoder,
    lowMemory: lowMemory ?? this.lowMemory,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'homeQuality': homeQuality,
    'autoAdvance': autoAdvance,
    'preload': preload,
    'hardwareDecoding': hardwareDecoding,
    'hardwareDecoder': hardwareDecoder.name,
    'lowMemory': lowMemory,
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final homeQuality = value['homeQuality'] as int? ?? 0;
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final preload = value['preload'] as bool? ?? true;
    if (!playbackSpeeds.contains(speed) ||
        quality < 0 ||
        quality > 4320 ||
        homeQuality < 0 ||
        homeQuality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    return PlaybackPreferences(
      speed: speed,
      quality: quality,
      homeQuality: homeQuality,
      autoAdvance: autoAdvance,
      preload: preload,
      hardwareDecoding: value['hardwareDecoding'] != false,
      hardwareDecoder:
          HardwareDecoder.values
              .where((item) => item.name == value['hardwareDecoder'])
              .firstOrNull ??
          HardwareDecoder.automatic,
      lowMemory: value['lowMemory'] == true,
    );
  }
}
