// Unit tests for the installer service. Exercises the real extract + .desktop
// writing pipeline against a sample tar.gz fixture and an isolated fake home.

import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:leenx_installer/main.dart';

Directory _makeFakeHome(String tag) {
  final root = Directory(p.join(
    Directory.systemTemp.path,
    'flutter_installer_test_$tag',
  ));
  if (root.existsSync()) root.deleteSync(recursive: true);
  root.createSync(recursive: true);
  Directory(p.join(root.path, '.local', 'share')).createSync(recursive: true);
  return root;
}

void main() {
  test('extracts a tar.gz to ~/.local/share and writes a .desktop file',
      () async {
    final source = XFile('/tmp/sample-app.tar.gz');
    final home = _makeFakeHome('install');
    final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
    final bin = Directory(p.join(home.path, '.local', 'bin'));

    final svc = InstallerService();
    InstallResult? result;
    final phases = <String>[];
    await for (final p in svc.install(
      source: source,
      home: home,
      appsDir: apps,
      binDir: bin,
    )) {
      phases.add(p.phase);
      if (p.result != null) result = p.result;
    }

    expect(result, isNotNull);
    expect(result!.appName, 'sample-app');
    expect(result!.appDir, p.join(apps.path, 'sample-app'));
    expect(result!.desktopFile,
        p.join(home.path, '.local', 'share', 'applications', 'installer-sample-app.desktop'));

    // Files extracted (the tarball contains a top-level sample-app/ folder,
    // so the real path is sample-app/sample-app/...)
    final readme = File(p.join(apps.path, 'sample-app', 'sample-app', 'README.md'));
    expect(readme.existsSync(), isTrue);
    expect(readme.readAsStringSync().contains('Sample App'), isTrue);

    // Executable preserved
    final binFile = File(p.join(apps.path, 'sample-app', 'sample-app', 'bin', 'sample-app'));
    expect(binFile.existsSync(), isTrue);
    // .desktop file written
    final desktop = File(result!.desktopFile);
    expect(desktop.existsSync(), isTrue);
    final contents = desktop.readAsStringSync();
    expect(contents.contains('[Desktop Entry]'), isTrue);
    expect(contents.contains('Name=Sample App'), isTrue);
    expect(contents.contains('Exec='), isTrue);

    // Progress reached 1.0 and reported multiple phases
    expect(phases, contains('Reading archive…'));
    expect(phases.last, 'Done');

    // Clean up
    await svc.uninstall(result!);
    expect(Directory(result!.appDir).existsSync(), isFalse);
    expect(File(result!.desktopFile).existsSync(), isFalse);
  });

  test('rejects an unsupported file extension', () async {
    final src = File(p.join(Directory.systemTemp.path, 'fake.iso'));
    src.writeAsStringSync('not an installer');
    final home = _makeFakeHome('unsupported');
    final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
    final bin = Directory(p.join(home.path, '.local', 'bin'));

    final svc = InstallerService();
    expect(
      () => svc.install(
        source: XFile(src.path),
        home: home,
        appsDir: apps,
        binDir: bin,
      ).drain(),
      throwsA(isA<InstallerException>()
          .having((e) => e.message, 'message', contains('Unsupported'))),
    );
    src.deleteSync();
  });

  test('rejects an .apk file (Android package, not supported)', () async {
    // Use a small synthetic "apk" so we don't depend on a real download.
    final src = File(p.join(Directory.systemTemp.path, 'fake.apk'));
    src.writeAsStringSync('PK\x03\x04not a real apk');

    final home = _makeFakeHome('apk');
    final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
    final bin = Directory(p.join(home.path, '.local', 'bin'));

    final svc = InstallerService();
    expect(
      () => svc.install(
        source: XFile(src.path),
        home: home,
        appsDir: apps,
        binDir: bin,
      ).drain(),
      throwsA(isA<InstallerException>().having(
        (e) => e.message,
        'message',
        contains('Unsupported'),
      )),
    );
    // Verify nothing was created on disk
    expect(apps.existsSync(), isFalse);
    expect(bin.existsSync(), isFalse);
    src.deleteSync();
  });

  test('refuses to overwrite an already-installed app', () async {
    final source = XFile('/tmp/sample-app.tar.gz');
    final home = _makeFakeHome('overwrite');
    final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
    final bin = Directory(p.join(home.path, '.local', 'bin'));
    apps.createSync(recursive: true);
    Directory(p.join(apps.path, 'sample-app')).createSync(recursive: true);

    final svc = InstallerService();
    expect(
      () => svc.install(
        source: source,
        home: home,
        appsDir: apps,
        binDir: bin,
      ).drain(),
      throwsA(isA<InstallerException>().having(
        (e) => e.message,
        'message',
        contains('already installed'),
      )),
    );
  });

  group('AppsRegistry', () {
    test('returns empty when appsDir is missing', () async {
      final home = _makeFakeHome('reg_empty');
      final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
      final appsDir = Directory(p.join(home.path, '.local', 'share', 'applications'));
      final reg = AppsRegistry(appsDir: apps, applicationsDir: appsDir);
      expect(await reg.scan(), isEmpty);
    });

    test('lists installed apps with their desktop files', () async {
      final home = _makeFakeHome('reg_listed');
      final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
      final applications = Directory(p.join(home.path, '.local', 'share', 'applications'));
      apps.createSync(recursive: true);
      applications.createSync(recursive: true);
      Directory(p.join(apps.path, 'foo')).createSync();
      File(p.join(applications.path, 'installer-foo.desktop'))
          .writeAsStringSync('[Desktop Entry]\nName=Foo\n');

      final reg = AppsRegistry(appsDir: apps, applicationsDir: applications);
      final list = await reg.scan();
      expect(list, hasLength(1));
      expect(list.first.name, 'foo');
      expect(list.first.launcherExists, isTrue);
      expect(list.first.desktopFile,
          p.join(applications.path, 'installer-foo.desktop'));
    });

    test('marks apps whose .desktop is missing', () async {
      final home = _makeFakeHome('reg_missing');
      final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
      final applications = Directory(p.join(home.path, '.local', 'share', 'applications'));
      apps.createSync(recursive: true);
      applications.createSync(recursive: true);
      Directory(p.join(apps.path, 'orphan')).createSync();

      final reg = AppsRegistry(appsDir: apps, applicationsDir: applications);
      final list = await reg.scan();
      expect(list, hasLength(1));
      expect(list.first.name, 'orphan');
      expect(list.first.launcherExists, isFalse);
      expect(list.first.desktopFile, isNull);
    });

    test('sorts newest first', () async {
      final home = _makeFakeHome('reg_sort');
      final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
      final applications = Directory(p.join(home.path, '.local', 'share', 'applications'));
      apps.createSync(recursive: true);
      applications.createSync(recursive: true);
      Directory(p.join(apps.path, 'older')).createSync();
      Directory(p.join(apps.path, 'newer')).createSync();
      // Use touch -d to set mtime (sync touch via Process)
      final now = DateTime.now();
      final past = now.subtract(const Duration(days: 7));
      await Process.run('touch', [
        '-d',
        past.toIso8601String(),
        p.join(apps.path, 'older')
      ]);
      await Process.run('touch', [
        '-d',
        now.toIso8601String(),
        p.join(apps.path, 'newer')
      ]);

      final reg = AppsRegistry(appsDir: apps, applicationsDir: applications);
      final list = await reg.scan();
      expect(list.map((e) => e.name).toList(), ['newer', 'older']);
    });

    test('uninstall refuses to delete a running app', () async {
      // Install sample-app into a fake home
      final source = XFile('/tmp/sample-app.tar.gz');
      final home = _makeFakeHome('running');
      final apps = Directory(p.join(home.path, '.local', 'share', 'installer-apps'));
      final bin = Directory(p.join(home.path, '.local', 'bin'));
      final svc = InstallerService();
      InstallResult? result;
      await for (final p in svc.install(
        source: source,
        home: home,
        appsDir: apps,
        binDir: bin,
      )) {
        if (p.result != null) result = p.result;
      }
      expect(result, isNotNull);

      // Copy /bin/sleep into the app dir and run it from there. The
      // /proc/<pid>/exe symlink for a direct binary invocation resolves
      // to the binary path itself, not to the script interpreter.
      final appBin = Directory(p.join(apps.path, 'sample-app', 'sample-app', 'bin'));
      final localSleep = File(p.join(appBin.path, 'sleep-copy'));
      await Process.run('cp', ['/bin/sleep', localSleep.path]);
      await Process.run('chmod', ['+x', localSleep.path]);

      final proc = await Process.start(
        localSleep.path,
        ['60'],
        mode: ProcessStartMode.detached,
      );
      // Give it a moment to start and expose its /proc/<pid>/exe
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        () => svc.uninstall(result!),
        throwsA(isA<InstallerException>().having(
          (e) => e.message,
          'message',
          allOf(contains('currently running'), contains('sample-app')),
        )),
      );

      // Clean up
      proc.kill();
      // Wait for the process to actually exit so the second uninstall succeeds
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await svc.uninstall(result!);
      expect(Directory(result!.appDir).existsSync(), isFalse);
    });
  });
}
