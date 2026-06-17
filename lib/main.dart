import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const WindowOptions windowOptions = WindowOptions(
    size: Size(820, 580),
    minimumSize: Size(720, 540),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
    title: 'Install Application',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Window icon is set in the C runner (my_application.cc) via
    // gtk_window_set_icon_from_file so every frame and task bar entry
    // shows the correct icon immediately — no Flutter/GTK default.
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const InstallerApp());
}

class InstallerApp extends StatelessWidget {
  const InstallerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Install Application',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: '.AppleSystemUIFont',
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ),
      home: const InstallerWindow(),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Window
// ──────────────────────────────────────────────────────────────────────────────

class InstallerWindow extends StatefulWidget {
  const InstallerWindow({super.key});

  @override
  State<InstallerWindow> createState() => _InstallerWindowState();
}

enum _DemoState { idle, installing, done, error }

class _DemoStateData {
  final XFile? droppedFile;
  final int? droppedSize;
  final _DemoState state;
  final double progress;
  final String phase;
  final InstallResult? result;
  final String? error;
  final String? rejection;
  final int shakeCounter;

  const _DemoStateData({
    this.droppedFile,
    this.droppedSize,
    this.state = _DemoState.idle,
    this.progress = 0,
    this.phase = '',
    this.result,
    this.error,
    this.rejection,
    this.shakeCounter = 0,
  });

  _DemoStateData copyWith({
    XFile? droppedFile,
    int? droppedSize,
    _DemoState? state,
    double? progress,
    String? phase,
    InstallResult? result,
    String? error,
    String? rejection,
    int? shakeCounter,
    bool clearError = false,
    bool clearRejection = false,
    bool clearFile = false,
  }) {
    return _DemoStateData(
      droppedFile: clearFile ? null : (droppedFile ?? this.droppedFile),
      droppedSize: clearFile ? null : (droppedSize ?? this.droppedSize),
      state: state ?? this.state,
      progress: progress ?? this.progress,
      phase: phase ?? this.phase,
      result: result ?? this.result,
      error: clearError ? null : (error ?? this.error),
      rejection: clearRejection ? null : (rejection ?? this.rejection),
      shakeCounter: shakeCounter ?? this.shakeCounter,
    );
  }
}

class _InstallerWindowState extends State<InstallerWindow> {
  _DemoStateData _data = const _DemoStateData();
  bool _isHovering = false;
  bool _showAppsPanel = false;
  bool _appsLoading = false;
  List<_InstalledApp> _apps = const [];
  late final InstallerService _service;
  late final AppsRegistry _registry;
  late final Directory _home;
  late final Directory _share;
  late final Directory _appsDir;
  late final Directory _binDir;
  late final Directory _applicationsDir;

  @override
  void initState() {
    super.initState();
    _service = InstallerService();
    _home = Directory(Platform.environment['HOME'] ?? '/tmp');
    _share = Directory(p.join(_home.path, '.local', 'share'));
    _appsDir = Directory(p.join(_share.path, 'installer-apps'));
    _binDir = Directory(p.join(_home.path, '.local', 'bin'));
    _applicationsDir = Directory(p.join(_share.path, 'applications'));
    _registry = AppsRegistry(appsDir: _appsDir, applicationsDir: _applicationsDir);
    // Fire and forget; we don't block startup.
    _refreshApps();
  }

  Future<void> _onDropDone(DropDoneDetails details) async {
    if (_data.state == _DemoState.installing) return;
    final files = details.files;
    if (files.isEmpty) return;
    final file = files.first;

    // Validate on drop: surface rejections immediately so the user gets
    // feedback before they bother clicking Install. Triggers a shake on the
    // source card.
    final ext = InstallerService.detectExt(file.name);
    if (ext == null) {
      final actual = p.extension(file.name).toLowerCase();
      final hint = actual.isEmpty
          ? '(no file extension)'
          : '"$actual"';
      setState(() {
        _data = _data.copyWith(
          rejection: 'Unsupported file type $hint. Drop a .tar.gz, .zip, or .AppImage.',
          shakeCounter: _data.shakeCounter + 1,
        );
      });
      // Auto-clear the rejection after a few seconds so the card returns
      // to the empty "drop here" state if the user doesn't try again.
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        if (_data.rejection != null) {
          setState(() => _data = _data.copyWith(clearRejection: true));
        }
      });
      return;
    }

    final stat = await File(file.path).stat();
    setState(() {
      _data = _data.copyWith(
        droppedFile: file,
        droppedSize: stat.size,
        state: _DemoState.idle,
        clearError: true,
        clearRejection: true,
      );
    });
  }

  Future<void> _startInstall() async {
    final file = _data.droppedFile;
    if (file == null) return;

    setState(() {
      _data = _data.copyWith(
        state: _DemoState.installing,
        progress: 0,
        phase: 'Preparing…',
        clearError: true,
      );
    });

    try {
      final stream = _service.install(
        source: file,
        home: _home,
        appsDir: _appsDir,
        binDir: _binDir,
      );
      await for (final p in stream) {
        if (!mounted) return;
        setState(() {
          _data = _data.copyWith(
            progress: p.value,
            phase: p.phase,
            result: p.result,
            state: p.result != null ? _DemoState.done : _DemoState.installing,
          );
        });
      }
      // Refresh the apps list so the sidebar (and the title bar badge) reflect
      // the new install.
      await _refreshApps();
    } on InstallerException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = _data.copyWith(
          state: _DemoState.error,
          error: e.message,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _data = _data.copyWith(
          state: _DemoState.error,
          error: e.toString(),
        );
      });
    }
  }

  Future<void> _reset() async {
    setState(() {
      _data = const _DemoStateData();
    });
  }

  Future<void> _uninstall() async {
    final r = _data.result;
    if (r == null) return;
    final confirmed = await showAnimatedUninstallDialog(
      context,
      appName: r.appName,
      appDir: r.appDir,
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.uninstall(r);
      if (!mounted) return;
      setState(() {
        _data = const _DemoStateData();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _data = _data.copyWith(
          state: _DemoState.error,
          error: 'Uninstall failed: $e',
        );
      });
    }
  }

  Future<void> _openFolder(String path) async {
    try {
      await Process.start('xdg-open', [path]);
    } catch (_) {
      try {
        await Process.start('explorer', [path]);
      } catch (_) {}
    }
  }

  Future<void> _refreshApps() async {
    setState(() => _appsLoading = true);
    try {
      final list = await _registry.scan();
      if (!mounted) return;
      setState(() {
        _apps = list;
        _appsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _appsLoading = false);
    }
  }

  Future<void> _toggleAppsPanel() async {
    if (_showAppsPanel) {
      setState(() => _showAppsPanel = false);
    } else {
      setState(() => _showAppsPanel = true);
      await _refreshApps();
    }
  }

  Future<void> _openEditor(_InstalledApp app) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LauncherEditor(app: app, applicationsDir: _applicationsDir),
    );
    if (saved == true) {
      await _refreshApps();
    }
  }

  Future<void> _uninstallApp(_InstalledApp app) async {
    final confirmed = await showAnimatedUninstallDialog(
      context,
      appName: app.name,
      appDir: app.appDir,
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.uninstall(app.toInstallResult(_applicationsDir.path));
      await _refreshApps();
      // If the just-uninstalled app was the one we showed on the success card,
      // clear the demo state too.
      if (_data.result?.appName == app.name) {
        setState(() => _data = const _DemoStateData());
      }
    } catch (e) {
      if (!mounted) return;
      // _service.uninstall throws InstallerException with user-facing
      // messages. Strip the "Exception: " prefix Dart adds.
      final msg = e is InstallerException
          ? e.message
          : e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFFFF6961),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              // Full-bleed background: image with wash-out overlay so the
              // foreground content stays readable while the photo provides
              // atmosphere. The image scales to cover the window.
              Positioned.fill(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      'assets/background.jpg',
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                    // Wash-out: darken + slight desaturation via a
                    // semi-transparent overlay plus a vertical gradient to
                    // ensure text contrast at the top and bottom of the
                    // window.
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0xFF0F1116).withOpacity(0.55),
                            const Color(0xFF0F1116).withOpacity(0.80),
                          ],
                          stops: const [0.0, 1.0],
                        ),
                      ),
                    ),
                    // Subtle dark vignette to push the foreground forward
                    Container(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.center,
                          radius: 1.1,
                          colors: [
                            Colors.transparent,
                            const Color(0xFF0F1116).withOpacity(0.35),
                          ],
                          stops: const [0.6, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Title bar + content
              Column(
                children: [
                  _TitleBar(
                    onReset: _data.state == _DemoState.done ? _reset : null,
                    onToggleApps: _toggleAppsPanel,
                    appsCount: _apps.length,
                    appsOpen: _showAppsPanel,
                  ),
                  Expanded(child: _buildBody(constraints)),
                ],
              ),
              // Apps panel overlay
              if (_showAppsPanel) _buildAppsOverlay(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(BoxConstraints constraints) {
    // ConstrainedBox keeps the design readable on huge windows; on
    // small/short windows we fall back to vertical scrolling.
    final scrollable = constraints.maxHeight < 540;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'Install Application',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _data.droppedFile == null
              ? 'Drop a .tar.gz / .zip / .AppImage below to install'
              : 'Review and click Install to continue',
          style: TextStyle(
            fontSize: 15,
            color: Colors.white.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 30),
        _buildTransferSection(),
        const SizedBox(height: 14),
        if (_data.state == _DemoState.installing)
          _PhaseLabel(phase: _data.phase)
        else if (_data.state == _DemoState.error)
          _ErrorLabel(message: _data.error ?? 'Error')
        else if (_data.state == _DemoState.done)
          _DoneLabel(result: _data.result!)
        else if (_data.droppedFile != null)
          _ReadyLabel(filename: _data.droppedFile!.name),
        if (!scrollable) const Spacer(),
        _InfoCardsRow(),
        const SizedBox(height: 18),
        _Footer(
          state: _data.state,
          onInstall: _data.droppedFile == null ||
                  _data.state == _DemoState.installing
              ? null
              : _startInstall,
          onReset: _reset,
          onUninstall: _uninstall,
          onOpenFolder: _data.result == null
              ? null
              : () => _openFolder(_data.result!.appDir),
          appDir: _data.result?.appDir,
        ),
      ],
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 28, 40, 24),
          child: scrollable
              ? SingleChildScrollView(child: content)
              : content,
        ),
      ),
    );
  }

  Widget _buildAppsOverlay() {
    return Positioned.fill(
      child: _AppsPanel(
        apps: _apps,
        isLoading: _appsLoading,
        onRefresh: _refreshApps,
        onClose: () => setState(() => _showAppsPanel = false),
        onOpenFolder: (app) => _openFolder(app.appDir),
        onEditLauncher: _openEditor,
        onUninstall: _uninstallApp,
      ),
    );
  }

  Widget _buildTransferSection() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Source = drop zone
        DropTarget(
          onDragEntered: (_) => setState(() => _isHovering = true),
          onDragExited: (_) => setState(() => _isHovering = false),
          onDragDone: (d) {
            setState(() => _isHovering = false);
            _onDropDone(d);
          },
          enable: _data.state != _DemoState.installing,
          child: _SourceCard(
            file: _data.droppedFile,
            size: _data.droppedSize,
            isHovering: _isHovering,
            state: _data.state,
            progress: _data.progress,
            phase: _data.phase,
            rejection: _data.rejection,
            shakeCounter: _data.shakeCounter,
          ),
        ),
        const SizedBox(width: 28),
        SizedBox(
          width: 80,
          child: Center(
            child: _ArrowOrProgress(
              state: _data.state,
              progress: _data.progress,
            ),
          ),
        ),
        const SizedBox(width: 28),
        _DestinationCard(
          state: _data.state,
          file: _data.droppedFile,
          result: _data.result,
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Title bar
// ──────────────────────────────────────────────────────────────────────────────

class _TitleBar extends StatelessWidget {
  final VoidCallback? onReset;
  final VoidCallback? onToggleApps;
  final int appsCount;
  final bool appsOpen;
  const _TitleBar({
    this.onReset,
    this.onToggleApps,
    this.appsCount = 0,
    this.appsOpen = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: const BoxDecoration(
        color: Color(0xFF1C1E24),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2A2C33), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Left: traffic lights (clicks pass through; NOT in the drag area)
          const SizedBox(width: 12),
          _TrafficLight(
            color: const Color(0xFFFF5F57),
            onTap: () => windowManager.close(),
          ),
          const SizedBox(width: 8),
          _TrafficLight(
            color: const Color(0xFFFFBD2E),
            onTap: () => windowManager.minimize(),
          ),
          const SizedBox(width: 8),
          _TrafficLight(
            color: const Color(0xFF28C840),
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          // Middle: draggable title area
          Expanded(
            child: DragToMoveArea(
              child: Container(
                color: Colors.transparent,
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.install_desktop_outlined,
                      size: 15,
                      color: Color(0xFF8E9299),
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      'Install Application',
                      style: TextStyle(
                        color: Color(0xFF8E9299),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Right: Apps toggle (with badge) and optional Reset
          if (onToggleApps != null)
            _AppsToggleButton(
              count: appsCount,
              open: appsOpen,
              onTap: onToggleApps!,
            ),
          if (onReset != null) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white54,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Reset', style: TextStyle(fontSize: 11.5)),
            ),
          ] else
            const SizedBox(width: 12),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

class _AppsToggleButton extends StatelessWidget {
  final int count;
  final bool open;
  final VoidCallback onTap;
  const _AppsToggleButton({
    required this.count,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = open ? const Color(0xFF5AC8FA) : Colors.white70;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: open
                ? const Color(0xFF5AC8FA).withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.apps_rounded, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                'Apps',
                style: TextStyle(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: open
                        ? const Color(0xFF5AC8FA)
                        : const Color(0xFF2A2C33),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      color: open ? const Color(0xFF0F1116) : Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TrafficLight extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;
  const _TrafficLight({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.5),
              blurRadius: 3,
              spreadRadius: 0.5,
            ),
          ],
          border: Border.all(
            color: Colors.black.withOpacity(0.25),
            width: 0.6,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Cards
// ──────────────────────────────────────────────────────────────────────────────

class _SourceCard extends StatefulWidget {
  final XFile? file;
  final int? size;
  final bool isHovering;
  final _DemoState state;
  final double progress;
  final String phase;
  final String? rejection;
  final int shakeCounter;

  const _SourceCard({
    required this.file,
    required this.size,
    required this.isHovering,
    required this.state,
    required this.progress,
    required this.phase,
    required this.rejection,
    required this.shakeCounter,
  });

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
  }

  @override
  void didUpdateWidget(covariant _SourceCard old) {
    super.didUpdateWidget(old);
    if (widget.shakeCounter != old.shakeCounter) {
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasFile = widget.file != null;
    final installing = widget.state == _DemoState.installing;
    final done = widget.state == _DemoState.done;
    final rejected = widget.rejection != null;

    Color borderColor;
    if (rejected) {
      borderColor = const Color(0xFFFF6961);
    } else if (widget.isHovering) {
      borderColor = const Color(0xFF5AC8FA);
    } else if (done) {
      borderColor = const Color(0xFF30D158);
    } else if (hasFile) {
      borderColor = const Color(0xFF5AC8FA).withOpacity(0.6);
    } else {
      borderColor = const Color(0xFF2A2C33);
    }

    final card = Container(
      width: 200,
      height: 170,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: borderColor,
          width: (widget.isHovering || hasFile || done || rejected) ? 1.5 : 1,
        ),
        boxShadow: rejected
            ? [
                BoxShadow(
                  color: const Color(0xFFFF6961).withOpacity(0.30),
                  blurRadius: 22,
                  spreadRadius: 2,
                ),
              ]
            : widget.isHovering
                ? [
                    BoxShadow(
                      color: const Color(0xFF5AC8FA).withOpacity(0.2),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!hasFile) _buildEmpty(),
          if (hasFile && !installing && !done) _buildFileIcon(),
          if (installing) _buildFileIcon(),
          if (done) _buildFileIcon(),
          const SizedBox(height: 10),
          if (rejected)
            _buildRejectionLabel(widget.rejection!)
          else
            _buildLabel(),
        ],
      ),
    );

    // Shake: a damped sine that swings left-right and decays over ~480ms.
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final t = _shake.value;
        final dx = (1 - t) * 10 * _sineShake(t); // amplitude decays with t
        return Transform.translate(
          offset: Offset(dx, 0),
          child: child,
        );
      },
      child: card,
    );
  }

  // Damped sine: 4 full oscillations over 0..1, amplitude returns
  // values in [-1, 1] that we scale and decay in the caller.
  double _sineShake(double t) {
    return math.sin(t * 4 * 2 * math.pi);
  }

  Widget _buildEmpty() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/tar_gz_icon.png',
          width: 64,
          height: 64,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
        const SizedBox(height: 10),
        Text(
          widget.isHovering ? 'Release to select' : 'Drop an archive here',
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }

  Widget _buildFileIcon() {
    final name = widget.file?.name ?? '';
    final ext = p.extension(name).toLowerCase();
    final isAppImage = ext == '.appimage';
    final isZip = ext == '.zip';

    return Stack(
      alignment: Alignment.center,
      children: [
        // Use the same icon asset; for AppImage/Zip we tint it slightly
        // differently via a small ColorFiltered wrapper.
        ColorFiltered(
          colorFilter: isAppImage
              ? const ColorFilter.mode(Color(0xFF7FB77E), BlendMode.modulate)
              : isZip
                  ? const ColorFilter.mode(Color(0xFFCBC2B1), BlendMode.modulate)
                  : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
          child: Image.asset(
            'assets/tar_gz_icon.png',
            width: 64,
            height: 80,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
        Positioned(
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1.5),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2F36),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              isAppImage
                  ? 'APPIMAGE'
                  : isZip
                      ? 'ZIP'
                      : 'TAR.GZ',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
        if (widget.state == _DemoState.done)
          Positioned(
            top: 0,
            right: 6,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: Color(0xFF1E2128),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF30D158),
                size: 20,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLabel() {
    final name = widget.file?.name ?? 'No file selected';
    final isDone = widget.state == _DemoState.done;
    final displayName = isDone
        ? (name.replaceAll(
            RegExp(r'\.(tar\.gz|tar\.xz|tar\.bz2|zip|appimage)$',
                caseSensitive: false),
            ''))
        : name;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        children: [
          Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDone ? const Color(0xFF30D158) : Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            widget.size == null ? '—' : _formatBytes(widget.size!),
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRejectionLabel(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFF6961),
            size: 13,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFF6961),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationCard extends StatelessWidget {
  final _DemoState state;
  final XFile? file;
  final InstallResult? result;

  const _DestinationCard({
    required this.state,
    required this.file,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = state == _DemoState.done;
    final showPreview = file != null && !isDone;

    final displayName = isDone
        ? (result?.appName ?? 'app')
        : showPreview
            ? _previewName(file!.name)
            : '~/.local/share';

    final displayPath = isDone
        ? (result?.appDir ?? '')
        : showPreview
            ? '~/.local/share/installer-apps/${_previewName(file!.name)}'
            : '~/.local/share';

    return Container(
      width: 200,
      height: 170,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDone ? const Color(0xFF30D158) : const Color(0xFF2A2C33),
          width: isDone ? 1.5 : 1,
        ),
        boxShadow: null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              // Tint the home folder icon based on state
              ColorFiltered(
                colorFilter: isDone
                    ? const ColorFilter.mode(
                        Color(0xFF30D158), BlendMode.modulate)
                    : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                child: Image.asset(
                  'assets/home_folder_icon.png',
                  width: 96,
                  height: 82,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              if (isDone)
                Positioned(
                  top: 0,
                  right: 18,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E2128),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF30D158),
                      size: 22,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Tooltip(
            message: displayPath,
            child: Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              displayPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _previewName(String filename) {
  return filename.replaceAll(
    RegExp(r'\.(tar\.gz|tar\.xz|tar\.bz2|tgz|zip|appimage)$', caseSensitive: false),
    '',
  );
}

class _ArrowOrProgress extends StatelessWidget {
  final _DemoState state;
  final double progress;
  const _ArrowOrProgress({required this.state, required this.progress});

  @override
  Widget build(BuildContext context) {
    if (state == _DemoState.installing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              value: progress > 0 ? progress : null,
              strokeWidth: 3.5,
              color: const Color(0xFF5AC8FA),
              backgroundColor: const Color(0xFF2A2C33),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF5AC8FA),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    }
    if (state == _DemoState.done) {
      return const Icon(
        Icons.check_circle_rounded,
        color: Color(0xFF30D158),
        size: 44,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '······',
          style: TextStyle(
            color: Colors.white.withOpacity(0.25),
            fontSize: 18,
            letterSpacing: 1.5,
            height: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Icon(
          Icons.arrow_forward_rounded,
          color: Colors.white.withOpacity(0.25),
          size: 26,
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Status labels between cards and footer
// ──────────────────────────────────────────────────────────────────────────────

class _PhaseLabel extends StatelessWidget {
  final String phase;
  const _PhaseLabel({required this.phase});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Color(0xFF5AC8FA),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              phase,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF5AC8FA),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorLabel extends StatelessWidget {
  final String message;
  const _ErrorLabel({required this.message});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFF6961),
            size: 16,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFF6961),
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DoneLabel extends StatelessWidget {
  final InstallResult result;
  const _DoneLabel({required this.result});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            color: Color(0xFF30D158),
            size: 16,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Installed to ${result.appDir}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF30D158),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadyLabel extends StatelessWidget {
  final String filename;
  const _ReadyLabel({required this.filename});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Text(
        'Ready: $filename',
        style: TextStyle(
          color: Colors.white.withOpacity(0.55),
          fontSize: 12.5,
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Info cards
// ──────────────────────────────────────────────────────────────────────────────

class _InfoCardsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _InfoCard(
            icon: Icons.download_rounded,
            title: 'What happens next?',
            description:
                'The archive is extracted to ~/.local/share/installer-apps/<name>/ and a .desktop launcher is created.',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InfoCard(
            icon: Icons.lock_outline_rounded,
            title: 'No sudo required',
            description:
                'Everything installs under your home directory. Safe to run on shared systems.',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InfoCard(
            icon: Icons.undo_rounded,
            title: 'Fully reversible',
            description:
                'Use Uninstall to remove files and the launcher. No traces left behind.',
          ),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2128),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF2A2C33), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                  color: Color(0xFF2A2C33),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 17, color: Colors.white70),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              color: Colors.white.withOpacity(0.65),
              fontSize: 11.5,
              height: 1.38,
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Footer with primary Install button
// ──────────────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  final _DemoState state;
  final VoidCallback? onInstall;
  final VoidCallback onReset;
  final VoidCallback onUninstall;
  final VoidCallback? onOpenFolder;
  final String? appDir;

  const _Footer({
    required this.state,
    required this.onInstall,
    required this.onReset,
    required this.onUninstall,
    required this.onOpenFolder,
    required this.appDir,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.help_outline_rounded,
          size: 15,
          color: Colors.white.withOpacity(0.4),
        ),
        const SizedBox(width: 6),
        Text(
          'Need help? View the ',
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 12,
          ),
        ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Drop a .tar.gz, .zip, or .AppImage onto the source card.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text(
              'quick start',
              style: TextStyle(
                color: Color(0xFF5AC8FA),
                fontSize: 12,
                decoration: TextDecoration.underline,
                decorationColor: Color(0xFF5AC8FA),
              ),
            ),
          ),
        ),
        const Spacer(),
        if (state == _DemoState.done) ...[
          _SecondaryButton(
            label: 'Open folder',
            icon: Icons.folder_open_rounded,
            onTap: onOpenFolder,
          ),
          const SizedBox(width: 8),
          _SecondaryButton(
            label: 'Uninstall',
            icon: Icons.delete_outline_rounded,
            onTap: onUninstall,
            danger: true,
          ),
          const SizedBox(width: 8),
        ],
        if (state != _DemoState.done)
          _PrimaryButton(
            label: 'Install',
            icon: Icons.download_rounded,
            onTap: onInstall,
          ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  const _PrimaryButton({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0xFF5AC8FA)
                : const Color(0xFF2A2C33),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: enabled ? const Color(0xFF0F1116) : Colors.white24,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? const Color(0xFF0F1116) : Colors.white24,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;
  const _SecondaryButton({
    required this.label,
    required this.icon,
    this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        danger ? const Color(0xFFFF6961) : const Color(0xFF8E9299);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2128),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF2A2C33)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Installer service — real extract + .desktop file
// ──────────────────────────────────────────────────────────────────────────────

// Public for testability.

class InstallerException implements Exception {
  final String message;
  InstallerException(this.message);
  @override
  String toString() => message;
}

class InstallProgress {
  final double value;
  final String phase;
  final InstallResult? result;
  const InstallProgress(this.value, this.phase, {this.result});
}

class InstallResult {
  final String appName;
  final String appDir;
  final String desktopFile;
  final String? launcherPath;
  const InstallResult({
    required this.appName,
    required this.appDir,
    required this.desktopFile,
    this.launcherPath,
  });
}

class InstallerService {
  static const _supportedExts = [
    '.tar.gz',
    '.tgz',
    '.tar.bz2',
    '.tar.xz',
    '.zip',
    '.appimage',
  ];

  Stream<InstallProgress> install({
    required XFile source,
    required Directory home,
    required Directory appsDir,
    required Directory binDir,
  }) async* {
    final srcPath = source.path;
    final srcName = source.name;
    final ext = detectExt(srcName);
    if (ext == null) {
      // Surface the actual extension so users know why their file was rejected.
      final actual = p.extension(srcName).toLowerCase();
      final hint = actual.isEmpty
          ? ' (no file extension)'
          : ' (got "$actual")';
      throw InstallerException(
        'Unsupported file type$hint. Drop a .tar.gz, .zip, or .AppImage.',
      );
    }

    final appName = _stripArchiveExt(srcName);
    final appDir = Directory(p.join(appsDir.path, appName));
    final desktopFile = File(p.join(home.path, '.local', 'share',
        'applications', 'installer-$appName.desktop'));
    String? launcherPath;

    if (appDir.existsSync()) {
      throw InstallerException(
        '"$appName" is already installed. Uninstall it first.',
      );
    }

    yield const InstallProgress(0.05, 'Preparing destination…');
    await appDir.create(recursive: true);
    await desktopFile.parent.create(recursive: true);
    if (ext == '.appimage') {
      await binDir.create(recursive: true);
    }

    if (ext == '.appimage') {
      yield const InstallProgress(0.15, 'Copying AppImage…');
      final target = File(p.join(binDir.path, appName));
      await File(srcPath).copy(target.path);
      await Process.run('chmod', ['+x', target.path]);
      launcherPath = target.path;
      yield const InstallProgress(0.9, 'Creating launcher…');
      await _writeDesktopFile(
        desktopFile,
        name: appName,
        exec: target.path,
      );
    } else {
      // Real extraction with progress
      yield InstallProgress(0.1, 'Reading archive…');

      late Archive archive;
      try {
        if (ext == '.zip') {
          final bytes = await File(srcPath).readAsBytes();
          archive = ZipDecoder().decodeBytes(bytes);
        } else {
          // .tar.gz / .tgz / .tar.bz2 / .tar.xz all need a decompression pass
          // before TarDecoder can parse them.
          final input = InputFileStream(srcPath);
          final out = OutputMemoryStream();
          switch (ext) {
            case '.tar.gz':
            case '.tgz':
              GZipDecoder().decodeStream(input, out);
              break;
            case '.tar.bz2':
              BZip2Decoder().decodeStream(input, out);
              break;
            case '.tar.xz':
              XZDecoder().decodeStream(input, out);
              break;
          }
          await input.close();
          final tar = InputMemoryStream(out.getBytes());
          archive = TarDecoder().decodeStream(tar);
        }
      } catch (e) {
        await _safeDelete(appDir);
        throw InstallerException('Could not read archive: $e');
      }

      final entries = archive.files.where((f) => f.isFile).toList();
      final total = entries.isEmpty ? 1 : entries.length;

      yield InstallProgress(0.15, 'Extracting 0/${entries.length}');

      var i = 0;
      for (final entry in entries) {
        if (entry.isFile) {
          final outPath = p.join(appDir.path, entry.name);
          try {
            final outFile = File(outPath);
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(entry.readBytes()!);
            // Restore the original unix mode bits (esp. executable)
            final mode = entry.mode & 0xFFF;
            if (mode != 0) {
              await Process.run('chmod', [mode.toRadixString(8), outPath]);
            }
          } catch (e) {
            await _safeDelete(appDir);
            throw InstallerException(
              'Failed to extract "${entry.name}": $e',
            );
          }
        }
        i++;
        // 0.15 → 0.85 maps to extraction
        final v = 0.15 + (0.70 * (i / total));
        if (i % 8 == 0 || i == entries.length) {
          yield InstallProgress(v, 'Extracting $i/${entries.length}');
        }
        // yield occasionally so the UI updates
        if (i % 4 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      yield const InstallProgress(0.88, 'Creating launcher…');
      final exec = _findExecutable(appDir);
      if (exec != null) {
        final execFull = p.join(appDir.path, exec);
        await _writeDesktopFile(
          desktopFile,
          name: appName,
          exec: execFull,
        );
      } else {
        await _writeDesktopFile(
          desktopFile,
          name: appName,
          exec: 'xdg-open .',
        );
      }
    }

    // Best-effort desktop database refresh
    try {
      await Process.run(
        'update-desktop-database',
        [p.join(home.path, '.local', 'share', 'applications')],
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}

    final result = InstallResult(
      appName: appName,
      appDir: appDir.path,
      desktopFile: desktopFile.path,
      launcherPath: launcherPath,
    );
    yield InstallProgress(1.0, 'Done', result: result);
  }

  Future<void> uninstall(InstallResult r) async {
    // Refuse to delete if the app is currently running. The OS keeps the
    // executable in memory, so removing the on-disk file would leave a
    // "deleted" process that breaks the running app the moment it tries to
    // re-read a resource.
    final running = _runningProcessesUnder(r.appDir);
    if (running.isNotEmpty) {
      throw InstallerException(
        'Cannot uninstall: "${r.appName}" is currently running '
        '(${running.length} process${running.length == 1 ? "" : "es"}). '
        'Close it first.',
      );
    }
    final appDir = Directory(r.appDir);
    if (appDir.existsSync()) {
      await appDir.delete(recursive: true);
    }
    final desktop = File(r.desktopFile);
    if (desktop.existsSync()) {
      await desktop.delete();
    }
    if (r.launcherPath != null) {
      final launcher = File(r.launcherPath!);
      if (launcher.existsSync()) {
        await launcher.delete();
      }
    }
    try {
      await Process.run(
        'update-desktop-database',
        [p.dirname(r.desktopFile)],
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Returns the PIDs of processes whose executable lives under [dir].
  /// Used to refuse uninstall of a running app.
  static List<int> _runningProcessesUnder(String dir) {
    final hits = <int>[];
    final proc = Directory('/proc');
    if (!proc.existsSync()) return hits;
    for (final entry in proc.listSync()) {
      if (entry is! Directory) continue;
      final exe = File('${entry.path}/exe');
      if (!exe.existsSync()) continue;
      try {
        // /proc/<pid>/exe is a symlink; readlinkSync returns the target.
        // If the file was deleted the link target ends with " (deleted)".
        final target = exe.resolveSymbolicLinksSync();
        if (target.startsWith('$dir/') || target == dir) {
          final pid = int.tryParse(p.basename(entry.path));
          if (pid != null) hits.add(pid);
        }
      } catch (_) {
        // Process may have just exited; ignore.
      }
    }
    return hits;
  }

  Future<void> _writeDesktopFile(
    File file, {
    required String name,
    required String exec,
  }) async {
    final content = '''[Desktop Entry]
Version=1.0
Type=Application
Name=${_humanize(name)}
Comment=Installed by Leenx Installer
Exec=$exec
Terminal=false
Categories=Utility;
''';
    await file.writeAsString(content);
  }

  String? _findExecutable(Directory dir) {
    // Look for a top-level executable file or a `bin/<appName>` script.
    // Returns a path relative to [dir].
    // Skip anything in lib/ or runtime/ — those are support files
    // (e.g. jspawnhelper) that happen to be marked executable.
    try {
      final candidates = <File>[];
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: dir.path);
          if (rel.split(p.separator).any((s) => s == 'lib' || s == 'runtime')) {
            continue;
          }
          final stat = entity.statSync();
          if ((stat.mode & 0x49) != 0) {
            candidates.add(entity);
          }
        }
      }
      if (candidates.isNotEmpty) {
        // Prefer one whose basename contains the app dir name
        final dirName = p.basename(dir.path);
        candidates.sort((a, b) {
          final aMatch = p.basename(a.path).contains(dirName) ? 0 : 1;
          final bMatch = p.basename(b.path).contains(dirName) ? 0 : 1;
          return aMatch.compareTo(bMatch);
        });
        return p.relative(candidates.first.path, from: dir.path);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _safeDelete(Directory d) async {
    try {
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Public for pre-install validation (e.g. on drop).
  static String? detectExt(String name) {
    final lower = name.toLowerCase();
    for (final ext in _supportedExts) {
      if (lower.endsWith(ext)) return ext;
    }
    return null;
  }

  String _stripArchiveExt(String name) {
    return name.replaceAll(
      RegExp(r'\.(tar\.gz|tar\.xz|tar\.bz2|tgz|zip|appimage)$', caseSensitive: false),
      '',
    );
  }

  String _humanize(String s) {
    return s
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

// ──────────────────────────────────────────────────────────────────────────────
// Installed apps registry
// ──────────────────────────────────────────────────────────────────────────────

class _InstalledApp {
  final String name;
  final String appDir;
  final String? desktopFile;
  final bool launcherExists;
  final DateTime? installedAt;

  const _InstalledApp({
    required this.name,
    required this.appDir,
    required this.desktopFile,
    required this.launcherExists,
    required this.installedAt,
  });

  InstallResult toInstallResult(String applicationsDir) => InstallResult(
        appName: name,
        appDir: appDir,
        desktopFile: desktopFile ??
            p.join(applicationsDir, 'installer-$name.desktop'),
        launcherPath: null,
      );
}

class AppsRegistry {
  final Directory appsDir;
  final Directory applicationsDir;
  const AppsRegistry({required this.appsDir, required this.applicationsDir});

  Future<List<_InstalledApp>> scan() async {
    if (!appsDir.existsSync()) return const [];
    final out = <_InstalledApp>[];
    for (final entity in appsDir.listSync()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      final desktop = File(
          p.join(applicationsDir.path, 'installer-$name.desktop'));
      final hasDesktop = desktop.existsSync();
      DateTime? modified;
      try {
        modified = entity.statSync().modified;
      } catch (_) {}
      out.add(_InstalledApp(
        name: name,
        appDir: entity.path,
        desktopFile: hasDesktop ? desktop.path : null,
        launcherExists: hasDesktop,
        installedAt: modified,
      ));
    }
    out.sort((a, b) {
      final am = a.installedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bm = b.installedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bm.compareTo(am);
    });
    return out;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Apps panel (slide-in sidebar)
// ──────────────────────────────────────────────────────────────────────────────

class _AppsPanel extends StatelessWidget {
  final List<_InstalledApp> apps;
  final bool isLoading;
  final Future<void> Function() onRefresh;
  final VoidCallback onClose;
  final Future<void> Function(_InstalledApp) onOpenFolder;
  final Future<void> Function(_InstalledApp) onEditLauncher;
  final Future<void> Function(_InstalledApp) onUninstall;

  const _AppsPanel({
    required this.apps,
    required this.isLoading,
    required this.onRefresh,
    required this.onClose,
    required this.onOpenFolder,
    required this.onEditLauncher,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Scrim
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            behavior: HitTestBehavior.opaque,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: 1,
              child: Container(color: Colors.black.withOpacity(0.45)),
            ),
          ),
        ),
        // Panel
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          width: 320,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: 0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) {
              return Transform.translate(
                offset: Offset(t * 320, 0),
                child: child,
              );
            },
            child: Material(
              color: const Color(0xFF16181F),
              child: Column(
                children: [
                  _AppsPanelHeader(
                    count: apps.length,
                    isLoading: isLoading,
                    onRefresh: onRefresh,
                    onClose: onClose,
                  ),
                  const Divider(height: 0.5, color: Color(0xFF2A2C33)),
                  Expanded(child: _buildBody()),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (isLoading && apps.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF5AC8FA),
          ),
        ),
      );
    }
    if (apps.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 44, color: Colors.white.withOpacity(0.18)),
            const SizedBox(height: 10),
            Text(
              'No apps installed yet',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              'Drop an archive on the Install tab.',
              style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 11.5),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: apps.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 0.5, color: Color(0xFF2A2C33), indent: 14, endIndent: 14),
      itemBuilder: (context, i) => _AppListTile(
        app: apps[i],
        onOpenFolder: () => onOpenFolder(apps[i]),
        onEditLauncher: apps[i].launcherExists ? () => onEditLauncher(apps[i]) : null,
        onUninstall: () => onUninstall(apps[i]),
      ),
    );
  }
}

class _AppsPanelHeader extends StatelessWidget {
  final int count;
  final bool isLoading;
  final Future<void> Function() onRefresh;
  final VoidCallback onClose;
  const _AppsPanelHeader({
    required this.count,
    required this.isLoading,
    required this.onRefresh,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: const Color(0xFF1C1E24),
      child: Row(
        children: [
          const Icon(Icons.apps_rounded, size: 15, color: Color(0xFF8E9299)),
          const SizedBox(width: 8),
          const Text(
            'Installed apps',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2C33),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: isLoading ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            color: Colors.white70,
            tooltip: 'Refresh',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: Colors.white70,
            tooltip: 'Close',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

class _AppListTile extends StatelessWidget {
  final _InstalledApp app;
  final VoidCallback onOpenFolder;
  final VoidCallback? onEditLauncher;
  final VoidCallback onUninstall;
  const _AppListTile({
    required this.app,
    required this.onOpenFolder,
    required this.onEditLauncher,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!app.launcherExists) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Launcher (.desktop) file is missing',
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Color(0xFFFFBD2E),
                  ),
                ),
              ],
              const Spacer(),
              PopupMenuButton<_AppRowAction>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert_rounded, size: 16, color: Colors.white54),
                color: const Color(0xFF1E2128),
                onSelected: (action) {
                  switch (action) {
                    case _AppRowAction.open:
                      onOpenFolder();
                      break;
                    case _AppRowAction.edit:
                      onEditLauncher?.call();
                      break;
                    case _AppRowAction.uninstall:
                      onUninstall();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _AppRowAction.open,
                    child: Row(
                      children: [
                        Icon(Icons.folder_open_rounded, size: 15, color: Colors.white70),
                        SizedBox(width: 8),
                        Text('Open folder'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: _AppRowAction.edit,
                    enabled: onEditLauncher != null,
                    child: Row(
                      children: [
                        Icon(Icons.edit_rounded,
                            size: 15,
                            color: onEditLauncher != null
                                ? Colors.white70
                                : Colors.white24),
                        const SizedBox(width: 8),
                        Text('Edit launcher',
                            style: TextStyle(
                              color: onEditLauncher != null
                                  ? Colors.white
                                  : Colors.white38,
                            )),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _AppRowAction.uninstall,
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded,
                            size: 15, color: Color(0xFFFF6961)),
                        SizedBox(width: 8),
                        Text('Uninstall', style: TextStyle(color: Color(0xFFFF6961))),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 2),
          Tooltip(
            message: app.appDir,
            child: Text(
              app.appDir,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            app.installedAt == null
                ? 'Installed'
                : 'Installed ${_formatDate(app.installedAt!)}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

enum _AppRowAction { open, edit, uninstall }

String _formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

// ──────────────────────────────────────────────────────────────────────────────
// Launcher editor (modal bottom sheet)
// ──────────────────────────────────────────────────────────────────────────────

class _LauncherEditor extends StatefulWidget {
  final _InstalledApp app;
  final Directory applicationsDir;
  const _LauncherEditor({required this.app, required this.applicationsDir});

  @override
  State<_LauncherEditor> createState() => _LauncherEditorState();
}

class _LauncherEditorState extends State<_LauncherEditor> {
  late final TextEditingController _controller;
  String? _initialContent;
  bool _loading = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _controller.addListener(() {
      final nowDirty = _controller.text != _initialContent;
      if (nowDirty != _dirty) setState(() => _dirty = nowDirty);
    });
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    String text;
    if (widget.app.desktopFile != null &&
        File(widget.app.desktopFile!).existsSync()) {
      try {
        text = await File(widget.app.desktopFile!).readAsString();
      } catch (_) {
        text = _defaultTemplate();
      }
    } else {
      text = _defaultTemplate();
    }
    if (!mounted) return;
    setState(() {
      _initialContent = text;
      _controller.text = text;
      _loading = false;
    });
  }

  String _defaultTemplate() {
    final exec = _findExecForTemplate();
    return '''[Desktop Entry]
Version=1.0
Type=Application
Name=${_humanizeName(widget.app.name)}
Comment=Installed by Leenx Installer
Exec=$exec
Terminal=false
Categories=Utility;
''';
  }

  String _findExecForTemplate() {
    try {
      final dir = Directory(widget.app.appDir);
      if (!dir.existsSync()) return 'xdg-open ${dir.path}';
      // Pick the first executable file
      for (final e in dir.listSync(recursive: true)) {
        if (e is File) {
          final stat = e.statSync();
          final mode = stat.mode;
          // owner-execute bit (0o100), group-execute (0o010), other-execute (0o001)
          if ((mode & 73) != 0) return e.path;
        }
      }
    } catch (_) {}
    return 'xdg-open ${widget.app.appDir}';
  }

  bool get _isValid {
    final t = _controller.text.trimLeft();
    return t.startsWith('[Desktop Entry]');
  }

  Future<void> _save() async {
    if (!_isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing [Desktop Entry] header')),
      );
      return;
    }
    final path = widget.app.desktopFile ??
        p.join(widget.applicationsDir.path, 'installer-${widget.app.name}.desktop');
    final file = File(path);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(_controller.text);
      try {
        await Process.run('chmod', ['644', file.path]);
      } catch (_) {}
      try {
        await Process.run('update-desktop-database', [file.parent.path])
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  Future<void> _resetToDefault() async {
    if (_dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E2128),
          title: const Text('Reset to default?',
              style: TextStyle(color: Colors.white)),
          content: Text(
            'This will replace your edits with a fresh template.',
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Reset'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _controller.text = _defaultTemplate();
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF16181F),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(
              top: BorderSide(color: Color(0xFF2A2C33)),
              left: BorderSide(color: Color(0xFF2A2C33)),
              right: BorderSide(color: Color(0xFF2A2C33)),
            ),
          ),
          child: Column(
            children: [
              _buildHeader(),
              const Divider(height: 0.5, color: Color(0xFF2A2C33)),
              if (_loading)
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF5AC8FA), strokeWidth: 2),
                  ),
                )
              else
                Expanded(child: _buildEditor(scrollController)),
              const Divider(height: 0.5, color: Color(0xFF2A2C33)),
              _buildFooter(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    final name = widget.app.desktopFile != null
        ? p.basename(widget.app.desktopFile!)
        : 'installer-${widget.app.name}.desktop';
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          // drag handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Icon(Icons.edit_rounded, size: 15, color: Color(0xFF8E9299)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          if (_dirty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF5AC8FA).withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'edited',
                style: TextStyle(
                    color: Color(0xFF5AC8FA),
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditor(ScrollController scrollController) {
    final valid = _isValid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Row(
            children: [
              Icon(
                valid ? Icons.check_circle_outline : Icons.error_outline,
                size: 13,
                color: valid ? const Color(0xFF30D158) : const Color(0xFFFFBD2E),
              ),
              const SizedBox(width: 6),
              Text(
                valid
                    ? 'Valid [Desktop Entry] header detected'
                    : 'Tip: file must start with [Desktop Entry]',
                style: TextStyle(
                  color: valid
                      ? const Color(0xFF30D158)
                      : const Color(0xFFFFBD2E),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0F1116),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2A2C33)),
              ),
              padding: const EdgeInsets.all(10),
              child: Scrollbar(
                controller: scrollController,
                thumbVisibility: true,
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  scrollController: scrollController,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['Courier', 'monospace'],
                    height: 1.45,
                  ),
                  cursorColor: const Color(0xFF5AC8FA),
                  cursorWidth: 1.4,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          TextButton(
            onPressed: _resetToDefault,
            child: const Text('Reset to default',
                style: TextStyle(color: Color(0xFF8E9299), fontSize: 12.5)),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: _isValid ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: _isValid ? _save : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: _isValid
                      ? const Color(0xFF5AC8FA)
                      : const Color(0xFF2A2C33),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Save',
                  style: TextStyle(
                    color: _isValid
                        ? const Color(0xFF0F1116)
                        : Colors.white24,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _humanizeName(String s) {
  return s
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

// ──────────────────────────────────────────────────────────────────────────────
// Animated uninstall dialog
// ──────────────────────────────────────────────────────────────────────────────

Future<bool?> showAnimatedUninstallDialog(
  BuildContext context, {
  required String appName,
  required String appDir,
}) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withOpacity(0.65),
    transitionDuration: const Duration(milliseconds: 350),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final slideT = animation.value;
          final scaleT = Curves.easeOutBack.transform(slideT);
          return Opacity(
            opacity: slideT,
            child: Transform.translate(
              offset: Offset(0, 60 * (1 - slideT)),
              child: Transform.scale(
                scale: 0.88 + 0.12 * scaleT,
                child: child,
              ),
            ),
          );
        },
        child: child,
      );
    },
    pageBuilder: (context, animation, secondaryAnimation) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            color: const Color(0xFF1E2128),
            borderRadius: BorderRadius.circular(14),
            elevation: 28,
            shadowColor: Colors.black54,
            child: SizedBox(
              width: 380,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF6961).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            color: Color(0xFFFF6961),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Uninstall "$appName"?',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      appDir,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'This will remove the app directory and its launcher. '
                      'This cannot be undone.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFFF6961),
                            backgroundColor:
                                const Color(0xFFFF6961).withOpacity(0.1),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 9,
                            ),
                          ),
                          child: const Text(
                            'Uninstall',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
