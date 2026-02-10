import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;

class Log {
  // Toggle this based on environment or user preference
  static bool shouldLog = kDebugMode;

  static void d(String tag, String message) {
    if (!shouldLog) return;
    _log('DEBUG', tag, message);
  }

  static void i(String tag, String message) {
    if (!shouldLog) return;
    _log('INFO', tag, message);
  }

  static void w(String tag, String message) {
    if (!shouldLog) return;
    _log('WARN', tag, message);
  }

  static void e(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    if (!shouldLog) return;
    _log('ERROR', tag, message, error: error, stackTrace: stackTrace);
  }

  static void _log(String level, String tag, String message, {Object? error, StackTrace? stackTrace}) {
    // Using developer.log for structured logging that tools can pick up
    developer.log(
      message,
      name: tag,
      level: _levelToInt(level),
      error: error,
      stackTrace: stackTrace,
    );
    
    // Also print to console for poor man's debugging if needed, but developer.log is better
    // debugPrint('[$level] $tag: $message'); 
  }

  static int _levelToInt(String level) {
    switch (level) {
      case 'DEBUG': return 500;
      case 'INFO': return 800;
      case 'WARN': return 900;
      case 'ERROR': return 1000;
      default: return 0;
    }
  }
}
