import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rtp_recorder/src/db_queries.dart';

import '../codecs/g711/dart_g711.dart';
import '../rtp/rtp_packet.dart';
import '../wave/wave.dart';

String audioPath = '';

Timer setTimeout(callback, [int duration = 30]) {
  return Timer(Duration(seconds: duration), callback);
}

void clearTimeout(Timer t) {
  t.cancel();
}

enum RTP_STATE { INITIALISED, RTP_RECEIVED, RTP_FINISHED }

class RtpState {
  RTP_STATE state = RTP_STATE.INITIALISED;
  int rtpSampleSize = 0;
}

void rtp_server(String ip, String filename, HttpRequest request) {
  RawDatagramSocket.bind(InternetAddress(ip), 0)
      .then((RawDatagramSocket socket) {
    print('UDP Echo ready to receive');
    print('${socket.address.address}:${socket.port}');

    //Return the listening port
    request.response
        .write('{"file_name":"$filename","rtp_port":${socket.port}}');
    request.response.close();

    List<Uint8List> buffer = [];

    RtpState state = RtpState();

    callback() {
      //if (counter == 0) {
      List<int> record = [];
      if (buffer.isEmpty) {
        return;
      } else {
        print("RTP server state: ${state.state}");
        if (state.state == RTP_STATE.RTP_FINISHED &&
            state.rtpSampleSize == buffer.length) {
          print("RTP server state changed to ${state.state}");
          for (var element in buffer) {
            for (int x = 0; x < element.lengthInBytes; x++) {
              record.add(element[x]);
            }
          }

          var buf = Uint8List.fromList(record);

          print("Writing to file");
          final pcmWave = Pcmtowave.pcmToWav(buf, 8000, 1);

          final f = File("$audioPath/$filename.wav");

          f.writeAsBytesSync(pcmWave);
          DbQueries.insertFileName(filename);

          //counter--;
          //if (counter == 0) {
          print('Cancel timer');
          //timer.cancel(); // Stops the repeating timer
          socket.close();
          buffer = [];
          record = [];
        }
        if (state.state == RTP_STATE.RTP_RECEIVED &&
            state.rtpSampleSize == buffer.length) {
          state.state = RTP_STATE.RTP_FINISHED;
          state.rtpSampleSize = buffer.length;
          print("RTP server state changed to ${state.state}");
        }
        if (state.state == RTP_STATE.RTP_RECEIVED &&
            state.rtpSampleSize != buffer.length) {
          state.state = RTP_STATE.RTP_RECEIVED;
          state.rtpSampleSize = buffer.length;
          print("RTP server state changed to ${state.state}");
        }
        if (state.state == RTP_STATE.INITIALISED) {
          state.state = RTP_STATE.RTP_RECEIVED;
          state.rtpSampleSize = buffer.length;
          print("RTP server state changed to ${state.state}");
        }
      }

      //}
      //}
    }

    final codec = DartG711Codec.g711a();

    //Timer t = setTimeout(callback, 30);

    const oneSec = Duration(seconds: 30);
    Timer.periodic(oneSec, (Timer t) {
      callback();
    });

    socket.listen((RawSocketEvent e) {
      Datagram? d = socket.receive();
      if (d != null) {
        //var data = String.fromCharCode(d.data);
        //print('Datagram from ${d.address.address}:${d.port}');
        RTPpacket rtPpacket = RTPpacket.fromList(d.data, d.data.lengthInBytes);

        var sample = codec.decode(rtPpacket.payload);
        buffer.add(sample);
        //counter = 1;

        //if (timerFlag) {
        //clearTimeout(t);
        //timerFlag = false;
        // }
      } else {
        //counter = 0;
        //if (!timerFlag) {
        //t = setTimeout(callback, 30);
        // timerFlag = true;
        //}
      }
      //t = setTimeout(callback, 30);
    });
  });

  //wsSipServer ws = wsSipServer("10.100.54.52", 8080);
}
