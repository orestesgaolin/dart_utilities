import '../models.dart';

/// A request the TUI hands back to the CLI when it shuts down, so the action
/// can run with full control of the terminal (e.g. `git mergetool`).
class SyncRequest {
  SyncRequest({
    required this.repo,
    required this.chain,
    required this.strategy,
  });

  final Repo repo;
  final Chain chain;
  final SyncStrategy strategy;
}

/// Shared mutable holder passed into the TUI. The CLI inspects it after
/// `runApp` returns to decide what to do next.
class AppIntent {
  /// Set when the user asked to sync a chain; null means the user just quit.
  SyncRequest? syncRequest;
}
