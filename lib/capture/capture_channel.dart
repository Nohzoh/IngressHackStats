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

  /// Android 13+ can offer to add the quick settings tile from the app.
  Future<bool> canAddTile() async => await _channel.invokeMethod<bool>('canAddTile') ?? false;

  /// Asks to add the tile; returns "added", "already", "refused" or "error".
  Future<String> addTile() async => await _channel.invokeMethod<String>('addTile') ?? 'error';

  /// Whether the quick settings tile is in place (as far as the app knows).
  Future<bool> tileAdded() async => await _channel.invokeMethod<bool>('tileAdded') ?? false;

  /// {notifications: bool, location: bool}
  Future<Map<String, bool>> permissionStatus() async =>
      await _channel.invokeMapMethod<String, bool>('permissionStatus') ?? const {};

  /// Asks the missing permissions, returns the new status.
  Future<Map<String, bool>> requestPermissions() async =>
      await _channel.invokeMapMethod<String, bool>('requestPermissions') ?? const {};

  /// Small persisted booleans (onboarding done…).
  Future<bool> getFlag(String key) async => await _channel.invokeMethod<bool>('getFlag', {'key': key}) ?? false;

  Future<void> setFlag(String key, bool value) =>
      _channel.invokeMethod<void>('setFlag', {'key': key, 'value': value});

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
