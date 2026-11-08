import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics/diagnostics.dart';
import 'engine/ffi_media_engine.dart';
import 'engine/media_engine.dart';
import 'media/android_media_platform.dart';
import 'media/desktop_media_platform.dart';
import 'media/media_platform.dart';
import 'storage/app_settings.dart';
import 'storage/project_store.dart';
import 'storage/store_backend.dart';

const appVersion = '0.5.0';

/// Everything the UI needs from the outside world. Tests build it with
/// in-memory storage and a fake media platform.
class AppServices {
  AppServices({
    required this.projects,
    required this.settingsStore,
    required this.media,
    MediaEngine? engine,
    AppSettings settings = const AppSettings(),
    this.diagnostics,
  })  : engine = engine ?? UnavailableMediaEngine(),
        settings = ValueNotifier(settings);

  final ProjectStore projects;
  final SettingsStore settingsStore;
  final MediaPlatform media;
  final MediaEngine engine;
  final ValueNotifier<AppSettings> settings;

  /// Crash reports and device information (null in tests).
  final Diagnostics? diagnostics;

  /// Real services: projects in the documents folder (visible on PC),
  /// settings in the app support folder.
  static Future<AppServices> create() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    final library = Platform.isAndroid ? Directory('${docs.path}${sep}projects') : Directory('${docs.path}${sep}CUTLAB Projects');
    final settingsStore = SettingsStore(FileBackend(support));
    final MediaPlatform media = Platform.isAndroid ? AndroidMediaPlatform() : DesktopMediaPlatform();
    final engine = FfiMediaEngine.load();
    Diagnostics? diagnostics;
    try {
      diagnostics = await Diagnostics.start(engine: engine, media: media, appVersion: appVersion);
    } on Object {
      diagnostics = null; // the editor must start even if diagnostics cannot
    }
    final loaded = await settingsStore.load();
    // CUTLAB closed while a hardware video decoder was in use: do not risk
    // it again until the user decides to.
    final settings = diagnostics?.settingsAfterCrashes(loaded) ?? loaded;
    if (!identical(settings, loaded)) await settingsStore.save(settings);
    return AppServices(
      projects: ProjectStore(FileBackend(library)),
      settingsStore: settingsStore,
      media: media,
      engine: engine,
      settings: settings,
      diagnostics: diagnostics,
    );
  }

  Future<void> updateSettings(AppSettings s) async {
    settings.value = s;
    await settingsStore.save(s);
  }
}
