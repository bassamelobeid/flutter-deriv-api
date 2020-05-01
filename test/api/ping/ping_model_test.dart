import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_deriv_api/api/ping/ping.dart';

import 'ping_model_mock_data.dart';

void main() {
  test('ping json parsing', () {
    final Map<String, dynamic> mapData = jsonDecode(pingModelMockData);
    final Ping ping = Ping.fromJson(mapData);

    expect(ping.ping, 'pong');
  });
}
