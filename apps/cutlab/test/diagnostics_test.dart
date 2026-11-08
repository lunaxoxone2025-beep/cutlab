import 'dart:io';

import 'package:cutlab/src/diagnostics/diagnostics.dart';
import 'package:cutlab/src/storage/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('cutlab_diag'));
  tearDown(() async => dir.delete(recursive: true));

  Diagnostics make([Map<String, Object?> device = const {}]) =>
      Diagnostics(dir, device: device, engine: FakeMediaEngine(), media: FakeMediaPlatform(), version: 'test');

  File crashFile() => File('${dir.path}${Platform.pathSeparator}native-crash.txt');

  test('a native crash during hardware decoding is reported once and turns hardware decoding off', () async {
    crashFile().writeAsStringSync('CUTLAB native crash report\nsignal: SIGSEGV (invalid memory access)\nhardware decoders open: 1\n');
    final d = make();
    await d.collect();
    expect(d.newCrashes, hasLength(1));
    expect(d.newCrashes.single.kind, 'native');
    expect(d.newCrashes.single.duringHardwareDecoding, isTrue);
    expect(crashFile().existsSync(), isFalse, reason: 'moved to the history');
    expect(await d.history(), hasLength(1));

    final s = d.settingsAfterCrashes(const AppSettings());
    expect(s.hardwareDecoding, isFalse);
    expect(d.notice, contains('Hardware video decoding was turned off'));

    final next = make();
    await next.collect();
    expect(next.newCrashes, isEmpty, reason: 'each crash is reported once');
    expect(await next.history(), hasLength(1));
  });

  test('a crash with software decoding keeps hardware decoding on', () async {
    crashFile().writeAsStringSync('CUTLAB native crash report\nsignal: SIGABRT (abort)\nhardware decoders open: 0\n');
    final d = make();
    await d.collect();
    expect(d.newCrashes, hasLength(1));
    const settings = AppSettings();
    expect(identical(d.settingsAfterCrashes(settings), settings), isTrue);
    expect(d.notice, isNull);
  });

  test('Android records: a low-memory kill is reported, a hardware-test process crash is only kept', () async {
    final d = make({
      'exits': [
        {'timeMs': 1000, 'reason': 'killed: low memory', 'process': 'com.lunaxoxone.studio.cutlab', 'importance': 100, 'pssKB': 900000},
        {'timeMs': 2000, 'reason': 'native crash', 'process': 'com.lunaxoxone.studio.cutlab:hwprobe', 'trace': 'SIGSEGV libc2.so'},
      ],
    });
    await d.collect();
    expect(d.newCrashes, hasLength(1));
    expect(d.newCrashes.single.lowMemory, isTrue);
    expect(await d.history(), hasLength(2));
    final report = await d.report();
    expect(report, contains('killed: low memory'));
    expect(report, contains('SIGSEGV libc2.so'));
  });

  test('errors go to the log and into the report', () async {
    final d = make({'platform': 'test', 'decoders': ['c2.test.avc.decoder video/avc HW']});
    d.log('dart', 'something broke', StackTrace.current);
    final report = await d.report();
    expect(report, contains('something broke'));
    expect(report, contains('c2.test.avc.decoder'));
    await d.clearHistory();
    expect(await d.report(), isNot(contains('something broke')));
  });
}
