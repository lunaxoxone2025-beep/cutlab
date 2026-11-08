# Building CUTLAB

| Part | Toolchain | Command |
|---|---|---|
| C++ core | CMake ≥ 3.16, a C++17 compiler (GCC 9+, Clang 10+, MSVC 2019+) | see below |
| `.cutlab` format package | Flutter 3.24.5 (Dart 3.5) | `dart test` |
| Flutter app | Flutter 3.24.5 + platform SDKs | `flutter run` |
| CutLab Lite | any static web server; Node 20 + JDK 17 for the APK | see below |

CI pins **Flutter 3.24.5**; use the same version locally to avoid analyzer/formatter differences.

## C++ core

```bash
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Release -DCUTLAB_WARNINGS_AS_ERRORS=ON
cmake --build build/core --config Release
ctest --test-dir build/core -C Release --output-on-failure
```

Produces the shared library `cutlab_core` (`.so` / `.dll` / `.dylib`) and the `cutlab_core_tests` executable. The tests have no external dependencies.

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

- **Android:** Android SDK (API 34), JDK 17. `flutter build apk --debug`. Release builds are signed with the debug key until a release keystore is configured as a CI secret (Phase 10).
- **Linux:** `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`. `flutter build linux`.
- **Windows:** Visual Studio 2022 with "Desktop development with C++". `flutter build windows`.
- **macOS:** Xcode 15+. `flutter build macos`. Builds are unsigned (Gatekeeper will warn) until notarization is set up.

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
| `ci.yml` | every push / PR | hygiene (no binaries > 5 MB, YAML valid), Lite JS checks, C++ build + tests on Linux/Windows/macOS, Dart format/analyze/test, Flutter analyze/test |
| `flutter-build.yml` | changes to `apps/cutlab`, `packages`, `core` | Android debug APK, release APK and AAB; Linux, Windows and macOS release builds — uploaded as **workflow artifacts** |
| `lite-apk.yml` | changes to `apps/web` | builds `CutLab.apk` (Lite) and publishes a GitHub Release |
| `dart-format.yml` | pushes with `.dart` changes | formats Dart code and commits the result |

Artifacts from `flutter-build.yml` are development builds; stable releases go to GitHub Releases from Phase 10.
