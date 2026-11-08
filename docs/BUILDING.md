# Building CUTLAB

| Part | Toolchain | Command |
|---|---|---|
| C++ core | CMake ≥ 3.16, a C++17 compiler (GCC 9+, Clang 10+, MSVC 2019+) | see below |
| `.cutlab` format package | Flutter 3.24.5 (Dart 3.5) | `dart test` |
| Flutter app | Flutter 3.24.5 + platform SDKs | `flutter run` |
| CutLab Lite | any static web server; Node 20 + JDK 17 for the APK | see below |

CI pins **Flutter 3.24.5**; use the same version locally to avoid analyzer/formatter differences.

## C++ core and media engine

Without FFmpeg (time math only; media calls report "unavailable"):

```bash
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Release -DCUTLAB_WARNINGS_AS_ERRORS=ON
cmake --build build/core --config Release
ctest --test-dir build/core -C Release --output-on-failure
```

With the media engine (Linux; needs `nasm`, `zlib1g-dev`, and `git` to fetch FFmpeg 8.1.3 and miniaudio):

```bash
scripts/ffmpeg/build_ffmpeg.sh linux-x64 build/ffmpeg-linux        # ~10 min on 2 cores
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Release -DCUTLAB_WITH_MEDIA=ON -DCUTLAB_FFMPEG_ROOT=$PWD/build/ffmpeg-linux
cmake --build build/core -j
scripts/make_test_media.sh build/test-media                         # needs the ffmpeg CLI with libx264
CUTLAB_TEST_MEDIA=$PWD/build/test-media ctest --test-dir build/core --output-on-failure
```

Android arm64: `ANDROID_NDK_HOME=… scripts/ffmpeg/build_ffmpeg.sh android-arm64 build/ffmpeg-android`, then configure `core` with the NDK toolchain (`-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static`) and copy `libcutlab_core.so` to `apps/cutlab/android/app/src/main/jniLibs/arm64-v8a/`.

Windows x64 (Developer PowerShell for VS 2022): `scripts/ffmpeg/fetch_ffmpeg_windows.ps1 -Dest build/ffmpeg-win64`, configure with `-DCUTLAB_WITH_MEDIA=ON -DCUTLAB_FFMPEG_SHARED=ON -DCUTLAB_FFMPEG_ROOT=…/build/ffmpeg-win64`, and put `cutlab_core.dll` plus the FFmpeg DLLs next to `cutlab.exe`.

`.github/workflows/flutter-build.yml` does all of this automatically.

## Dart format package

```bash
cd packages/project_format
dart pub get
dart format --line-length 140 .
dart analyze --fatal-infos
dart test
```

## Flutter app

Platform folders are not committed yet (see ARCHITECTURE D13). Generate the ones you need once:

```bash
cd apps/cutlab
flutter create --platforms=android,linux,windows,macos --org com.lunaxoxone.studio --project-name cutlab .
flutter pub get
flutter test
flutter run            # pick a device
```

`flutter create` only adds missing files; it does not overwrite `lib/`, `test/` or `pubspec.yaml`.

### Platform requirements

- **Android:** Android SDK (API 34), NDK, JDK 17. Copy `platform_overlay/android/.` into `android/` after `flutter create`, set `minSdk = 24`, add the engine to `jniLibs`, then `flutter build apk --target-platform android-arm64`. Signed with `android-signing/cutlab.keystore` (copied to `~/.android/debug.keystore`) so updates install in place.
- **Windows:** Visual Studio 2022 with "Desktop development with C++". `flutter build windows`, then add the engine DLLs.
- **Linux:** `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`. `flutter build linux`, then copy `libcutlab_core.so` into `bundle/lib/`.

Application id of the Flutter edition: `com.lunaxoxone.studio.cutlab` — different from CutLab Lite (`com.lunaxoxone.cutlab`) so both can be installed together during development.

## CutLab Lite

Serve `apps/web/` over HTTP(S) (service workers need HTTPS or `localhost`):

```bash
python3 -m http.server -d apps/web 8080
```

The Android APK is built by `.github/workflows/lite-apk.yml` (Capacitor 6 + `@capacitor/filesystem` + `@capacitor/share`) and published to Releases as `CutLab.apk`.

## Continuous integration

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | every push / PR | hygiene, Lite JS checks, generated test media, C++ core + media engine tests on Linux and Windows, Dart format/analyze/test, Flutter analyze/test |
| `flutter-build.yml` | changes to `apps/cutlab`, `packages`, `core`, `scripts` | FFmpeg + engine + app for Android (arm64 APK), Windows x64 and Linux x64, published to the rolling **`dev`** release |
| `lite-apk.yml` | changes to `apps/web` | builds `CutLab.apk` (Lite) and publishes a GitHub Release |
| `dart-format.yml` | pushes with `.dart` changes | formats Dart code and commits the result |


