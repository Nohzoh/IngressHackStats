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

  /// Minimum delay between two OCR passes, in milliseconds.
  Future<int> ocrInterval() async => await _channel.invokeMethod<int>('getOcrInterval') ?? 250;

  Future<void> setOcrInterval(int ms) => _channel.invokeMethod<void>('setOcrInterval', {'ms': ms});

  /// Native pipeline counters (frames, OCR runs, kept frames, last text…).
  Future<Map<String, Object?>> diagnostics() async =>
      await _channel.invokeMapMethod<String, Object?>('diagnostics') ?? const {};

  /// Persistent journal of the capture lifecycle (start, consent, errors…).
  Future<String> serviceLog() async => await _channel.invokeMethod<String>('serviceLog') ?? '';

  Future<void> clearServiceLog() => _channel.invokeMethod<void>('clearServiceLog');

  /// Captures stored by the service since the last call, as JSON strings.
  Future<List<String>> drainPending() async =>
      await _channel.invokeListMethod<String>('drainPending') ?? const [];
}
