import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'media/android_media_platform.dart';
import 'media/desktop_media_platform.dart';
import 'media/media_platform.dart';
import 'storage/app_settings.dart';
import 'storage/project_store.dart';
import 'storage/store_backend.dart';

const appVersion = '0.2.0';

/// Everything the UI needs from the outside world. Tests build it with
/// in-memory storage and a fake media platform.
class AppServices {
  AppServices({required this.projects, required this.settingsStore, required this.media, AppSettings settings = const AppSettings()})
      : settings = ValueNotifier(settings);

  final ProjectStore projects;
  final SettingsStore settingsStore;
  final MediaPlatform media;
  final ValueNotifier<AppSettings> settings;

  /// Real services: projects in the documents folder (visible on PC),
  /// settings in the app support folder.
  static Future<AppServices> create() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final library = Platform.isAndroid ? Directory('${docs.path}${sep}projects') : Directory('${docs.path}${sep}CUTLAB Projects');
    final settingsStore = SettingsStore(FileBackend(support));
    return AppServices(
      projects: ProjectStore(FileBackend(library)),
      settingsStore: settingsStore,
      media: Platform.isAndroid ? AndroidMediaPlatform() : DesktopMediaPlatform(),
      settings: await settingsStore.load(),
    );
  }

  Future<void> updateSettings(AppSettings s) async {
    settings.value = s;
    await settingsStore.save(s);
  }
}
