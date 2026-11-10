import 'dart:async';
import 'package:duanju_app/subscription_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shares concurrent parsing only, preserving retries and request scope',
    () async {
      final pending = PendingSourceRequests();
      final completion = Completer<Map<String, dynamic>>();
      var calls = 0;
      Future<Map<String, dynamic>> load() {
        calls++;
        return completion.future;
      }

      final first = pending.run('profile:epoch:digest:episode:720', load);
      final second = pending.run('profile:epoch:digest:episode:720', load);
      final other = pending.run('profile:newEpoch:digest:episode:720', load);
      expect(calls, 2);
      completion.complete({'url': 'https://example.test/video'});
      await Future.wait([first, second, other]);
      await pending.run('profile:epoch:digest:episode:720', load);
      expect(calls, 3);
      var failures = 0;
      Future<Map<String, dynamic>> fail() async {
        failures++;
        throw StateError('unavailable');
      }

      await expectLater(pending.run('failed', fail), throwsStateError);
      await expectLater(pending.run('failed', fail), throwsStateError);
      expect(failures, 2);
    },
  );
}
