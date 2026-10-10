import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/foreground_service_lease.dart';

class _FakeService {
  int starts = 0;
  int stops = 0;
  bool startResult = true;
  Object? startError;
  Completer<bool>? pendingStart;

  Future<bool> start() {
    starts++;
    final error = startError;
    if (error != null) return Future.error(error);
    return pendingStart?.future ?? Future.value(startResult);
  }

  Future<void> stop() async => stops++;

  ForegroundServiceLease lease() =>
      ForegroundServiceLease(start: start, stop: stop);
}

void main() {
  test('starts once and stops after the last owner releases', () async {
    final service = _FakeService();
    final lease = service.lease();

    expect(await lease.acquire('download'), isTrue);
    expect(await lease.acquire('lanShare'), isTrue);
    expect(service.starts, 1);

    await lease.release('download');
    expect(service.stops, 0);
    expect(lease.isRunning, isTrue);

    await lease.release('lanShare');
    expect(service.stops, 1);
    expect(lease.isRunning, isFalse);
  });

  test('releasing an owner that never acquired does nothing', () async {
    final service = _FakeService();
    final lease = service.lease();
    await lease.acquire('download');

    await lease.release('lanShare');

    expect(service.stops, 0);
    expect(lease.holds('download'), isTrue);
  });

  test('a failed start drops the owner so a later acquire retries', () async {
    final service = _FakeService()..startResult = false;
    final lease = service.lease();

    expect(await lease.acquire('download'), isFalse);
    expect(lease.holds('download'), isFalse);

    service.startResult = true;
    expect(await lease.acquire('download'), isTrue);
    expect(service.starts, 2);
  });

  test('a throwing start drops the owner so a later acquire retries', () async {
    final service = _FakeService()..startError = StateError('start failed');
    final lease = service.lease();

    await expectLater(lease.acquire('download'), throwsA(isA<StateError>()));
    expect(lease.holds('download'), isFalse);
    expect(lease.isRunning, isFalse);

    service.startError = null;
    expect(await lease.acquire('download'), isTrue);
    expect(service.starts, 2);
    expect(lease.isRunning, isTrue);
  });

  test('concurrent acquires share one platform start', () async {
    final service = _FakeService()..pendingStart = Completer<bool>();
    final lease = service.lease();

    final first = lease.acquire('download');
    final second = lease.acquire('lanShare');
    service.pendingStart!.complete(true);

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(service.starts, 1);
  });

  test('releasing during a pending start stops the service once up', () async {
    final service = _FakeService()..pendingStart = Completer<bool>();
    final lease = service.lease();

    final acquired = lease.acquire('lanShare');
    await lease.release('lanShare');
    service.pendingStart!.complete(true);

    expect(await acquired, isFalse);
    expect(service.stops, 1);
    expect(lease.isRunning, isFalse);
  });
}
