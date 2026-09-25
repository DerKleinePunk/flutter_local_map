import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Async Race Prevention Pattern', () {
    test('Token-based deduplication prevents stale async results', () async {
      // Simulation of the token pattern used in _initializeTileProvider
      int currentToken = 0;
      int? appliedResult;

      // Simulate first initialization request
      int token1 = ++currentToken;
      Future.delayed(const Duration(milliseconds: 10), () {
        // Simulate async work completing
        if (currentToken == token1) {
          appliedResult = token1;
        }
      });

      // Simulate second (newer) initialization request before first completes
      await Future.delayed(const Duration(milliseconds: 5));
      int token2 = ++currentToken;

      Future.delayed(const Duration(milliseconds: 5), () {
        // Second request completes
        if (currentToken == token2) {
          appliedResult = token2;
        }
      });

      // Wait for all async operations
      await Future.delayed(const Duration(milliseconds: 30));

      // Only the latest token should have been applied
      expect(appliedResult, equals(token2));
      expect(appliedResult, isNotNull);
    });

    test('Token correctly identifies stale requests', () {
      int initializationToken = 0;

      // Start first request
      initializationToken++;
      final firstToken = initializationToken;

      // Start another request (invalidates first)
      initializationToken++;
      final secondToken = initializationToken;

      // First request's token is now stale
      expect(firstToken, isNot(equals(initializationToken)));
      expect(secondToken, equals(initializationToken));
    });
  });
}
