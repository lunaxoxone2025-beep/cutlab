import 'dart:convert';

import 'package:cutlab_project_format/cutlab_project_format.dart';

import 'store_backend.dart';

/// User preferences that apply to the whole app.
class AppSettings {
  const AppSettings({
    this.defaultMode = EditorMode.beginner,
    this.autosaveSeconds = 10,
    this.previewHeight = 720,
    this.hardwareDecoding = true,
    this.fastEffectsPreview = false,
  });

  /// Mode used for new projects.
  final EditorMode defaultMode;

  /// Delay after the last edit before unsaved changes are written to the
  /// recovery file.
  final int autosaveSeconds;

  /// Preview resolution (lines). Lower is lighter for mid-range phones.
  final int previewHeight;

  /// Use the GPU/hardware video decoder when the device has one.
  final bool hardwareDecoding;

  /// Compose effects and transitions at a low size in the preview, for
  /// heavy effects on slower devices. Exports are not affected.
  final bool fastEffectsPreview;

  static const autosaveChoices = [5, 10, 30, 60];
  static const previewChoices = [360, 540, 720, 1080];

  /// Preview size limits for the current quality (16:9 box, either orientation).
  int get previewMaxWidth => previewHeight * 16 ~/ 9;
  int get previewMaxHeight => previewHeight * 16 ~/ 9;

  AppSettings copyWith(
          {EditorMode? defaultMode, int? autosaveSeconds, int? previewHeight, bool? hardwareDecoding, bool? fastEffectsPreview}) =>
      AppSettings(
        defaultMode: defaultMode ?? this.defaultMode,
        autosaveSeconds: autosaveSeconds ?? this.autosaveSeconds,
        previewHeight: previewHeight ?? this.previewHeight,
        hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
        fastEffectsPreview: fastEffectsPreview ?? this.fastEffectsPreview,
      );

  Map<String, Object?> toJson() => {
        'defaultMode': defaultMode.name,
        'autosaveSeconds': autosaveSeconds,
        'previewHeight': previewHeight,
        'hardwareDecoding': hardwareDecoding,
        'fastEffectsPreview': fastEffectsPreview,
      };

  /// Lenient: unknown or broken values fall back to defaults.
  static AppSettings fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const AppSettings();
    final mode = EditorMode.values.where((m) => m.name == json['defaultMode']).firstOrNull ?? EditorMode.beginner;
    final secs = json['autosaveSeconds'];
    final preview = json['previewHeight'];
    return AppSettings(
      defaultMode: mode,
      autosaveSeconds: secs is int && secs >= 1 && secs <= 3600 ? secs : 10,
      previewHeight: preview is int && previewChoices.contains(preview) ? preview : 720,
      hardwareDecoding: json['hardwareDecoding'] != false,
      fastEffectsPreview: json['fastEffectsPreview'] == true,
    );
  }
}

class SettingsStore {
  SettingsStore(this.backend);

  static const fileName = 'settings.json';
  final StoreBackend backend;

  Future<AppSettings> load() async {
    try {
      final text = await backend.read(fileName);
      return text == null ? const AppSettings() : AppSettings.fromJson(jsonDecode(text));
    } on Object {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings s) => backend.writeAtomic(fileName, jsonEncode(s.toJson()));
}
