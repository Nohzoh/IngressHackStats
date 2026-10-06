/// One line of text found by ML Kit, with its position on screen (pixels).
class OcrLine {
  const OcrLine(this.text, {this.x = 0, this.y = 0, this.h = 0});

  final String text;
  final double x;
  final double y;
  final double h;

  double get centerY => y + h / 2;

  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
        json['t'] as String? ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        h: (json['h'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {'t': text, 'x': x, 'y': y, 'h': h};
}

/// A screen frame captured by the native service whose text looked like a
/// hack result (or any frame, in debug mode).
class OcrCapture {
  const OcrCapture({
    required this.timestamp,
    required this.lines,
    this.screenWidth = 0,
    this.screenHeight = 0,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.debug = false,
  });

  final int timestamp;
  final List<OcrLine> lines;
  final double screenWidth;
  final double screenHeight;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final bool debug;

  String get rawText => lines.map((l) => l.text).join('\n');

  factory OcrCapture.fromJson(Map<String, dynamic> json) => OcrCapture(
        timestamp: (json['ts'] as num).toInt(),
        lines: (json['lines'] as List<dynamic>? ?? const [])
            .map((e) => OcrLine.fromJson(e as Map<String, dynamic>))
            .toList(),
        screenWidth: (json['w'] as num?)?.toDouble() ?? 0,
        screenHeight: (json['h'] as num?)?.toDouble() ?? 0,
        latitude: (json['lat'] as num?)?.toDouble(),
        longitude: (json['lng'] as num?)?.toDouble(),
        accuracy: (json['acc'] as num?)?.toDouble(),
        debug: json['debug'] as bool? ?? false,
      );
}
