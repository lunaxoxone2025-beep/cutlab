// dart:ffi bindings to the C ABI in core/include/cutlab/cutlab_core.h.
// Hand-written (the surface is small) and kept in sync with that header.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _StatusOutJson = Int32 Function(Pointer<Utf8> uri, Pointer<Pointer<Utf8>> out);
typedef StatusOutJsonDart = int Function(Pointer<Utf8> uri, Pointer<Pointer<Utf8>> out);

class EngineBindings {
  EngineBindings(DynamicLibrary lib)
      : lastError = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('cutlab_last_error'),
        free = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('cutlab_free'),
        closeFd = lib.lookupFunction<Void Function(Int32), void Function(int)>('cutlab_close_fd'),
        engineInfo = lib.lookupFunction<Int32 Function(Pointer<Pointer<Utf8>>), int Function(Pointer<Pointer<Utf8>>)>('cutlab_engine_info'),
        probe = lib.lookupFunction<_StatusOutJson, StatusOutJsonDart>('cutlab_media_probe'),
        frame = lib.lookupFunction<
            Int32 Function(
                Pointer<Utf8>, Int64, Int32, Int32, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>, Pointer<Int64>),
            int Function(Pointer<Utf8>, int, int, int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>,
                Pointer<Int64>)>('cutlab_media_frame'),
        thumbnails = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
                Pointer<Int64>),
            int Function(Pointer<Utf8>, int, int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
                Pointer<Int64>)>('cutlab_media_thumbnails'),
        peaks = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Float>>, Pointer<Int64>),
            int Function(
                Pointer<Utf8>, int, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Float>>, Pointer<Int64>)>('cutlab_media_peaks'),
        playerOpen = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Pointer<Pointer<Void>>),
            int Function(Pointer<Utf8>, int, int, int, Pointer<Pointer<Void>>)>('cutlab_player_open'),
        playerClose = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('cutlab_player_close'),
        playerPlay = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('cutlab_player_play'),
        playerPause = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('cutlab_player_pause'),
        playerPlaying = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('cutlab_player_playing'),
        playerSeek =
            lib.lookupFunction<Void Function(Pointer<Void>, Int64, Int32), void Function(Pointer<Void>, int, int)>('cutlab_player_seek'),
        playerPosition = lib.lookupFunction<Int64 Function(Pointer<Void>), int Function(Pointer<Void>)>('cutlab_player_position'),
        playerDuration = lib.lookupFunction<Int64 Function(Pointer<Void>), int Function(Pointer<Void>)>('cutlab_player_duration'),
        playerFrame = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint8>, Int64, Pointer<Int32>, Pointer<Int32>, Pointer<Int64>),
            int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint8>, int, Pointer<Int32>, Pointer<Int32>,
                Pointer<Int64>)>('cutlab_player_frame'),
        playerStats =
            lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>), int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)>(
                'cutlab_player_stats');

  final Pointer<Utf8> Function() lastError;
  final void Function(Pointer<Void>) free;
  final void Function(int) closeFd;
  final int Function(Pointer<Pointer<Utf8>>) engineInfo;
  final StatusOutJsonDart probe;
  final int Function(Pointer<Utf8>, int, int, int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>, Pointer<Int64>) frame;
  final int Function(Pointer<Utf8>, int, int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>, Pointer<Int64>)
      thumbnails;
  final int Function(Pointer<Utf8>, int, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Float>>, Pointer<Int64>) peaks;
  final int Function(Pointer<Utf8>, int, int, int, Pointer<Pointer<Void>>) playerOpen;
  final void Function(Pointer<Void>) playerClose;
  final void Function(Pointer<Void>) playerPlay;
  final void Function(Pointer<Void>) playerPause;
  final int Function(Pointer<Void>) playerPlaying;
  final void Function(Pointer<Void>, int, int) playerSeek;
  final int Function(Pointer<Void>) playerPosition;
  final int Function(Pointer<Void>) playerDuration;
  final int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint8>, int, Pointer<Int32>, Pointer<Int32>, Pointer<Int64>) playerFrame;
  final int Function(Pointer<Void>, Pointer<Pointer<Utf8>>) playerStats;

  static const statusOk = 0;
  static const statusUnavailable = 4;
  static const flagSoftwareDecode = 1;

  String get lastErrorMessage => lastError().toDartString();

  /// Opens the engine library shipped with the app (null if it is missing).
  /// Each isolate calls this for itself; the OS shares the loaded library.
  static EngineBindings? tryLoad() {
    try {
      return EngineBindings(_open());
    } on Object {
      return null;
    }
  }

  static DynamicLibrary _open() {
    if (Platform.isAndroid) return DynamicLibrary.open('libcutlab_core.so');
    if (Platform.isWindows) return DynamicLibrary.open('cutlab_core.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('libcutlab_core.dylib');
    // Linux bundles keep libraries in lib/ next to the executable.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = File('$exeDir/lib/libcutlab_core.so');
    return DynamicLibrary.open(bundled.existsSync() ? bundled.path : 'libcutlab_core.so');
  }
}
