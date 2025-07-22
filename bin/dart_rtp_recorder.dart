import 'package:dart_rtp_recorder/dart_rtp_recorder.dart';
import 'package:dart_rtp_recorder/src/config.dart';

import 'package:dotenv/dotenv.dart';

void main(List<String> arguments) {
  var env = DotEnv(includePlatformEnvironment: true)..load();
  String ip = env['HTTP_SERVER_ADDRESS']!;
  int port = int.parse(env['HTTP_SERVER_PORT']!);
  audioPath = env['AUDIO_PATH']!;

  //initialise recorde daatabase values
  Config.asteriskDbHost = env['AST_DB_HOST']!;
  Config.asteriskDbPort = env['AST_DB_PORT']!;
  Config.asteriskDbName = env['AST_DB_DATABASE']!;
  Config.asteriskDbUsername = env['AST_DB_USERNAME']!;
  Config.asteriskDbPassword = env['AST_DB_PASSWORD']!;

  //print('Hello world: ${dart_rtp_recorder.calculate()}!');
  HttpRtpServer(ip, port);
  print("listening on $ip:$port");
}
