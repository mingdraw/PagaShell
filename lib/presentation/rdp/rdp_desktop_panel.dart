import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/rdp/rdp_clipboard_controller.dart';
import '../../domain/rdp/rdp_clipboard.dart';
import '../../domain/rdp/rdp_engine.dart';
import '../../domain/rdp/rdp_resolution.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vnc/vnc_engine.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../navigation/app_notice.dart';
import '../vnc/vnc_keyboard.dart';
import 'rdp_input_queue.dart';
import 'rdp_surface.dart';

/// Decodes one update at a time; native damage accumulates until requested.
class RdpDesktopPanel extends StatefulWidget {
  const RdpDesktopPanel({
    super.key,
    required this.session,
    required this.active,
    required this.onError,
    this.fullscreen = false,
    this.fullscreenBusy = false,
    this.onToggleFullscreen,
    this.protocolLabel = 'RDP',
    this.dynamicResolution = true,
  });
  final RdpEngineSession session;
  final bool active;
  final ValueChanged<String> onError;
  final bool fullscreen;
  final bool fullscreenBusy;
  final VoidCallback? onToggleFullscreen;
  final String protocolLabel;
  final bool dynamicResolution;
  @override
  State<RdpDesktopPanel> createState() => _RdpDesktopPanelState();
}

class _RdpDesktopPanelState extends State<RdpDesktopPanel>
    with WidgetsBindingObserver {
  final _focus = FocusNode();
  final _pressed = <int>{};
  final _vncPressed = <PhysicalKeyboardKey, int>{};
  final _buttons = <int>{};
  final _macMeta = <PhysicalKeyboardKey>{};
  final _clipboardShortcutKeys = <PhysicalKeyboardKey>{};
  RdpClipboardController? _clipboard;
  StreamSubscription<void>? _frames;
  final _surface = RdpSurface();
  final _cursorPosition = ValueNotifier<Offset?>(null);
  ui.Image? _cursorImage;
  RdpCursor? _cursor;
  late final RdpInputQueue _inputs;
  Timer? _moveTimer;
  Offset? _move;
  Offset _position = Offset.zero;
  bool _failed = false;
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  bool _framesPaused = false;
  RdpResolution? _resolution;
  RdpResolution? _viewport;
  RdpResolution? _awaitingResolution;
  bool _resizeBusy = false;
  bool _fullscreenShortcutHeld = false;
  int _resizeSerial = 0;
  Timer? _resizeDebounce;
  Timer? _resizeConfirmation;

  bool get _appResumed => _lifecycle == AppLifecycleState.resumed;
  bool get _clipboardAvailable =>
      _lifecycle != AppLifecycleState.paused &&
      _lifecycle != AppLifecycleState.detached;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputs = RdpInputQueue(onError: _fail);
    _frames = widget.session.frames
        .asyncMap(_decode)
        .listen(
          (_) {},
          onError: (Object error) => _fail(error),
          onDone: () {
            if (mounted) _fail(const SshEngineException('远程桌面已断开，请重新连接'));
          },
        );
    _syncFrames();
    _focus.addListener(_focusChanged);
    final clipboardSession = widget.session;
    if (clipboardSession is RdpClipboardSession &&
        Get.isRegistered<LocalClipboard>()) {
      _clipboard = RdpClipboardController(
        session: clipboardSession,
        local: Get.find<LocalClipboard>(),
        onError: AppNotice.error,
      )..setForeground(_appResumed);
      _syncClipboard();
    }
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  Future<void> _decode(RdpFrame frame) async {
    final previousWidth = _surface.width;
    final previousHeight = _surface.height;
    ui.Image? cursorImage;
    try {
      await _surface.apply(frame);
      if (!mounted) return;
      final cursor = frame.cursor;
      if (cursor?.kind == RdpCursorKind.bitmap) {
        if (cursor!.width < 1 ||
            cursor.height < 1 ||
            cursor.rgba.length != cursor.width * cursor.height * 4) {
          throw const SshEngineException('远程桌面画面无效');
        }
        cursorImage = await decodeRdpPixels(
          cursor.rgba,
          cursor.width,
          cursor.height,
        );
      }
      if (!mounted) {
        cursorImage?.dispose();
        return;
      }
      final previousCursor = _cursorImage;
      final layoutChanged =
          previousWidth != _surface.width || previousHeight != _surface.height;
      final actual = RdpResolution(_surface.width, _surface.height);
      final resizeConfirmed = _awaitingResolution == actual;
      if (resizeConfirmed) {
        _resizeConfirmation?.cancel();
        _awaitingResolution = null;
        _resizeBusy = false;
      }
      if (layoutChanged && _awaitingResolution == null && _resolution != null) {
        _resolution = actual;
      }
      if (cursor != null) {
        _cursor = cursor;
        _cursorImage = cursorImage;
      }
      // Surface notifications repaint pixels without rebuilding any widgets.
      if (layoutChanged || cursor != null || resizeConfirmed) setState(() {});
      if (cursor != null) previousCursor?.dispose();
      if (layoutChanged || resizeConfirmed) _scheduleAutomaticResize();
    } on Object {
      cursorImage?.dispose();
      rethrow;
    }
  }

  void _fail(Object error) {
    if (!mounted || _failed) return;
    _failed = true;
    _resizeDebounce?.cancel();
    _resizeConfirmation?.cancel();
    _clipboard?.setActive(false);
    widget.onError(
      error is SshEngineException ? error.message : '远程桌面已断开，请重新连接',
    );
  }

  void _send(Future<void> Function() action, {bool movement = false}) {
    if (_failed) return;
    _inputs.add(action, movement: movement);
  }

  void _syncFrames() {
    final paused = !widget.active || !_appResumed;
    if (paused == _framesPaused) return;
    _framesPaused = paused;
    if (paused) {
      _frames?.pause();
    } else {
      _frames?.resume();
    }
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _release();
  }

  void _syncClipboard() {
    _clipboard?.setActive(widget.active && _clipboardAvailable);
    _clipboard?.setForeground(_appResumed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (!_appResumed) _release();
    _syncFrames();
    _syncClipboard();
  }

  @override
  void didUpdateWidget(RdpDesktopPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFrames();
    _syncClipboard();
    if (widget.active && !oldWidget.active) {
      _focus.requestFocus();
      _scheduleAutomaticResize();
    }
    if (!widget.active && oldWidget.active) {
      _release();
      _focus.unfocus();
    }
    if (widget.fullscreen != oldWidget.fullscreen) {
      _release();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focus.requestFocus();
      });
    }
  }

  void _release() {
    _moveTimer?.cancel();
    _moveTimer = null;
    _move = null;
    _cursorPosition.value = null;
    _macMeta.clear();
    _clipboardShortcutKeys.clear();
    final vncSession = widget.session;
    if (vncSession is VncEngineSession) {
      for (final symbol in _vncPressed.values) {
        _send(() => vncSession.keySymbol(symbol, down: false));
      }
      _vncPressed.clear();
    }
    for (final scan in _pressed.toList()) {
      _send(
        () =>
            widget.session.key(scan & 0xff, down: false, extended: scan > 255),
      );
    }
    _pressed.clear();
    for (final button in _buttons.toList()) {
      _pointer(_position, button);
    }
    _buttons.clear();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.active) return KeyEventResult.ignored;
    // Defer macOS Command so Cmd+C/X/V does not send a Windows-key tap.
    // Other Command combinations retain the ordinary Windows scan-code path.
    if (_clipboard != null && defaultTargetPlatform == TargetPlatform.macOS) {
      final physical = event.physicalKey;
      if (physical == PhysicalKeyboardKey.metaLeft ||
          physical == PhysicalKeyboardKey.metaRight) {
        if (event is KeyUpEvent) {
          _macMeta.remove(physical);
          final scan = rdpScanCode(physical)!;
          if (_pressed.remove(scan)) {
            _send(
              () =>
                  widget.session.key(scan & 0xff, down: false, extended: true),
            );
          }
        } else {
          _macMeta.add(physical);
        }
        return KeyEventResult.handled;
      }
      if (_clipboardShortcutKeys.contains(physical)) {
        if (event is KeyUpEvent) _clipboardShortcutKeys.remove(physical);
        return KeyEventResult.handled;
      }
      if (_macMeta.isNotEmpty &&
          !HardwareKeyboard.instance.isAltPressed &&
          !HardwareKeyboard.instance.isControlPressed &&
          !HardwareKeyboard.instance.isShiftPressed &&
          [
            PhysicalKeyboardKey.keyC,
            PhysicalKeyboardKey.keyX,
            PhysicalKeyboardKey.keyV,
          ].contains(physical) &&
          event is KeyDownEvent) {
        _clipboardShortcutKeys.add(physical);
        final scan = rdpScanCode(physical)!;
        _send(() async {
          if (physical == PhysicalKeyboardKey.keyV) {
            if (!await _clipboard!.syncBeforePaste()) return;
          }
          await widget.session.key(0x1d, down: true);
          await widget.session.key(scan, down: true);
          await widget.session.key(scan, down: false);
          await widget.session.key(0x1d, down: false);
        });
        return KeyEventResult.handled;
      }
      for (final meta in _macMeta) {
        final scan = rdpScanCode(meta)!;
        if (_pressed.add(scan)) {
          _send(
            () => widget.session.key(scan & 0xff, down: true, extended: true),
          );
        }
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_fullscreenShortcutHeld) {
        if (event is KeyUpEvent) _fullscreenShortcutHeld = false;
        return KeyEventResult.handled;
      }
      if (widget.onToggleFullscreen != null &&
          event is KeyDownEvent &&
          HardwareKeyboard.instance.isControlPressed &&
          HardwareKeyboard.instance.isAltPressed) {
        _fullscreenShortcutHeld = true;
        _release();
        if (!widget.fullscreenBusy) widget.onToggleFullscreen!();
        return KeyEventResult.handled;
      }
    }
    final vncSession = widget.session;
    if (vncSession is VncEngineSession) {
      final down = event is! KeyUpEvent;
      final symbol = down
          ? _vncPressed[event.physicalKey] ?? vncKeySymbol(event)
          : _vncPressed.remove(event.physicalKey);
      if (symbol == null) return KeyEventResult.ignored;
      if (down) _vncPressed[event.physicalKey] = symbol;
      _send(() => vncSession.keySymbol(symbol, down: down));
      return KeyEventResult.handled;
    }
    final scan = rdpScanCode(event.physicalKey);
    if (scan == null) return KeyEventResult.ignored;
    final down = event is! KeyUpEvent;
    if (down) {
      _pressed.add(scan);
    } else {
      _pressed.remove(scan);
    }
    final paste =
        down &&
        event.physicalKey == PhysicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed;
    _send(() async {
      if (paste && _clipboard != null) {
        if (!await _clipboard!.syncBeforePaste()) return;
      }
      await widget.session.key(scan & 0xff, down: down, extended: scan > 255);
    });
    return KeyEventResult.handled;
  }

  void _pointer(Offset position, int flags, {int wheel = 0}) {
    final image = _surface;
    if (!image.hasImage) return;
    final x = position.dx.round().clamp(0, image.width - 1);
    final y = position.dy.round().clamp(0, image.height - 1);
    _send(
      () => widget.session.pointer(x, y, flags, wheel: wheel),
      movement: flags == 0x0800,
    );
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final position = _move;
    _move = null;
    if (position != null) _pointer(position, 0x0800);
  }

  void _moving(PointerEvent event) {
    if (!widget.active) return;
    _position = event.localPosition;
    _cursorPosition.value = _position;
    _move = _position;
    _moveTimer ??= Timer(const Duration(milliseconds: 16), _flushMove);
  }

  void _button(PointerEvent event, bool down) {
    if (!widget.active) return;
    _focus.requestFocus();
    _flushMove();
    _position = event.localPosition;
    _cursorPosition.value = _position;
    const buttons = {
      kPrimaryMouseButton: 0x1000,
      kSecondaryMouseButton: 0x2000,
      kMiddleMouseButton: 0x4000,
    };
    for (final button in buttons.entries) {
      final wasDown = _buttons.contains(button.value);
      final isDown = down && event.buttons & button.key != 0;
      if (wasDown == isDown) continue;
      if (isDown) {
        _buttons.add(button.value);
      } else {
        _buttons.remove(button.value);
      }
      _pointer(_position, button.value | (isDown ? 0x8000 : 0));
    }
  }

  void _scroll(PointerSignalEvent event) {
    if (!widget.active || event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      _flushMove();
      final delta = event.scrollDelta.dy != 0
          ? event.scrollDelta.dy
          : event.scrollDelta.dx;
      final flags =
          (event.scrollDelta.dy != 0 ? 0x0200 : 0x0400) |
          (delta > 0 ? 0x0100 : 0);
      _pointer(
        event.localPosition,
        flags,
        wheel: delta.abs().round().clamp(1, 255),
      );
    });
  }

  void _scheduleAutomaticResize() {
    _resizeDebounce?.cancel();
    if (!widget.dynamicResolution ||
        _resolution != null ||
        _viewport == null ||
        _resizeBusy ||
        !widget.active ||
        _failed ||
        !_surface.hasImage) {
      return;
    }
    _resizeDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted &&
          widget.active &&
          _resolution == null &&
          _viewport != null) {
        unawaited(_resize(_viewport!));
      }
    });
  }

  void _selectResolution(String value) {
    final actual = RdpResolution(_surface.width, _surface.height);
    final resolution = value == 'auto'
        ? null
        : RdpResolution.presets.firstWhere(
            (r) => '${r.width}x${r.height}' == value,
            orElse: () => actual,
          );
    _resizeDebounce?.cancel();
    setState(() => _resolution = resolution);
    final target = resolution ?? _viewport;
    if (target != null) unawaited(_resize(target));
    _focus.requestFocus();
  }

  Future<void> _resize(RdpResolution target) async {
    if (_resizeBusy ||
        !widget.active ||
        _failed ||
        !_surface.hasImage ||
        target == RdpResolution(_surface.width, _surface.height)) {
      return;
    }
    _release();
    final serial = ++_resizeSerial;
    setState(() {
      _resizeBusy = true;
      _awaitingResolution = target;
    });
    try {
      final sent = await widget.session.resize(target.width, target.height);
      if (!mounted ||
          _failed ||
          serial != _resizeSerial ||
          _awaitingResolution == null) {
        return;
      }
      if (!sent) {
        _resizeFailed('远端不支持动态分辨率，已保留当前画面');
      } else {
        _resizeConfirmation = Timer(const Duration(seconds: 8), () {
          if (mounted &&
              serial == _resizeSerial &&
              _awaitingResolution != null) {
            _resizeFailed('远端未确认分辨率调整，已保留当前画面');
          }
        });
      }
    } on Object catch (error) {
      if (!mounted ||
          _failed ||
          serial != _resizeSerial ||
          _awaitingResolution == null) {
        return;
      }
      _resizeFailed(
        error is SshEngineException ? error.message : '无法调整远程桌面分辨率，请重试',
      );
    }
  }

  void _resizeFailed(String message) {
    _resizeConfirmation?.cancel();
    _resizeDebounce?.cancel();
    setState(() {
      _resizeBusy = false;
      _awaitingResolution = null;
      _resolution = RdpResolution(_surface.width, _surface.height);
    });
    AppNotice.error(message);
  }

  void _secureAttention() {
    _release();
    final vncSession = widget.session;
    if (vncSession is VncEngineSession) {
      for (final symbol in [0xffe3, 0xffe9, 0xffff]) {
        _send(() => vncSession.keySymbol(symbol, down: true));
      }
      for (final symbol in [0xffff, 0xffe9, 0xffe3]) {
        _send(() => vncSession.keySymbol(symbol, down: false));
      }
      _focus.requestFocus();
      return;
    }
    for (final scan in [0x1d, 0x38, 0x153]) {
      _send(
        () => widget.session.key(scan & 0xff, down: true, extended: scan > 255),
      );
    }
    for (final scan in [0x153, 0x38, 0x1d]) {
      _send(
        () =>
            widget.session.key(scan & 0xff, down: false, extended: scan > 255),
      );
    }
    _focus.requestFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resizeDebounce?.cancel();
    _resizeConfirmation?.cancel();
    _release();
    _clipboard?.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    unawaited(_frames?.cancel());
    _surface.dispose();
    _cursorImage?.dispose();
    _cursorPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _surface;
    final resolutionDisabled = _resizeBusy || !image.hasImage;
    final actual = RdpResolution(image.width, image.height);
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            Offstage(
              offstage: widget.fullscreen,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      !image.hasImage
                          ? '远程桌面'.tr
                          : '${widget.protocolLabel} · ${image.width} × ${image.height}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.dynamicResolution)
                      ExcludeFocus(
                        excluding: resolutionDisabled,
                        child: IgnorePointer(
                          ignoring: resolutionDisabled,
                          child: AppMenuButton<String>(
                            key: const ValueKey('rdp-resolution-menu'),
                            semanticLabel: '分辨率'.tr,
                            selectedValue: _resolution == null
                                ? 'auto'
                                : '${_resolution!.width}x${_resolution!.height}',
                            items: [
                              ('auto', '自适应窗口'.tr),
                              for (final r in RdpResolution.presets)
                                ('${r.width}x${r.height}', r.label),
                              if (image.hasImage &&
                                  !RdpResolution.presets.contains(actual))
                                (
                                  '${actual.width}x${actual.height}',
                                  actual.label,
                                ),
                            ],
                            onSelected: _selectResolution,
                            icon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_resizeBusy)
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: shadcn.CircularProgressIndicator(),
                                  )
                                else
                                  const Icon(
                                    shadcn.LucideIcons.monitor,
                                    size: 16,
                                  ),
                                const SizedBox(width: 6),
                                Text(
                                  _resolution == null ? '自适应窗口'.tr : '分辨率'.tr,
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  shadcn.LucideIcons.chevronDown,
                                  size: 14,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    shadcn.OutlineButton(
                      onPressed: _secureAttention,
                      child: const Text('Ctrl+Alt+Del'),
                    ),
                    AppIconButton(
                      key: const ValueKey('rdp-enter-fullscreen'),
                      semanticLabel: '全屏（Ctrl+Alt+Enter）'.tr,
                      tooltip: '全屏（Ctrl+Alt+Enter）'.tr,
                      icon: const Icon(shadcn.LucideIcons.maximize, size: 16),
                      onPressed: widget.fullscreenBusy
                          ? null
                          : widget.onToggleFullscreen,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth.isFinite &&
                      constraints.maxHeight.isFinite &&
                      constraints.maxWidth > 0 &&
                      constraints.maxHeight > 0) {
                    final viewport = RdpResolution.fromViewport(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    if (_viewport != viewport) {
                      _viewport = viewport;
                      _scheduleAutomaticResize();
                    }
                  }
                  return Focus(
                    focusNode: _focus,
                    onKeyEvent: _key,
                    child: ColoredBox(
                      color: const Color(0xff000000),
                      child: SizedBox.expand(
                        child: !image.hasImage
                            ? const Center(
                                child: shadcn.CircularProgressIndicator(),
                              )
                            : FittedBox(
                                fit: BoxFit.contain,
                                child: SizedBox(
                                  width: image.width.toDouble(),
                                  height: image.height.toDouble(),
                                  child: Listener(
                                    behavior: HitTestBehavior.opaque,
                                    onPointerDown: (e) => _button(e, true),
                                    onPointerUp: (e) =>
                                        _button(e, e.buttons != 0),
                                    onPointerCancel: (_) => _release(),
                                    onPointerHover: _moving,
                                    onPointerMove: _moving,
                                    onPointerSignal: _scroll,
                                    child: MouseRegion(
                                      cursor:
                                          _cursor?.kind ==
                                                  RdpCursorKind.bitmap ||
                                              _cursor?.kind ==
                                                  RdpCursorKind.hidden
                                          ? SystemMouseCursors.none
                                          : SystemMouseCursors.basic,
                                      onEnter: (event) =>
                                          _cursorPosition.value =
                                              event.localPosition,
                                      onExit: (_) =>
                                          _cursorPosition.value = null,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: RepaintBoundary(
                                              child: CustomPaint(
                                                key: const ValueKey(
                                                  'rdp-desktop-image',
                                                ),
                                                painter: RdpSurfacePainter(
                                                  _surface,
                                                ),
                                                isComplex: true,
                                                willChange: true,
                                              ),
                                            ),
                                          ),
                                          if (_cursorImage != null)
                                            ValueListenableBuilder<Offset?>(
                                              valueListenable: _cursorPosition,
                                              builder: (_, position, _) =>
                                                  position == null
                                                  ? const SizedBox.shrink()
                                                  : Positioned(
                                                      left:
                                                          position.dx -
                                                          _cursor!.hotspotX,
                                                      top:
                                                          position.dy -
                                                          _cursor!.hotspotY,
                                                      child: IgnorePointer(
                                                        child: RawImage(
                                                          key: const ValueKey(
                                                            'rdp-cursor-image',
                                                          ),
                                                          image: _cursorImage,
                                                        ),
                                                      ),
                                                    ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        if (_clipboard != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Obx(() {
              final progress = _clipboard!.progress.value;
              if (progress == null) return const SizedBox.shrink();
              return Center(
                child: shadcn.Card(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: shadcn.CircularProgressIndicator(),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          progress.total == 0
                              ? '正在同步剪贴板'.tr
                              : '正在接收剪贴板文件（@percent%）'.trParams({
                                  'percent':
                                      (progress.transferred *
                                              100 ~/
                                              progress.total)
                                          .toString(),
                                }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      AppIconButton(
                        key: const ValueKey('rdp-clipboard-cancel'),
                        semanticLabel: '取消剪贴板传输'.tr,
                        onPressed: () =>
                            unawaited(_clipboard!.cancelTransfer()),
                        icon: const Icon(shadcn.LucideIcons.x, size: 16),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
      ],
    );
  }
}

/// USB HID keyboard usages to Windows set-1 scan codes. Bit 8 marks E0.
int? rdpScanCode(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >> 16 != 7) return null;
  const codes = <int, int>{
    4: 0x1e,
    5: 0x30,
    6: 0x2e,
    7: 0x20,
    8: 0x12,
    9: 0x21,
    10: 0x22,
    11: 0x23,
    12: 0x17,
    13: 0x24,
    14: 0x25,
    15: 0x26,
    16: 0x32,
    17: 0x31,
    18: 0x18,
    19: 0x19,
    20: 0x10,
    21: 0x13,
    22: 0x1f,
    23: 0x14,
    24: 0x16,
    25: 0x2f,
    26: 0x11,
    27: 0x2d,
    28: 0x15,
    29: 0x2c,
    30: 2,
    31: 3,
    32: 4,
    33: 5,
    34: 6,
    35: 7,
    36: 8,
    37: 9,
    38: 10,
    39: 11,
    40: 0x1c,
    41: 1,
    42: 0x0e,
    43: 0x0f,
    44: 0x39,
    45: 0x0c,
    46: 0x0d,
    47: 0x1a,
    48: 0x1b,
    49: 0x2b,
    50: 0x2b,
    51: 0x27,
    52: 0x28,
    53: 0x29,
    54: 0x33,
    55: 0x34,
    56: 0x35,
    57: 0x3a,
    58: 0x3b,
    59: 0x3c,
    60: 0x3d,
    61: 0x3e,
    62: 0x3f,
    63: 0x40,
    64: 0x41,
    65: 0x42,
    66: 0x43,
    67: 0x44,
    68: 0x57,
    69: 0x58,
    70: 0x137,
    71: 0x46,
    73: 0x152,
    74: 0x147,
    75: 0x149,
    76: 0x153,
    77: 0x14f,
    78: 0x151,
    79: 0x14d,
    80: 0x14b,
    81: 0x150,
    82: 0x148,
    83: 0x45,
    84: 0x135,
    85: 0x37,
    86: 0x4a,
    87: 0x4e,
    88: 0x11c,
    89: 0x4f,
    90: 0x50,
    91: 0x51,
    92: 0x4b,
    93: 0x4c,
    94: 0x4d,
    95: 0x47,
    96: 0x48,
    97: 0x49,
    98: 0x52,
    99: 0x53,
    100: 0x56,
    101: 0x15d,
    224: 0x1d,
    225: 0x2a,
    226: 0x38,
    227: 0x15b,
    228: 0x11d,
    229: 0x36,
    230: 0x138,
    231: 0x15c,
  };
  return codes[usage & 0xffff];
}
