import 'dart:convert';

import 'package:cutlab_project_format/cutlab_project_format.dart';

import 'store_backend.dart';

/// User preferences that apply to the whole app.
class AppSettings {
  const AppSettings({this.defaultMode = EditorMode.beginner, this.autosaveSeconds = 10});

  /// Mode used for new projects.
  final EditorMode defaultMode;

  /// Delay after the last edit before unsaved changes are written to the
  /// recovery file.
  final int autosaveSeconds;

  static const autosaveChoices = [5, 10, 30, 60];

  AppSettings copyWith({EditorMode? defaultMode, int? autosaveSeconds}) =>
      AppSettings(defaultMode: defaultMode ?? this.defaultMode, autosaveSeconds: autosaveSeconds ?? this.autosaveSeconds);

  Map<String, Object?> toJson() => {'defaultMode': defaultMode.name, 'autosaveSeconds': autosaveSeconds};

  /// Lenient: unknown or broken values fall back to defaults.
  static AppSettings fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const AppSettings();
    final mode = EditorMode.values.where((m) => m.name == json['defaultMode']).firstOrNull ?? EditorMode.beginner;
    final secs = json['autosaveSeconds'];
    return AppSettings(defaultMode: mode, autosaveSeconds: secs is int && secs >= 1 && secs <= 3600 ? secs : 10);
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
