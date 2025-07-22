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
}
