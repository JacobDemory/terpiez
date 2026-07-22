import 'package:flutter_test/flutter_test.dart';
import 'package:terpiez/main.dart';

void main() {
  test('remote location parses supported map fields', () {
    final location = RemoteTerpiezLocation.tryParse({
      'latitude': 38.9869,
      'longitude': -76.9426,
      'species_id': 'test-terpiez',
    });

    expect(location, isNotNull);
    expect(location!.speciesId, 'test-terpiez');
    expect(location.location.latitude, 38.9869);
    expect(location.location.longitude, -76.9426);
  });

  test('catch records round-trip through JSON', () {
    final record = CatchRecord(
      latitude: 38.9869,
      longitude: -76.9426,
      caughtAtIso: '2026-07-22T12:00:00.000Z',
    );

    final restored = CatchRecord.fromJson(record.toJson());

    expect(restored.latitude, record.latitude);
    expect(restored.longitude, record.longitude);
    expect(restored.caughtAtIso, record.caughtAtIso);
  });
}
