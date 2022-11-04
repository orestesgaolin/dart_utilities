import 'package:changelog_cli/src/model/changelog_entry.dart';
import 'package:collection/collection.dart';

class SimplePrinter {
  SimplePrinter(this.types);

  final List<String> types;

  String print(List<ChangelogEntry> entries) {
    final groupedBy = entries.groupListsBy((e) => e.type);
    final buffer = StringBuffer();
    for (final type in types) {
      final group = groupedBy[type];
      if (group != null) {
        buffer.writeln('## $type');
        for (final entry in group) {
          buffer.writeln('- ${entry.message}');
        }
      }
    }
    return buffer.toString();
  }
}
