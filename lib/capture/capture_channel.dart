import 'package:flutter/services.dart';

/// Dart side of the native capture service (see MainActivity.kt).
class CaptureChannel {
  const CaptureChannel();

  static const _channel = MethodChannel('ingresshackstats/capture');

  /// Asks permissions and screen-capture consent, then starts the service.
  /// Returns false if the user declined the capture.
  Future<bool> start() async => await _channel.invokeMethod<bool>('startCapture') ?? false;

  Future<void> stop() => _channel.invokeMethod<void>('stopCapture');

  Future<bool> isRunning() async => await _channel.invokeMethod<bool>('isRunning') ?? false;

  Future<bool> isDebug() async => await _channel.invokeMethod<bool>('isDebug') ?? false;

  Future<void> setDebug(bool enabled) =>
      _channel.invokeMethod<void>('setDebug', {'enabled': enabled});

  /// Captures stored by the service since the last call, as JSON strings.
  Future<List<String>> drainPending() async =>
      await _channel.invokeListMethod<String>('drainPending') ?? const [];
}
