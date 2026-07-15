import 'dart:typed_data';

import 'package:dart_rtp_recorder/src/rtp/rtp_packet.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build an RTP packet with the given header flags and payload.
///
/// * [padCount]: if > 0, the packet gets P=1 and `padCount` bytes of
///   trailing padding (the last byte is `padCount` itself, RFC 3550 §5.1).
/// * [csrcs]: 32-bit CSRC identifiers. CC field is set from length.
/// * [extension]: bytes of extension body (must be a multiple of 4).
///   The extension header (defined-by-profile:u16 + length:u16) is
///   prepended automatically.
Uint8List _buildRtp({
  required int pt,
  required Uint8List payload,
  int seq = 0x1234,
  int ts = 0xDEADBEEF,
  int ssrc = 0xCAFEBABE,
  int marker = 0,
  int padCount = 0,
  List<int> csrcs = const [],
  Uint8List? extension,
  int extensionProfile = 0xBEDE,
}) {
  if (extension != null && extension.length % 4 != 0) {
    throw ArgumentError('extension length must be a multiple of 4');
  }
  final cc = csrcs.length;
  final hasExt = extension != null;
  final extBytes = hasExt ? 4 + extension.length : 0;
  final total = 12 + 4 * cc + extBytes + payload.length + padCount;
  final out = Uint8List(total);
  final bd = ByteData.view(out.buffer);

  final v = 2;
  final p = padCount > 0 ? 1 : 0;
  final x = hasExt ? 1 : 0;
  out[0] = (v << 6) | (p << 5) | (x << 4) | (cc & 0x0F);
  out[1] = ((marker & 0x01) << 7) | (pt & 0x7F);
  bd.setUint16(2, seq, Endian.big);
  bd.setUint32(4, ts, Endian.big);
  bd.setUint32(8, ssrc, Endian.big);

  var off = 12;
  for (final c in csrcs) {
    bd.setUint32(off, c, Endian.big);
    off += 4;
  }
  if (hasExt) {
    bd.setUint16(off, extensionProfile, Endian.big);
    bd.setUint16(off + 2, extension.length ~/ 4, Endian.big);
    off += 4;
    out.setRange(off, off + extension.length, extension);
    off += extension.length;
  }
  out.setRange(off, off + payload.length, payload);
  off += payload.length;
  if (padCount > 0) {
    // RFC 3550: last byte = pad count (including itself). Middle bytes
    // are arbitrary — we write 0xAA to prove they're stripped.
    for (var i = 0; i < padCount - 1; i++) {
      out[off + i] = 0xAA;
    }
    out[off + padCount - 1] = padCount;
  }
  return out;
}

Uint8List _payload(int n, {int seed = 1}) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = (seed + i * 7) & 0xFF;
  }
  return b;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RTPpacket.fromList happy path', () {
    test('parses a plain PT=8 packet with no options', () {
      final pl = _payload(160, seed: 3);
      final pkt = _buildRtp(pt: 8, payload: pl);
      final rtp = RTPpacket.fromList(pkt, pkt.length);
      expect(rtp.PayloadType, 8);
      expect(rtp.SequenceNumber, 0x1234);
      expect(rtp.TimeStamp, 0xDEADBEEF);
      expect(rtp.Ssrc, 0xCAFEBABE);
      expect(rtp.Padding, 0);
      expect(rtp.Extension, 0);
      expect(rtp.CC, 0);
      expect(rtp.payload, pl);
    });

    test('reads the marker bit (M=1)', () {
      final pkt = _buildRtp(pt: 0, payload: _payload(160), marker: 1);
      final rtp = RTPpacket.fromList(pkt, pkt.length);
      expect(rtp.Marker, 1);
      expect(rtp.PayloadType, 0);
    });
  });

  group('RTPpacket.fromList option handling', () {
    test('strips a trailing 4-byte padding block (P=1)', () {
      final pl = _payload(160, seed: 9);
      final pkt = _buildRtp(pt: 8, payload: pl, padCount: 4);
      final rtp = RTPpacket.fromList(pkt, pkt.length);
      expect(rtp.Padding, 1);
      expect(rtp.payload, pl,
          reason: 'payload must NOT include the 4 trailing padding bytes');
    });

    test('skips a 4-byte CSRC list (CC=1)', () {
      final pl = _payload(160, seed: 11);
      final pkt = _buildRtp(pt: 8, payload: pl, csrcs: [0x11223344]);
      final rtp = RTPpacket.fromList(pkt, pkt.length);
      expect(rtp.CC, 1);
      expect(rtp.payload, pl,
          reason: 'payload must NOT include the 4 CSRC bytes');
    });

    test('skips an RFC 6464 audio-level extension header (X=1)', () {
      // 4-byte extension body (one 32-bit word).
      final ext = Uint8List.fromList([0x10, 0x20, 0x30, 0x40]);
      final pl = _payload(160, seed: 13);
      final pkt = _buildRtp(pt: 8, payload: pl, extension: ext);
      final rtp = RTPpacket.fromList(pkt, pkt.length);
      expect(rtp.Extension, 1);
      expect(rtp.payload, pl,
          reason: 'payload must NOT include the 8 extension-header bytes');
    });

    test('handles P=1 + X=1 + CC>0 simultaneously', () {
      final pl = _payload(160, seed: 17);
      final ext = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]); // 2 words
      final pkt = _buildRtp(
        pt: 8,
        payload: pl,
        csrcs: [0xAAAAAAAA, 0xBBBBBBBB],
        extension: ext,
        padCount: 8,
        marker: 1,
      );
      final rtp = RTPpacket.fromList(pkt, pkt.length);
      expect(rtp.Padding, 1);
      expect(rtp.Extension, 1);
      expect(rtp.CC, 2);
      expect(rtp.Marker, 1);
      expect(rtp.payload, pl);
    });
  });

  group('RTPpacket.fromList error handling', () {
    test('rejects packets shorter than header + 1 payload byte', () {
      final pkt = Uint8List(12); // valid version, but no payload.
      pkt[0] = 0x80;
      expect(() => RTPpacket.fromList(pkt, pkt.length),
          throwsA(isA<FormatException>()));
    });

    test('rejects packet_size larger than the buffer', () {
      final pkt = _buildRtp(pt: 8, payload: _payload(4));
      expect(() => RTPpacket.fromList(pkt, pkt.length + 100),
          throwsA(isA<FormatException>()));
    });

    test('rejects a non-2 RTP version', () {
      final pkt = _buildRtp(pt: 8, payload: _payload(160));
      pkt[0] = (1 << 6); // V=1
      expect(() => RTPpacket.fromList(pkt, pkt.length),
          throwsA(isA<FormatException>()));
    });

    test('rejects a CSRC count that overruns the buffer', () {
      final pl = _payload(4);
      final pkt = _buildRtp(pt: 8, payload: pl);
      // Force CC=15 (60 bytes of CSRC) without actually having them.
      pkt[0] = (pkt[0] & 0xF0) | 0x0F;
      expect(() => RTPpacket.fromList(pkt, pkt.length),
          throwsA(isA<FormatException>()));
    });

    test('rejects an extension length that overruns the buffer', () {
      final pl = _payload(4);
      final pkt = _buildRtp(pt: 8, payload: pl);
      // Force X=1 but with no extension body actually appended.
      pkt[0] = pkt[0] | 0x10;
      expect(() => RTPpacket.fromList(pkt, pkt.length),
          throwsA(isA<FormatException>()));
    });

    test('rejects an invalid padding octet count (0)', () {
      final pkt = _buildRtp(pt: 8, payload: _payload(160), padCount: 4);
      // Corrupt the trailing pad-count byte to 0.
      pkt[pkt.length - 1] = 0;
      expect(() => RTPpacket.fromList(pkt, pkt.length),
          throwsA(isA<FormatException>()));
    });

    test('rejects an invalid padding octet count (exceeds packet)', () {
      final pkt = _buildRtp(pt: 8, payload: _payload(4), padCount: 4);
      pkt[pkt.length - 1] = 250;
      expect(() => RTPpacket.fromList(pkt, pkt.length),
          throwsA(isA<FormatException>()));
    });
  });
}
