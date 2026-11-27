import 'dart:async';
import 'dart:math' as math;
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
import '../../domain/rdp/rdp_network_stats.dart';
import '../../domain/rdp/rdp_resolution.dart';
import '../../domain/ssh/ssh_engine.dart';
import '../../domain/vnc/vnc_engine.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_menu.dart';
import '../navigation/app_navigation.dart';
import '../navigation/app_notice.dart';
import '../shell/workspace_visibility.dart';
import '../theme/app_theme.dart';
import '../vnc/vnc_keyboard.dart';
import 'rdp_fullscreen_toolbar.dart';
import 'rdp_input_queue.dart';
import 'rdp_local_text_input.dart';
import 'rdp_network_indicator.dart';
import 'rdp_surface.dart';
import 'rdp_windows_cursor.dart';
import 'rdp_windows_keyboard.dart';

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
    with WidgetsBindingObserver, WorkspaceVisibilityObserver<RdpDesktopPanel> {
  final _focus = FocusNode();
  final _pressed = <int>{};
  final _vncPressed = <PhysicalKeyboardKey, int>{};
  final _buttons = <int>{};
  final _macMeta = <PhysicalKeyboardKey>{};
  final _clipboardShortcutKeys = <PhysicalKeyboardKey>{};
  RdpClipboardController? _clipboard;
  StreamSubscription<void>? _frames;
  StreamSubscription<RdpNetworkStats>? _networkSub;
  RdpNetworkStats? _networkStats;
  final _surface = RdpSurface();
  final _cursorPosition = ValueNotifier<Offset?>(null);
  ui.Image? _cursorImage;
  RdpWindowsCursor? _nativeCursor;
  RdpCursor? _cursor;
  late final RdpInputQueue _inputs;
  Timer? _moveTimer;
  Offset? _move;
  Timer? _wheelTimer;
  Offset _wheelPosition = Offset.zero;
  double _wheelDeltaX = 0;
  double _wheelDeltaY = 0;
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
  bool _typingText = false;
  bool _useLocalIme = false;
  late final RdpLocalTextInput _localTextInput;
  late final RdpWindowsKeyboard _windowsKeyboard;
  Offset? _imeAnchor;
  int _openMenus = 0;
  static const _maxTypedText = 2048;

  bool get _appResumed => _lifecycle == AppLifecycleState.resumed;
  bool get _clipboardAvailable =>
      _lifecycle != AppLifecycleState.paused &&
      _lifecycle != AppLifecycleState.detached;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _localTextInput = RdpLocalTextInput(_commitLocalText);
    _windowsKeyboard = RdpWindowsKeyboard(
      onKey: _captureScan,
      onLost: _release,
    );
    _inputs = RdpInputQueue(onError: _fail, sendBatch: _writeInputs);
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
    _bindNetworkStats();
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  Future<void> _decode(RdpFrame frame) async {
    final previousWidth = _surface.width;
    final previousHeight = _surface.height;
    final previousTexture = _surface.textureId;
    ui.Image? cursorImage;
    RdpWindowsCursor? nativeCursor;
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
        if (widget.session is! VncEngineSession) {
          nativeCursor = await RdpWindowsCursor.create(cursor);
        }
        if (mounted && nativeCursor == null) {
          cursorImage = await decodeRdpPixels(
            cursor.rgba,
            cursor.width,
            cursor.height,
          );
        }
      }
      if (!mounted) {
        cursorImage?.dispose();
        nativeCursor?.release();
        return;
      }
      final previousCursor = _cursorImage;
      final previousNativeCursor = _nativeCursor;
      final layoutChanged =
          previousWidth != _surface.width || previousHeight != _surface.height;
      final actual = RdpResolution(_surface.width, _surface.height);
      final awaiting = _awaitingResolution;
      final resizeConfirmed =
          awaiting == actual ||
          (layoutChanged && awaiting?.matchesAligned(actual) == true);
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
        _nativeCursor = nativeCursor;
      }
      // Surface notifications repaint pixels without rebuilding any widgets.
      if (layoutChanged ||
          cursor != null ||
          resizeConfirmed ||
          previousTexture != _surface.textureId) {
        setState(() {});
      }
      if (cursor != null) {
        previousCursor?.dispose();
        if (previousNativeCursor != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            previousNativeCursor.release();
          });
        }
      }
      if (layoutChanged || resizeConfirmed) _scheduleAutomaticResize();
    } on Object {
      cursorImage?.dispose();
      nativeCursor?.release();
      rethrow;
    }
  }

  void _fail(Object error) {
    if (!mounted || _failed) return;
    setState(() {
      _failed = true;
      _typingText = false;
    });
    _inputs.cancel();
    _localTextInput.close();
    _windowsKeyboard.setEnabled(false);
    _resizeDebounce?.cancel();
    _resizeConfirmation?.cancel();
    _clipboard?.setActive(false);
    widget.onError(
      error is SshEngineException ? error.message : '远程桌面已断开，请重新连接',
    );
  }

  void _send(Future<void> Function() action) {
    if (_failed) return;
    _inputs.add(action);
  }

  Future<void> _writeInputs(List<RdpInputEvent> events) async {
    if (_failed) return;
    final session = widget.session;
    if (session is RdpBatchInputSession) {
      await session.inputBatch(events);
    } else {
      for (final event in events) {
        if (_failed) return;
        await switch (event) {
          RdpKeyInput() =>
            session is VncEngineSession
                ? session.keySymbol(event.scanCode, down: event.down)
                : session.key(
                    event.scanCode,
                    down: event.down,
                    extended: event.extended,
                  ),
          RdpPointerInput() => session.pointer(
            event.x,
            event.y,
            event.flags,
            wheel: event.wheel,
          ),
        };
      }
    }
  }

  void _sendScan(int scan, {required bool down}) => _inputs.addEvent(
    RdpKeyInput(scan & 0xff, down: down, extended: scan > 255),
  );

  void _syncFrames() {
    final paused = !widget.active || !_appResumed || !workspaceVisible;
    if (paused == _framesPaused) return;
    _framesPaused = paused;
    if (paused) {
      _frames?.pause();
    } else {
      _frames?.resume();
    }
  }

  @override
  void onWorkspaceVisibilityChanged() {
    if (!workspaceVisible) _release();
    _syncFrames();
    _syncLocalTextInput();
    _syncRemoteKeyboard();
    _syncKeyboard();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _release();
    _syncLocalTextInput();
    _syncRemoteKeyboard();
    _syncKeyboard();
  }

  void _syncKeyboard() {
    final session = widget.session;
    if (session is! RdpKeyboardSyncSession ||
        !widget.active ||
        !_appResumed ||
        !workspaceVisible ||
        !_focus.hasFocus ||
        _failed) {
      return;
    }
    final locks = HardwareKeyboard.instance.lockModesEnabled;
    final flags =
        (locks.contains(KeyboardLockMode.scrollLock) ? 1 : 0) |
        (locks.contains(KeyboardLockMode.numLock) ? 2 : 0) |
        (locks.contains(KeyboardLockMode.capsLock) ? 4 : 0);
    _send(() => session.synchronizeKeyboard(flags));
  }

  void _syncLocalTextInput() {
    if (!_useLocalIme ||
        !widget.active ||
        !_appResumed ||
        !workspaceVisible ||
        !_focus.hasFocus ||
        _failed) {
      _localTextInput.close();
      return;
    }
    final view = View.of(context);
    _localTextInput
      ..setAnchor(
        _imeAnchor ?? const Offset(24, 96),
        view.physicalSize / view.devicePixelRatio,
      )
      ..open(view.viewId);
  }

  bool get _captureKeyboard =>
      !_useLocalIme &&
      !_failed &&
      widget.active &&
      widget.fullscreen &&
      !widget.fullscreenBusy &&
      _appResumed &&
      workspaceVisible &&
      _focus.hasFocus &&
      _openMenus == 0 &&
      widget.session is! VncEngineSession;

  void _syncRemoteKeyboard() => _windowsKeyboard.setEnabled(_captureKeyboard);

  void _captureScan(int scan, bool down) {
    if (!_captureKeyboard) return;
    final control = _pressed.contains(0x1d) || _pressed.contains(0x11d);
    final alt = _pressed.contains(0x38) || _pressed.contains(0x138);
    if (down &&
        (scan == 0x1c || scan == 0x11c) &&
        control &&
        alt &&
        widget.onToggleFullscreen != null) {
      _windowsKeyboard.setEnabled(false);
      _release();
      widget.onToggleFullscreen!();
      return;
    }
    _forwardScan(scan, down: down, paste: scan == 0x2f && control);
  }

  void _selectKeyboardMode(bool useLocalIme) {
    if (_useLocalIme != useLocalIme) {
      _release();
      setState(() => _useLocalIme = useLocalIme);
      _syncLocalTextInput();
      _syncRemoteKeyboard();
    }
    _focus.requestFocus();
  }

  void _commitLocalText(String text) {
    if (_failed || !widget.active || !_appResumed || !_focus.hasFocus) return;
    final session = widget.session;
    for (var offset = 0; offset < text.length;) {
      var end = math.min(offset + _maxTypedText, text.length);
      if (end < text.length && (text.codeUnitAt(end - 1) & 0xfc00) == 0xd800) {
        end--;
      }
      final chunk = text.substring(offset, end);
      _send(() => session.text(chunk));
      offset = end;
    }
  }

  void _bindNetworkStats() {
    unawaited(_networkSub?.cancel());
    _networkSub = null;
    final session = widget.session;
    if (session is! RdpNetworkSession) {
      _networkStats = null;
      _surface.setLowQuality(false);
      return;
    }
    _networkStats = session.latestNetworkStats;
    _surface.setLowQuality(_networkStats?.qualityTier == RdpQualityTier.low);
    _networkSub = session.networkStats.listen((stats) {
      if (!mounted) return;
      _surface.setLowQuality(stats.qualityTier == RdpQualityTier.low);
      if (_networkStats != stats) {
        setState(() => _networkStats = stats);
      }
    });
  }

  void _selectQualityMode(RdpQualityMode mode) {
    final session = widget.session;
    if (session is! RdpNetworkSession || _failed) return;
    unawaited(() async {
      try {
        await session.setQualityMode(mode);
      } on Object catch (error) {
        if (mounted && widget.active) {
          AppNotice.error(
            error is SshEngineException ? error.message : '无法切换画质模式，请重试',
          );
        }
      }
    }());
    _focus.requestFocus();
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
    _syncLocalTextInput();
    _syncRemoteKeyboard();
    _syncKeyboard();
    _syncClipboard();
  }

  @override
  void didUpdateWidget(RdpDesktopPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.session, oldWidget.session)) {
      _bindNetworkStats();
    }
    _syncFrames();
    _syncClipboard();
    if (widget.active && !oldWidget.active) {
      _focus.requestFocus();
      _scheduleAutomaticResize();
    }
    if (!widget.active && oldWidget.active) {
      _release();
      _focus.unfocus();
      _resizeDebounce?.cancel();
      _resizeConfirmation?.cancel();
      _resizeSerial++;
      _awaitingResolution = null;
      _resizeBusy = false;
    }
    if (widget.fullscreen != oldWidget.fullscreen) {
      _release();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) {
          _focus.requestFocus();
          _syncRemoteKeyboard();
        }
      });
    }
    _syncLocalTextInput();
    _syncRemoteKeyboard();
  }

  void _release() {
    _fullscreenShortcutHeld = false;
    _moveTimer?.cancel();
    _moveTimer = null;
    _move = null;
    _wheelTimer?.cancel();
    _wheelTimer = null;
    _wheelDeltaX = 0;
    _wheelDeltaY = 0;
    _cursorPosition.value = null;
    _macMeta.clear();
    _clipboardShortcutKeys.clear();
    final vncSession = widget.session;
    if (vncSession is VncEngineSession) {
      for (final symbol in _vncPressed.values) {
        _inputs.addEvent(RdpKeyInput(symbol, down: false));
      }
      _vncPressed.clear();
    }
    for (final scan in _pressed.toList()) {
      _sendScan(scan, down: false);
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
    // VNC preserves native Super/Command keysyms (important for remote macOS).
    if (widget.session is! VncEngineSession &&
        _clipboard != null &&
        defaultTargetPlatform == TargetPlatform.macOS) {
      final physical = event.physicalKey;
      if (physical == PhysicalKeyboardKey.metaLeft ||
          physical == PhysicalKeyboardKey.metaRight) {
        if (event is KeyUpEvent) {
          _macMeta.remove(physical);
          final scan = rdpScanCode(physical)!;
          if (_pressed.remove(scan)) {
            _sendScan(scan, down: false);
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
          await _writeInputs([
            const RdpKeyInput(0x1d, down: true),
            RdpKeyInput(scan, down: true),
            RdpKeyInput(scan, down: false),
            const RdpKeyInput(0x1d, down: false),
          ]);
        });
        return KeyEventResult.handled;
      }
      for (final meta in _macMeta) {
        final scan = rdpScanCode(meta)!;
        if (_pressed.add(scan)) {
          _sendScan(scan, down: true);
        }
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) _fullscreenShortcutHeld = false;
      if (_fullscreenShortcutHeld) {
        if (event is KeyUpEvent) _fullscreenShortcutHeld = false;
        return KeyEventResult.handled;
      }
      if (widget.onToggleFullscreen != null &&
          HardwareKeyboard.instance.isControlPressed &&
          HardwareKeyboard.instance.isAltPressed &&
          (event is KeyDownEvent || event is KeyRepeatEvent)) {
        if (event is KeyDownEvent) {
          _release();
          _fullscreenShortcutHeld = true;
          if (!widget.fullscreenBusy) widget.onToggleFullscreen!();
        }
        return KeyEventResult.handled;
      }
    }
    final vncSession = widget.session;
    if (vncSession is VncEngineSession) {
      // A modifier sent before composition must still be released remotely.
      if (!_vncPressed.containsKey(event.physicalKey) &&
          _localTextInput.handlesKey(event)) {
        return KeyEventResult.skipRemainingHandlers;
      }
      final down = event is! KeyUpEvent;
      final symbol = down
          ? _vncPressed[event.physicalKey] ?? vncKeySymbol(event)
          : _vncPressed.remove(event.physicalKey);
      if (symbol == null) return KeyEventResult.ignored;
      if (down) _vncPressed[event.physicalKey] = symbol;
      final clipboard = _clipboard;
      final isPaste =
          down &&
          event is KeyDownEvent &&
          event.physicalKey == PhysicalKeyboardKey.keyV &&
          (HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed);
      if (isPaste && clipboard != null) {
        _send(() async {
          if (!await clipboard.syncBeforePaste()) return;
          await _writeInputs([RdpKeyInput(symbol, down: true)]);
        });
      } else {
        _inputs.addEvent(RdpKeyInput(symbol, down: down));
      }
      return KeyEventResult.handled;
    }
    final scan = rdpScanCode(event.physicalKey);
    // A modifier sent before composition must still be released remotely.
    if ((scan == null || !_pressed.contains(scan)) &&
        _localTextInput.handlesKey(event)) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (scan == null) return KeyEventResult.ignored;
    _forwardScan(
      scan,
      down: event is! KeyUpEvent,
      paste:
          event.physicalKey == PhysicalKeyboardKey.keyV &&
          HardwareKeyboard.instance.isControlPressed,
    );
    return KeyEventResult.handled;
  }

  void _forwardScan(int scan, {required bool down, required bool paste}) {
    if (down) {
      _pressed.add(scan);
    } else if (!_pressed.remove(scan)) {
      return;
    }
    final clipboard = _clipboard;
    if (down && paste && clipboard != null) {
      _send(() async {
        if (!await clipboard.syncBeforePaste()) return;
        await _writeInputs([
          RdpKeyInput(scan & 0xff, down: down, extended: scan > 255),
        ]);
      });
    } else {
      _sendScan(scan, down: down);
    }
  }

  void _pointer(Offset position, int flags) {
    final image = _surface;
    if (!image.hasImage) return;
    final x = position.dx.round().clamp(0, image.width - 1);
    final y = position.dy.round().clamp(0, image.height - 1);
    _inputs.addEvent(RdpPointerInput(x, y, flags));
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final position = _move;
    _move = null;
    if (position != null) _pointer(position, 0x0800);
  }

  void _flushWheel() {
    _wheelTimer?.cancel();
    _wheelTimer = null;
    final dy = _wheelDeltaY.round();
    final dx = _wheelDeltaX.round();
    _wheelDeltaY -= dy;
    _wheelDeltaX -= dx;
    if (_failed || !_surface.hasImage) return;
    final x = _wheelPosition.dx.round().clamp(0, _surface.width - 1);
    final y = _wheelPosition.dy.round().clamp(0, _surface.height - 1);
    _inputs.addWheel(dx, dy, (horizontal, vertical) async {
      var events = <RdpInputEvent>[];
      Future<void> sendAxis(int delta, int axis) async {
        final flags = axis | (delta > 0 ? 0x0100 : 0);
        var remaining = delta.abs();
        while (remaining > 0 && !_failed) {
          final step = math.min(remaining, 255);
          events.add(RdpPointerInput(x, y, flags, wheel: step));
          if (events.length == RdpInputQueue.maxBatchSize) {
            await _writeInputs(events);
            events = [];
          }
          remaining -= step;
        }
      }

      await sendAxis(vertical, 0x0200);
      await sendAxis(horizontal, 0x0400);
      if (events.isNotEmpty) await _writeInputs(events);
    });
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
    if (down && _useLocalIme) {
      _imeAnchor = event.position;
      _syncLocalTextInput();
    }
    _focus.requestFocus();
    _flushMove();
    _flushWheel();
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
      _wheelPosition = event.localPosition;
      _wheelDeltaY += event.scrollDelta.dy;
      _wheelDeltaX += event.scrollDelta.dx;
      _wheelTimer ??= Timer(const Duration(milliseconds: 16), _flushWheel);
    });
  }

  void _scheduleAutomaticResize() {
    _resizeDebounce?.cancel();
    if (!widget.dynamicResolution ||
        _resolution != null ||
        _viewport == null ||
        _viewport!.matchesAligned(
          RdpResolution(_surface.width, _surface.height),
        ) ||
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
    if (target != null) unawaited(_resize(target, userInitiated: true));
    _focus.requestFocus();
  }

  Future<void> _resize(
    RdpResolution target, {
    bool userInitiated = false,
  }) async {
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
        _resizeFailed('远端不支持动态分辨率，已保留当前画面', notify: userInitiated);
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

  void _resizeFailed(String message, {bool notify = true}) {
    _resizeConfirmation?.cancel();
    _resizeDebounce?.cancel();
    setState(() {
      _resizeBusy = false;
      _awaitingResolution = null;
      _resolution = RdpResolution(_surface.width, _surface.height);
    });
    if (notify && widget.active) AppNotice.error(message);
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
      _sendScan(scan, down: true);
    }
    for (final scan in [0x153, 0x38, 0x1d]) {
      _sendScan(scan, down: false);
    }
    _focus.requestFocus();
  }

  Future<void> _typeClipboard() async {
    if (_typingText || _failed || !widget.active) return;
    final session = widget.session;
    bool current() =>
        mounted &&
        widget.active &&
        _appResumed &&
        !_failed &&
        identical(widget.session, session);
    setState(() => _typingText = true);
    var queued = false;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!current()) return;
      final text = (data?.text ?? '')
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      if (text.isEmpty) {
        AppNotice.error('剪贴板没有可键入的文本');
        return;
      }
      if (text.length > _maxTypedText) {
        AppNotice.error(
          '剪贴板文本太长，最多可键入 @count 个字符'.trParams({'count': '$_maxTypedText'}),
        );
        return;
      }
      if (text.contains('\n') || text.contains('\t')) {
        final accepted = await AppNavigation.dialog<bool>(
          AppDialog(
            title: Text('键入剪贴板文本'.tr),
            content: Text('文本包含换行或制表符，可能触发远程窗口的提交或焦点切换。'.tr),
            actions: [
              shadcn.OutlineButton(
                onPressed: () => AppNavigation.closeDialog(result: false),
                child: Text('取消'.tr),
              ),
              shadcn.PrimaryButton(
                onPressed: () => AppNavigation.closeDialog(result: true),
                child: Text('继续键入'.tr),
              ),
            ],
          ),
        );
        if (accepted != true || !current()) return;
      }
      _release();
      queued = true;
      _send(() async {
        try {
          if (current()) await session.text(text);
        } on Object {
          if (current()) AppNotice.error('无法键入剪贴板文本');
        } finally {
          if (mounted) setState(() => _typingText = false);
        }
      });
    } on Object {
      if (current()) AppNotice.error('无法读取剪贴板文本');
    } finally {
      if (mounted && !queued) setState(() => _typingText = false);
      if (current()) _focus.requestFocus();
    }
  }

  void _menuVisibilityChanged(bool open) {
    if (!mounted) return;
    setState(() => _openMenus = math.max(0, _openMenus + (open ? 1 : -1)));
    if (open) _release();
    _syncRemoteKeyboard();
    if (!open && widget.active) _focus.requestFocus();
  }

  Widget _toolbar(BuildContext context) => Container(
    key: const ValueKey('rdp-toolbar'),
    width: double.infinity,
    decoration: BoxDecoration(
      color: AppTheme.surface(context),
      border: Border(bottom: BorderSide(color: AppTheme.border(context))),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: _toolbarControls(),
    ),
  );

  List<Widget> _toolbarControls() {
    final image = _surface;
    final actual = RdpResolution(image.width, image.height);
    return [
      Text(
        !image.hasImage
            ? '远程桌面'.tr
            : '${widget.protocolLabel} · ${image.width} × ${image.height}',
        overflow: TextOverflow.ellipsis,
      ),
      if (widget.session is RdpNetworkSession)
        RdpNetworkBadge(
          stats: _networkStats,
          compact: widget.fullscreen,
          enabled: widget.active && !_failed,
          onSelectQualityMode: _selectQualityMode,
          onMenuVisibilityChanged: _menuVisibilityChanged,
        ),
      if (widget.dynamicResolution)
        AppMenuButton<String>(
          key: const ValueKey('rdp-resolution-menu'),
          enabled: !_resizeBusy && image.hasImage,
          semanticLabel: '分辨率'.tr,
          tooltip: '分辨率'.tr,
          selectedValue: _resolution == null
              ? 'auto'
              : '${_resolution!.width}x${_resolution!.height}',
          items: [
            ('auto', '自适应窗口'.tr),
            for (final r in RdpResolution.presets)
              ('${r.width}x${r.height}', r.label),
            if (image.hasImage && !RdpResolution.presets.contains(actual))
              ('${actual.width}x${actual.height}', actual.label),
          ],
          onSelected: _selectResolution,
          onMenuVisibilityChanged: _menuVisibilityChanged,
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_resizeBusy)
                const SizedBox.square(
                  dimension: 14,
                  child: shadcn.CircularProgressIndicator(),
                )
              else
                const AppIcon(AppIcons.monitor, size: 16),
              if (!widget.fullscreen) ...[
                const SizedBox(width: 6),
                Text(_resolution == null ? '自适应窗口'.tr : '分辨率'.tr),
              ],
              const SizedBox(width: 4),
              const AppIcon(AppIcons.chevronDown, size: 14),
            ],
          ),
        ),
      AppMenuButton<bool>(
        key: const ValueKey('rdp-keyboard-mode'),
        enabled: widget.active && !_failed,
        semanticLabel: '键盘输入模式'.tr,
        tooltip: '键盘输入模式'.tr,
        selectedValue: _useLocalIme,
        items: [(false, '远端键盘'.tr), (true, '本机输入法'.tr)],
        onSelected: _selectKeyboardMode,
        onMenuVisibilityChanged: _menuVisibilityChanged,
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((_useLocalIme ? '本机输入法' : '远端键盘').tr),
            const SizedBox(width: 4),
            const AppIcon(AppIcons.chevronDown, size: 14),
          ],
        ),
      ),
      AppIconButton(
        key: const ValueKey('rdp-type-clipboard'),
        semanticLabel: '键入剪贴板文本'.tr,
        tooltip: '键入剪贴板文本'.tr,
        icon: const AppIcon(AppIcons.fileImport, size: 16),
        onPressed: _typingText || !widget.active
            ? null
            : () => unawaited(_typeClipboard()),
      ),
      shadcn.OutlineButton(
        onPressed: _secureAttention,
        size: widget.fullscreen
            ? shadcn.ButtonSize.small
            : shadcn.ButtonSize.normal,
        child: const Text('Ctrl+Alt+Del'),
      ),
      if (widget.fullscreen)
        shadcn.OutlineButton(
          key: const ValueKey('rdp-exit-fullscreen'),
          onPressed: widget.fullscreenBusy ? null : widget.onToggleFullscreen,
          size: shadcn.ButtonSize.small,
          leading: const AppIcon(AppIcons.minimize, size: 15),
          child: Text('退出全屏'.tr),
        )
      else
        AppIconButton(
          key: const ValueKey('rdp-enter-fullscreen'),
          semanticLabel: '全屏（Ctrl+Alt+Enter）'.tr,
          tooltip: '全屏（Ctrl+Alt+Enter）'.tr,
          icon: const AppIcon(AppIcons.maximize, size: 16),
          onPressed: widget.fullscreenBusy ? null : widget.onToggleFullscreen,
        ),
    ];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _windowsKeyboard.setEnabled(false);
    _resizeDebounce?.cancel();
    _resizeConfirmation?.cancel();
    _release();
    _localTextInput.close();
    _clipboard?.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    unawaited(_frames?.cancel());
    unawaited(_networkSub?.cancel());
    _surface.dispose();
    _cursorImage?.dispose();
    _nativeCursor?.release();
    _cursorPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            if (!widget.fullscreen) _toolbar(context),
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
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const shadcn.CircularProgressIndicator(),
                                    const SizedBox(height: 12),
                                    Text(
                                      '正在等待远程桌面画面…'.tr,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFFB8C0CC),
                                      ),
                                    ),
                                  ],
                                ),
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
                                          _nativeCursor ??
                                          (_cursor?.kind ==
                                                      RdpCursorKind.bitmap ||
                                                  _cursor?.kind ==
                                                      RdpCursorKind.hidden
                                              ? SystemMouseCursors.none
                                              : SystemMouseCursors.basic),
                                      onEnter: (event) =>
                                          _cursorPosition.value =
                                              event.localPosition,
                                      onExit: (_) =>
                                          _cursorPosition.value = null,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: RepaintBoundary(
                                              child: image.textureId != null
                                                  ? Texture(
                                                      textureId:
                                                          image.textureId!,
                                                      filterQuality:
                                                          _networkStats
                                                                  ?.qualityTier ==
                                                              RdpQualityTier.low
                                                          ? ui
                                                                .FilterQuality
                                                                .none
                                                          : ui
                                                                .FilterQuality
                                                                .low,
                                                    )
                                                  : CustomPaint(
                                                      key: const ValueKey(
                                                        'rdp-desktop-image',
                                                      ),
                                                      painter:
                                                          RdpSurfacePainter(
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
        if (widget.fullscreen)
          Positioned(
            top: math.max(
              MediaQuery.paddingOf(context).top,
              shadcn.Theme.of(context).platform == TargetPlatform.macOS
                  ? 24
                  : 0,
            ),
            left: 0,
            right: 0,
            child: Align(
              alignment: Alignment.topCenter,
              child: RdpFullscreenToolbar(
                controls: _toolbarControls(),
                holdOpen: _openMenus > 0 || _typingText,
                onRefocus: _focus.requestFocus,
              ),
            ),
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
                        icon: const AppIcon(AppIcons.x, size: 16),
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
