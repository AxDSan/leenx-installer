#!/usr/bin/env dart
// Standalone CLI for Leenx Installer — no Flutter dependency.
// Build: dart compile exe bin/leenx.dart -o ~/.local/bin/leenx

import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class _Progress {
  final double value;
  final String phase;
  final _Result? result;
  _Progress(this.value, this.phase, {this.result});
}

class _Result {
  final String appName;
  final String appDir;
  final String desktopFile;
  _Result(this.appName, this.appDir, this.desktopFile);
}

class _Service {
  static const _supported = ['.tar.gz', '.tgz', '.tar.bz2', '.tar.xz', '.zip', '.appimage'];

  static String? _detectExt(String name) {
    final lower = name.toLowerCase();
    for (final ext in _supported) {
      if (lower.endsWith(ext)) return ext;
    }
    return null;
  }

  static String _stripExt(String name) {
    return name.replaceAll(
      RegExp(r'\.(tar\.gz|tar\.xz|tar\.bz2|tgz|zip|appimage)$', caseSensitive: false),
      '',
    );
  }

  static String _humanize(String s) {
    return s
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  static void _rmDir(Directory d) {
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  static Stream<_Progress> install({
    required String srcPath,
    required String home,
    required String appsDir,
    required String binDir,
  }) async* {
    final srcName = p.basename(srcPath);
    final ext = _detectExt(srcName);
    if (ext == null) {
      throw FormatException('Unsupported file type: $srcName');
    }

    final appName = _stripExt(srcName);
    final appDirPath = p.join(appsDir, appName);
    final appDir = Directory(appDirPath);
    final desktopFile = p.join(home, '.local', 'share', 'applications', 'installer-$appName.desktop');

    if (appDir.existsSync()) {
      throw StateError('"$appName" is already installed. Uninstall it first.');
    }

    yield _Progress(0.05, 'Preparing destination…');
    appDir.createSync(recursive: true);
    File(desktopFile).parent.createSync(recursive: true);
    String? launcherPath;

    if (ext == '.appimage') {
      Directory(binDir).createSync(recursive: true);
      yield _Progress(0.15, 'Copying AppImage…');
      final target = p.join(binDir, appName);
      File(srcPath).copySync(target);
      Process.runSync('chmod', ['+x', target]);
      launcherPath = target;
      yield _Progress(0.9, 'Creating launcher…');
      _writeDesktop(desktopFile, appName, target);
    } else {
      yield _Progress(0.1, 'Reading archive…');
      late Archive archive;
      try {
        if (ext == '.zip') {
          final bytes = File(srcPath).readAsBytesSync();
          archive = ZipDecoder().decodeBytes(bytes);
        } else {
          final input = InputFileStream(srcPath);
          final out = OutputMemoryStream();
          if (ext == '.tar.gz' || ext == '.tgz') {
            GZipDecoder().decodeStream(input, out);
          } else if (ext == '.tar.bz2') {
            BZip2Decoder().decodeStream(input, out);
          } else if (ext == '.tar.xz') {
            XZDecoder().decodeStream(input, out);
          }
          input.closeSync();
          archive = TarDecoder().decodeStream(InputMemoryStream(out.getBytes()));
        }
      } catch (e) {
        _rmDir(appDir);
        throw Exception('Could not read archive: $e');
      }

      final entries = archive.files.where((f) => f.isFile).toList();
      final total = entries.isEmpty ? 1 : entries.length;
      yield _Progress(0.15, 'Extracting 0/${entries.length}');

      for (int i = 0; i < entries.length; i++) {
        final entry = entries[i];
        if (!entry.isFile) continue;
        final outPath = p.join(appDirPath, entry.name);
        try {
          final outFile = File(outPath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(entry.readBytes()!);
          final mode = entry.mode & 0xFFF;
          if (mode != 0) {
            Process.runSync('chmod', [mode.toRadixString(8), outPath]);
          }
        } catch (e) {
          _rmDir(appDir);
          throw Exception('Failed to extract "${entry.name}": $e');
        }
        if (i % 8 == 0 || i == entries.length - 1) {
          yield _Progress(0.15 + 0.70 * ((i + 1) / total), 'Extracting ${i + 1}/${entries.length}');
        }
      }

      yield _Progress(0.88, 'Creating launcher…');
      final exec = _findExecutable(appDir);
      if (exec != null) {
        _writeDesktop(desktopFile, appName, exec);
      } else {
        _writeDesktop(desktopFile, appName, 'xdg-open .');
      }
    }

    try {
      Process.runSync('update-desktop-database', [
        p.join(home, '.local', 'share', 'applications'),
      ]);
    } catch (_) {}

    yield _Progress(1.0, 'Done', result: _Result(appName, appDirPath, desktopFile));
  }

  static String? _findExecutable(Directory dir) {
    try {
      final candidates = <String>[];
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: dir.path);
          if (rel.split(p.separator).any((s) => s == 'lib' || s == 'runtime')) continue;
          final stat = entity.statSync();
          if ((stat.mode & 0x49) != 0) candidates.add(entity.path);
        }
      }
      if (candidates.isEmpty) return null;
      final dirName = p.basename(dir.path);
      candidates.sort((a, b) {
        final aMatch = p.basename(a).contains(dirName) ? 0 : 1;
        final bMatch = p.basename(b).contains(dirName) ? 0 : 1;
        return aMatch.compareTo(bMatch);
      });
      return candidates.first;
    } catch (_) {
      return null;
    }
  }

  static void _writeDesktop(String path, String name, String exec) {
    final content = '''[Desktop Entry]
Version=1.0
Type=Application
Name=${_humanize(name)}
Comment=Installed by leenx
Exec=$exec
Terminal=false
Categories=Utility;
''';
    File(path).writeAsStringSync(content);
  }
}

void main(List<String> args) {
  if (args.length < 2 || args[0] != 'install') {
    stderr.writeln('Usage: leenx install <archive>');
    exitCode = 1;
    return;
  }
  final src = args[1];
  if (!File(src).existsSync()) {
    stderr.writeln('File not found: $src');
    exitCode = 1;
    return;
  }
  final home = Platform.environment['HOME'] ?? '/tmp';

  _Service.install(
    srcPath: src,
    home: home,
    appsDir: p.join(home, '.local', 'share', 'installer-apps'),
    binDir: p.join(home, '.local', 'bin'),
  ).listen(
    (p) {
      stderr.write('\r${(p.value * 100).toInt()}%  ${p.phase}');
      if (p.result != null) {
        stderr.writeln();
        print('Installed "${p.result!.appName}" to ${p.result!.appDir}');
        print('Launcher: ${p.result!.desktopFile}');
      }
    },
    onError: (e) {
      stderr.writeln('\nError: $e');
      exitCode = 1;
    },
    onDone: () => exit(exitCode),
  );
}
