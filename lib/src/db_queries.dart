import 'package:dart_rtp_recorder/src/config.dart';
import 'package:eloquent/eloquent.dart';

// Declarations

class DbQueries {
  static Future<Connection> getDbConnection() async {
    var manager = Manager();
    if (true) {
      manager.addConnection({
        'driver': 'mysql',
        'host': Config.asteriskDbHost,
        'port': Config.asteriskDbPort,
        'database': Config.asteriskDbName,
        'username': Config.asteriskDbUsername,
        'password': Config.asteriskDbPassword,
      });
      manager.setAsGlobal();
    }
    final db = await manager.connection();
    return db;
  }

  static Future<void> insertFileName(String filename) async {
    final db = await getDbConnection();

    try {
      await db.table('recordings').insert({'filename': filename});
    } catch (e) {
      print('Error: $e');
      // Handle reconnection logic if needed
    } finally {
      await db.disconnect();
    }
  }

  /// Persist a completed recording along with its codec/container metadata.
  ///
  /// Requires the `recordings` table to carry the columns below (in
  /// addition to `filename`). If they are missing this method falls back to
  /// a filename-only insert so an older DB schema keeps working:
  ///
  /// ```sql
  /// ALTER TABLE recordings
  ///   ADD COLUMN codec        VARCHAR(16) NULL,
  ///   ADD COLUMN container    VARCHAR(16) NULL,
  ///   ADD COLUMN sample_rate  INT         NULL,
  ///   ADD COLUMN duration_ms  BIGINT      NULL,
  ///   ADD COLUMN bytes        BIGINT      NULL;
  /// ```
  static Future<void> insertRecording({
    required String filename,
    required String codec,
    required String container,
    required int sampleRate,
    required int durationMs,
    required int bytes,
  }) async {
    final db = await getDbConnection();
    try {
      try {
        await db.table('recordings').insert({
          'filename': filename,
          'codec': codec,
          'container': container,
          'sample_rate': sampleRate,
          'duration_ms': durationMs,
          'bytes': bytes,
        });
      } catch (e) {
        print('insertRecording: extended insert failed ($e); '
            'falling back to filename-only insert');
        await db.table('recordings').insert({'filename': filename});
      }
    } catch (e) {
      print('insertRecording: DB write failed for $filename: $e');
    } finally {
      await db.disconnect();
    }
  }
}
