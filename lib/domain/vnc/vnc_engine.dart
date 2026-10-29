import '../rdp/rdp_engine.dart';

/// VNC uses the shared desktop frame and input contract.
abstract interface class VncEngine implements RdpEngine {}

abstract interface class VncEngineSession implements RdpEngineSession {
  Future<void> keySymbol(int keysym, {required bool down});
}

class VncAuthenticationException extends DesktopAuthenticationException {
  const VncAuthenticationException(super.message, {super.cause});
}
