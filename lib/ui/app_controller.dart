import 'dart:async';

import 'package:flutter/widgets.dart';

import '../capture/capture_channel.dart';
import '../data/reward_repository.dart';

/// State shared by every tab: the database, the capture service state and
/// its diagnostics. Pulls the captures from the service every few seconds
/// and when the app comes back to the front.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({this.capture = const CaptureChannel()});

  final CaptureChannel capture;

  RewardRepository? repository;
  Object? error;

  bool running = false;
  bool debug = false;
  int ocrInterval = 250;
  bool canAddTile = false;
  bool tileAdded = false;
  Map<String, bool> permissions = const {};
  Map<String, Object?> diagnostics = const {};
  Map<String, int> kinds = const {};
  String serviceLog = '';

  /// Increases each time new data was stored: tabs reload their content.
  int dataVersion = 0;

  Timer? _poll;
  bool _syncing = false;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      repository = await RewardRepository.open();
      debug = await capture.isDebug();
      ocrInterval = await capture.ocrInterval();
      canAddTile = await capture.canAddTile();
      await sync();
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => sync());
    } catch (e) {
      error = e;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync();
  }

  /// Pulls pending captures from the service and refreshes the state.
  Future<void> sync() async {
    final repo = repository;
    if (repo == null || _syncing) return;
    _syncing = true;
    try {
      final pending = await capture.drainPending();
      if (pending.isNotEmpty) {
        await repo.ingest(pending);
        dataVersion++;
      }
      running = await capture.isRunning();
      diagnostics = await capture.diagnostics();
      kinds = await repo.countByKind();
      serviceLog = await capture.serviceLog();
      tileAdded = await capture.tileAdded();
      permissions = await capture.permissionStatus();
      error = null;
    } catch (e) {
      error = e;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// To call after changing the data outside a sync (deletion, re-analysis).
  void dataChanged() {
    dataVersion++;
    notifyListeners();
  }

  /// Starts or stops the capture. Returns false if the user declined.
  Future<bool> toggleCapture() async {
    var ok = true;
    if (running) {
      await capture.stop();
    } else {
      ok = await capture.start();
    }
    // The service needs a moment to report its state.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await sync();
    return ok;
  }

  Future<void> setDebug(bool value) async {
    await capture.setDebug(value);
    debug = value;
    notifyListeners();
  }

  Future<void> setOcrInterval(int ms) async {
    await capture.setOcrInterval(ms);
    ocrInterval = ms;
    notifyListeners();
  }

  Future<String> addTile() async {
    final result = await capture.addTile();
    tileAdded = await capture.tileAdded();
    notifyListeners();
    return result;
  }

  Future<void> requestPermissions() async {
    permissions = await capture.requestPermissions();
    notifyListeners();
  }

  int diag(String key) => (diagnostics[key] as num?)?.toInt() ?? 0;

  /// Milliseconds since the capture started (0 when stopped).
  int get captureStartedAt => running ? diag('startedAt') : 0;

  /// Average OCR duration (ms) and passes per second since the start.
  ({int avgMs, double perSecond})? get ocrSpeed {
    final runs = diag('ocrRuns');
    if (runs == 0) return null;
    final elapsed = (diag('now') - diag('startedAt')) / 1000;
    return (avgMs: (diag('ocrTotalMs') / runs).round(), perSecond: elapsed > 0 ? runs / elapsed : 0);
  }

  /// Last journal line, newest last in the file.
  String get lastLogLine {
    final lines = serviceLog.trim().split('\n');
    return lines.isEmpty ? '' : lines.last;
  }
}
