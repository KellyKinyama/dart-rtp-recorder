import 'dart:io';

import '../recorder/rtp_server.dart';

class HttpRtpServer {
  HttpRtpServer(String ip, int port) {
    HttpServer.bind(InternetAddress(ip), port).then((HttpServer server) {
      server.listen((HttpRequest request) {
        print("Request from ${request.uri.host}");
        // request.response.write("Hello world!");
        // request.response.close();
        var queryParams = request.uri.queryParameters;
        if (queryParams['filename'] != null) {
          rtp_server(ip, queryParams['filename']!, request);
        } else {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..close();
        }
      });
    });
  }
}
