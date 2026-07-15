import 'dart:typed_data';

enum PayloadTypeEnum {
  PCMU(0),
  RESERVED1(1),
  RESERVED2(2),
  GSM(3),
  G723(4),
  DVI4_1(5),
  DVI4_2(6),
  LPC(7),
  PCMA(8),
  G722(9),
  L16_1(10),
  L16_2(11),
  QCELP(12),
  CN(13),
  MPA(14),
  G728(15),
  DVI4_3(16),
  DVI4_4(17),
  G729(18),
  RESERVED19(19),
  UNASSIGNED20(20),
  UNASSIGNED21(21),
  UNASSIGNED22(22),
  UNASSIGNED23(23),
  UNASSIGNED24(24),
  CELB(25),
  JPEG(26),
  UNASSIGNED27(27),
  NV(28),
  UNASSIGNED29(29),
  UNASSIGNED30(30),
  H261(31),
  MPV(32),
  MP2T(33),
  H263(34),
  MPEG_PS(96);

  const PayloadTypeEnum(this.value);
  final value;
}

class RTPpacket {
  //size of the RTP header:
  static int HEADER_SIZE = 12;

  //Fields that compose the RTP header
  int Version = 2;
  int Padding = 0;
  int Extension = 0;
  int CC = 0;
  int Marker = 0;
  int PayloadType;
  int SequenceNumber;
  int TimeStamp;
  int Ssrc = 0;

  //Bitstream of the RTP header
  Uint8List header = Uint8List(HEADER_SIZE);

  //size of the RTP payload
  int payload_size;
  //Bitstream of the RTP payload
  Uint8List payload;

  //--------------------------
  //Constructor of an RTPpacket object from header fields and payload bitstream
  //--------------------------
  RTPpacket(int PType, int Framenb, int Time, Uint8List pload, int data_length)
      : PayloadType = PType,
        SequenceNumber = Framenb,
        TimeStamp = Time,
        payload = pload,
        payload_size = data_length {
    //fill by default header fields:
    //Version = 2;
    //Padding = 0;
    //Extension = 0;
    //CC = 0;
    //Marker = 0;
    //Ssrc = 0;

    //fill changing header fields:
    //SequenceNumber = Framenb;
    //TimeStamp = Time;
    //PayloadType = PType;

    //build the header bistream:
    //--------------------------
    //header = Uint8List(HEADER_SIZE);

    //.............
    //TO COMPLETE
    //.............
    //fill the header array of byte with RTP header fields

    //header[0] = ...
    // .....

    //fill the payload bitstream:
    //--------------------------
    //payload_size = data_length;
    payload = pload;

    //fill payload array of byte from data (given in parameter of the constructor)
    //......

    // ! Do not forget to uncomment method printheader() below !
  }

  //--------------------------
  //Constructor of an RTPpacket object from the packet bistream
  //--------------------------
  //
  // Full RFC 3550 §5.1 header layout (12 fixed bytes + optional CSRC list
  // + optional extension header, and optional trailing padding on the
  // payload):
  //
  //   0                   1                   2                   3
  //   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  //  |V=2|P|X|  CC   |M|     PT      |       sequence number         |
  //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  //  |                           timestamp                           |
  //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  //  |           synchronization source (SSRC) identifier            |
  //  +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
  //  |            contributing source (CSRC) identifiers             |
  //  |                             ....                              |
  //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  //
  // If X=1, a 4-byte extension header (`defined-by-profile:u16 |
  // length:u16` where length is in 32-bit words) plus `length*4` bytes
  // of extension body follow the CSRC list.
  //
  // If P=1, the LAST byte of the packet is the padding octet count
  // (including itself); those bytes are trailing garbage on the
  // payload and must be stripped before hand-off to the codec.
  //
  // The previous implementation ignored P/X/CC entirely, so any packet
  // from a softphone using the RFC 6464 audio-level extension, or from
  // a mixer inserting CSRCs, would silently prepend or append header
  // bytes to the audio payload — audible as clicks or static.
  factory RTPpacket.fromList(Uint8List packet, int packet_size) {
    if (packet_size < HEADER_SIZE + 1) {
      // RFC 3550: 12-byte header + at least 1 payload byte.
      throw FormatException(
        'RTP packet too short: expected at least ${HEADER_SIZE + 1} bytes, '
        'got $packet_size',
      );
    }
    // Guard against callers passing packet_size > buffer length.
    if (packet_size > packet.lengthInBytes) {
      throw FormatException(
        'RTP packet_size ($packet_size) exceeds buffer length '
        '(${packet.lengthInBytes})',
      );
    }

    final int version = (packet[0] >> 6) & 0x03;
    if (version != 2) {
      throw FormatException(
        'Invalid RTP version: expected 2, got $version',
      );
    }
    final int padding = (packet[0] >> 5) & 0x01;
    final int extension = (packet[0] >> 4) & 0x01;
    final int cc = packet[0] & 0x0F;
    final int marker = (packet[1] >> 7) & 0x01;
    final int payloadType = packet[1] & 0x7F;

    final bd = ByteData.view(
        packet.buffer, packet.offsetInBytes, packet.lengthInBytes);
    final int sequenceNumber = bd.getUint16(2, Endian.big);
    final int timestamp = bd.getUint32(4, Endian.big);
    final int ssrc = bd.getUint32(8, Endian.big);

    // Payload starts after the fixed header + 4*CC CSRC bytes + optional
    // extension header.
    int payloadStart = HEADER_SIZE + 4 * cc;
    if (payloadStart > packet_size) {
      throw FormatException(
        'RTP packet truncated in CSRC list (need $payloadStart bytes, '
        'have $packet_size)',
      );
    }
    if (extension == 1) {
      if (payloadStart + 4 > packet_size) {
        throw FormatException('RTP packet truncated in extension header');
      }
      final int extLenWords = bd.getUint16(payloadStart + 2, Endian.big);
      payloadStart += 4 + 4 * extLenWords;
      if (payloadStart > packet_size) {
        throw FormatException(
          'RTP packet truncated in extension body (need $payloadStart '
          'bytes, have $packet_size)',
        );
      }
    }

    int payloadEnd = packet_size;
    if (padding == 1) {
      final int padCount = packet[packet_size - 1];
      if (padCount < 1 || payloadStart + padCount > packet_size) {
        throw FormatException(
          'RTP padding octet count invalid: $padCount '
          '(payloadStart=$payloadStart, packet_size=$packet_size)',
        );
      }
      payloadEnd -= padCount;
    }

    final int payloadSize = payloadEnd - payloadStart;
    if (payloadSize < 0) {
      throw FormatException('RTP payload size negative after header parsing');
    }
    final Uint8List payload = Uint8List.sublistView(
      packet,
      payloadStart,
      payloadEnd,
    );

    final rtp =
        RTPpacket(payloadType, sequenceNumber, timestamp, payload, payloadSize);
    rtp.Version = version;
    rtp.Padding = padding;
    rtp.Extension = extension;
    rtp.CC = cc;
    rtp.Marker = marker;
    rtp.Ssrc = ssrc;
    return rtp;
  }

  //--------------------------
  //getpayload: return the payload bistream of the RTPpacket and its size
  //--------------------------
  int getpayload(Uint8List data) {
    for (int i = 0; i < payload_size; i++) data[i] = payload[i];

    return (payload_size);
  }

  //--------------------------
  //getpayload_length: return the length of the payload
  //--------------------------
  int getpayload_length() {
    return (payload_size);
  }

  //--------------------------
  //getlength: return the total length of the RTP packet
  //--------------------------
  int getlength() {
    return (payload_size + HEADER_SIZE);
  }

  //--------------------------
  //getpacket: returns the packet bitstream and its length
  //--------------------------
  int getpacket(Uint8List packet) {
    //construct the packet = header + payload
    for (int i = 0; i < HEADER_SIZE; i++) packet[i] = header[i];
    for (int i = 0; i < payload_size; i++) packet[i + HEADER_SIZE] = payload[i];

    //return total size of the packet
    return (payload_size + HEADER_SIZE);
  }

  //--------------------------
  //gettimestamp
  //--------------------------

  int gettimestamp() {
    return (TimeStamp);
  }

  //--------------------------
  //getsequencenumber
  //--------------------------
  int getsequencenumber() {
    return (SequenceNumber);
  }

  //--------------------------
  //getpayloadtype
  //--------------------------
  int getpayloadtype() {
    return (PayloadType);
  }

  //--------------------------
  //print headers without the SSRC
  //--------------------------
  void printheader() {
    //TO DO: uncomment
    /*
    for (int i=0; i < (HEADER_SIZE-4); i++)
      {
	for (int j = 7; j>=0 ; j--)
	  if (((1<<j) & header[i] ) != 0)
	    System.out.print("1");
	else
	  System.out.print("0");
	System.out.print(" ");
      }

    System.out.println();
    */
  }

  //return the unsigned value of 8-bit integer nb
  static int unsigned_int(int nb) {
    if (nb >= 0)
      return (nb);
    else
      return (256 + nb);
  }

  @override
  String toString() {
    // TODO: implement toString
    return ("{vesrion : ${Version},padding: $Padding}: payload type:$PayloadType, Payload Size: ${payload.lengthInBytes}, Sequence Number: $SequenceNumber");
  }
}
