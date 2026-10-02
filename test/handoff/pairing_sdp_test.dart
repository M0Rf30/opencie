// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/handoff/pairing.dart';

void main() {
  group('HandoffPairing.compactSdpForQr', () {
    const udp4 =
        'a=candidate:1 1 udp 2122129151 192.168.0.62 38867 typ host generation 0';
    const udp6 =
        'a=candidate:2 1 udp 2122197247 2a02::1 35199 typ host generation 0';
    const srflx =
        'a=candidate:3 1 udp 1685921535 151.68.6.162 38867 typ srflx raddr 192.168.0.62 rport 38867';
    const tcp4 =
        'a=candidate:4 1 tcp 1518149375 192.168.0.62 9 typ host tcptype active';
    const tcp6 =
        'a=candidate:5 1 tcp 1518217471 2a02::1 9 typ host tcptype active';

    String sdp(List<String> cands) => [
      'v=0',
      'm=application 9 UDP/DTLS/SCTP webrtc-datachannel',
      ...cands,
      'a=sctp-port:5000',
      '',
    ].join('\r\n');

    test('drops TCP candidates and keeps UDP ones', () {
      final out = HandoffPairing.compactSdpForQr(
        sdp([udp4, tcp4, udp6, tcp6, srflx]),
      );
      expect(out, sdp([udp4, udp6, srflx]));
    });

    test('keeps TCP candidates when there is no UDP candidate', () {
      final input = sdp([tcp4, tcp6]);
      expect(HandoffPairing.compactSdpForQr(input), input);
    });

    test('leaves an SDP without candidates untouched', () {
      final input = sdp([]);
      expect(HandoffPairing.compactSdpForQr(input), input);
    });
  });
}
