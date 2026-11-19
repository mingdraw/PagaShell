import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../domain/proxy/dynamic_proxy_engine.dart';

class ProxyTrafficStatus extends StatefulWidget {
  const ProxyTrafficStatus({required this.source, super.key});

  final DynamicProxyTrafficSource source;

  @override
  State<ProxyTrafficStatus> createState() => _ProxyTrafficStatusState();
}

class _ProxyTrafficStatusState extends State<ProxyTrafficStatus> {
  final _clock = Stopwatch()..start();
  Timer? _timer;
  ProxyTraffic? _last;
  int _sampleTime = 0;
  double _sentRate = 0;
  double _receivedRate = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_sample());
  }

  Future<void> _sample() async {
    ProxyTraffic? sample;
    try {
      sample = await widget.source.readTraffic().timeout(
        const Duration(seconds: 3),
      );
    } on Object {
      // A failed statistics read must not affect the proxy.
    }
    if (!mounted) return;
    final now = _clock.elapsedMilliseconds;
    final previous = _last;
    setState(() {
      final elapsed = (now - _sampleTime) / 1000;
      _sentRate = sample != null && previous != null && elapsed > 0
          ? (sample.sent - previous.sent).clamp(0, sample.sent) / elapsed
          : 0;
      _receivedRate = sample != null && previous != null && elapsed > 0
          ? (sample.received - previous.received).clamp(0, sample.received) /
                elapsed
          : 0;
      _last = sample;
      _sampleTime = now;
    });
    _timer = Timer(const Duration(seconds: 1), () => unawaited(_sample()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _amount(num bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var unit = 0;
    var value = bytes.toDouble();
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final sample = _last;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 12, color: colors.mutedForeground),
        child: sample == null
            ? Text('等待流量采样…'.tr)
            : Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text(
                    '发送 @rate/s · 累计 @total'.trParams({
                      'rate': _amount(_sentRate),
                      'total': _amount(sample.sent),
                    }),
                  ),
                  Text(
                    '接收 @rate/s · 累计 @total'.trParams({
                      'rate': _amount(_receivedRate),
                      'total': _amount(sample.received),
                    }),
                  ),
                ],
              ),
      ),
    );
  }
}
