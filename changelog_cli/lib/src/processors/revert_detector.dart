import 'package:changelog_cli/src/model/model.dart';
import 'package:mason_logger/mason_logger.dart';

class RevertDetector {
  /// Detects reverted commits in the changelog entries and marks them appropriately
  static List<ChangelogEntry> detectReverts(
    List<ChangelogEntry> entries, {
    Logger? logger,
  }) {
    final result = <ChangelogEntry>[];
    final commitRefToEntry = <String, ChangelogEntry>{};

    // Build a map of commit refs to entries for quick lookup
    for (final entry in entries) {
      commitRefToEntry[entry.ref] = entry;
    }

    logger?.detail('Detecting reverted commits in ${entries.length} entries');

    for (final entry in entries) {
      final revertInfo = parseRevertCommit(entry.commit.message);

      if (revertInfo != null) {
        // This is a revert commit
        logger?.detail('Found revert commit ${entry.ref}: ${revertInfo.revertedCommitRef}');

        // Find the original commit that was reverted
        final revertedEntry = commitRefToEntry[revertInfo.revertedCommitRef];
        if (revertedEntry != null) {
          // Mark the original commit as reverted
          final updatedRevertedEntry = revertedEntry.copyWith(
            isReverted: true,
            revertedByRef: entry.ref,
          );
          commitRefToEntry[revertedEntry.ref] = updatedRevertedEntry;
          logger?.detail('Marked commit ${revertedEntry.ref} as reverted by ${entry.ref}');
        } else {
          logger?.detail('Could not find original commit ${revertInfo.revertedCommitRef} to mark as reverted');
        }

        // Skip revert commits - they shouldn't appear in the changelog
        logger?.detail('Skipping revert commit ${entry.ref} from changelog');
      } else {
        // Regular commit, add the potentially updated version from our map
        final updatedEntry = commitRefToEntry[entry.ref] ?? entry;
        result.add(updatedEntry);
      }
    }

    final revertedCount = result.where((e) => e.isReverted).length;
    logger?.detail('Found $revertedCount reverted commits');

    return result;
  }

  /// Parses a commit message to extract revert information
  static RevertInfo? parseRevertCommit(String commitMessage) {
    // Common revert message patterns
    final revertPatterns = [
      // Git's default revert format: "Revert "commit title""
      RegExp(r'^Revert\s+".*"\s*\n\nThis reverts commit\s+([a-f0-9]{7,40})\.?', caseSensitive: false, multiLine: true),

      // Alternative format: "Revert commit abc1234"
      RegExp(r'^Revert\s+commit\s+([a-f0-9]{7,40})', caseSensitive: false, multiLine: true),

      // GitHub style: "Revert #PR-number" or similar patterns
      RegExp(r'^Revert\s+".*"\s*.*commit\s+([a-f0-9]{7,40})', caseSensitive: false, multiLine: true, dotAll: true),

      // Manual revert with "This reverts commit" somewhere in message
      RegExp(r'This reverts commit\s+([a-f0-9]{7,40})\.?', caseSensitive: false, multiLine: true),
    ];

    for (final pattern in revertPatterns) {
      final match = pattern.firstMatch(commitMessage);
      if (match != null) {
        final revertedCommitRef = match.group(1);
        if (revertedCommitRef != null) {
          return RevertInfo(revertedCommitRef: revertedCommitRef);
        }
      }
    }

    return null;
  }
}

/// Information about a revert commit
class RevertInfo {
  const RevertInfo({
    required this.revertedCommitRef,
  });

  final String revertedCommitRef;
}
