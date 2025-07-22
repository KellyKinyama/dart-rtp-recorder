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
  factory RTPpacket.fromList(Uint8List packet, int packet_size) {
    //fill default fields:
    int Version = 2;
    int Padding = 0;
    int Extension = 0;
    int CC = 0;
    int Marker = 0;
    int Ssrc = 0;
    int PayloadType = 0;
    int SequenceNumber = 0;
    int TimeStamp = 0;
    int payload_size = packet_size - HEADER_SIZE;
    Uint8List payload = Uint8List(payload_size);

    if (packet.lengthInBytes < 13) {
      // As per RFC 3550 - the header is 12 bytes, there must be data - anything less is a bad packet.
      throw ("Packet too short, expecting at least 13 bytes, but found ${packet.lengthInBytes}");
    }
    if ((packet[0] & 0xC0) != Version << 6) {
      // This is not a valid version number.
      throw ("Invalid version number found, expecting $Version");
    }

    //check if total packet size is lower than the header size
    if (packet_size >= HEADER_SIZE) {
      //get the header bitsream:
      Uint8List header = Uint8List(HEADER_SIZE);
      for (int i = 0; i < HEADER_SIZE; i++) {
        header[i] = packet[i];
      }

      //get the payload bitstream:
      payload_size = packet_size - HEADER_SIZE;
      payload = Uint8List(payload_size);
      for (int i = HEADER_SIZE; i < packet_size; i++) {
        payload[i - HEADER_SIZE] = packet[i];
      }

      //interpret the changing fields of the header:
      PayloadType = header[1] & 127;
      SequenceNumber = unsigned_int(header[3]) + 256 * unsigned_int(header[2]);
      TimeStamp = unsigned_int(header[7]) +
          256 * unsigned_int(header[6]) +
          65536 * unsigned_int(header[5]) +
          16777216 * unsigned_int(header[4]);
    }

    return RTPpacket(
        PayloadType, SequenceNumber, TimeStamp, payload, packet_size);
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
