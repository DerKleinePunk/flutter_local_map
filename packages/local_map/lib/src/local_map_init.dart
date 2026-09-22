import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'config/map_config.dart';

/// Einmalige Initialisierung des Packages.
class LocalMap {
  const LocalMap._();

  static bool _initialized = false;

  /// Richtet alles ein, was das Package zur Laufzeit braucht:
  ///
  /// * `WidgetsFlutterBinding.ensureInitialized()`
  /// * den sqflite-FFI-Backend auf Desktop-Plattformen (wird vom
  ///   [OfflineGeocoder] benoetigt)
  /// * optional [MapConfig.defaults], damit Widgets und Services ohne
  ///   explizite Config auskommen
  ///
  /// Muss vor `runApp()` aufgerufen werden. Mehrfache Aufrufe sind
  /// unschaedlich; [config] wird dabei trotzdem uebernommen.
  static void ensureInitialized({MapConfig? config}) {
    WidgetsFlutterBinding.ensureInitialized();

    if (config != null) {
      MapConfig.defaults = config;
    }

    if (_initialized) return;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    _initialized = true;
  }
}
