import 'package:test/test.dart';

// The original placeholder test referenced a `calculate()` function that was
// never defined in `package:dart_rtp_recorder`. It is skipped so the rest of
// the suite (e.g. `pcm_wav_sink_test.dart`) runs cleanly. Delete once a real
// end-to-end test replaces it.
void main() {
  test('placeholder (pre-existing, no real assertion)', () {}, skip: true);
}
