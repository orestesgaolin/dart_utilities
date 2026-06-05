import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../git/git_repo.dart';
import '../models.dart';

/// Interactive TUI to review local branches and batch-delete or push them.
class GitBranchesApp extends StatefulComponent {
  const GitBranchesApp({
    required this.git,
    required this.repoName,
    super.key,
  });

  final GitRepo git;
  final String repoName;

  @override
  State<GitBranchesApp> createState() => _GitBranchesAppState();
}

class _GitBranchesAppState extends State<GitBranchesApp> {
  final _scrollController = ScrollController();

  List<BranchInfo> _all = [];
  final _marks = <String, MarkState>{};
  SortOrder _sort = SortOrder.activityAsc;
  BranchFilter _filter = BranchFilter.all;
  int _selected = 0;
  bool _loading = true;
  bool _busy = false;
  bool _showHelp = false;

  String? _status;
  Timer? _statusTimer;

  // Confirmation overlay (supports multi-line prompts).
  String? _confirmPrompt;
  void Function()? _confirmAction;

  /// Branches with last activity older than this are flagged "stale".
  static const _staleAfter = Duration(days: 60);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _flash(String message) {
    _statusTimer?.cancel();
    setState(() => _status = message);
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _status = null);
    });
  }

  /// Bumped on every [_load] so a slow background squash pass from an earlier
  /// load can detect it's stale and bail out.
  int _loadGen = 0;

  void _apply(List<BranchInfo> branches) {
    _all = branches;
    _selected = _selected.clamp(0, _visible.isEmpty ? 0 : _visible.length - 1);
    final names = branches.map((b) => b.name).toSet();
    _marks.removeWhere((k, _) => !names.contains(k));
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() => _loading = true);

    // Fast first paint using reachability only…
    final quick = await component.git.branches(detectSquashMerges: false);
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _apply(quick);
      _loading = false;
      _status = 'Checking for squash-merged branches…';
    });

    // …then fill in squash/rebase merges (cached, so reloads are fast).
    final full = await component.git.branches(detectSquashMerges: true);
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _apply(full);
      _status = null;
    });
  }

  // ---- Derived data ---------------------------------------------------------

  List<BranchInfo> get _visible {
    final list = _all.where((b) {
      return switch (_filter) {
        BranchFilter.all => true,
        BranchFilter.merged => b.isEffectivelyMerged,
        BranchFilter.unmerged => !b.isEffectivelyMerged,
      };
    }).toList();
    list.sort((a, b) {
      // Keep the current/default branch pinned to the top regardless of sort.
      if (a.isProtected != b.isProtected) return a.isProtected ? -1 : 1;
      return switch (_sort) {
        SortOrder.activityAsc => a.lastActivity.compareTo(b.lastActivity),
        SortOrder.activityDesc => b.lastActivity.compareTo(a.lastActivity),
        SortOrder.name => a.name.compareTo(b.name),
      };
    });
    return list;
  }

  bool _isStale(BranchInfo b) =>
      !b.isEffectivelyMerged &&
      !b.isProtected &&
      DateTime.now().difference(b.lastActivity) > _staleAfter;

  /// Name of the default branch, for messages.
  String get _defaultBranchName {
    for (final b in _all) {
      if (b.isDefault) return b.name;
    }
    return 'the default branch';
  }

  bool get _hasMarks => _marks.values.any((m) => m != MarkState.none);

  int get _deleteCount =>
      _marks.values.where((m) => m == MarkState.delete).length;
  int get _pushCount => _marks.values.where((m) => m == MarkState.push).length;

  BranchInfo? get _highlighted {
    final v = _visible;
    if (v.isEmpty || _selected < 0 || _selected >= v.length) return null;
    return v[_selected];
  }

  // ---- Actions --------------------------------------------------------------

  void _cycleMark(BranchInfo b) {
    final current = _marks[b.name] ?? MarkState.none;
    var next = switch (current) {
      MarkState.none => MarkState.delete,
      MarkState.delete => MarkState.push,
      MarkState.push => MarkState.none,
    };
    // Don't let the current/default branch be marked for deletion.
    if (next == MarkState.delete && b.isProtected) next = MarkState.push;
    setState(() => _marks[b.name] = next);
  }

  void _quickDelete(BranchInfo b) {
    if (b.isProtected) {
      _flash('Cannot delete the current or default branch.');
      return;
    }
    final String prompt;
    if (b.isMerged) {
      prompt = 'Delete merged branch "${b.name}"? [y/n]';
    } else if (b.isSquashMerged) {
      prompt = 'Branch "${b.name}" is squash-merged into $_defaultBranchName\n'
          '(its changes are already there). Delete it? [y/n]';
    } else {
      prompt = 'Branch "${b.name}" is NOT merged into $_defaultBranchName.\n'
          'Force-delete it? [y/n]';
    }
    setState(() {
      _confirmPrompt = prompt;
      _confirmAction = () => unawaited(_runDeletes([b]));
    });
  }

  void _quickPush(BranchInfo b) {
    unawaited(_runPushes([b]));
  }

  void _applyMarks() {
    final deletes = _visibleOrAll
        .where((b) => _marks[b.name] == MarkState.delete)
        .toList();
    final pushes =
        _visibleOrAll.where((b) => _marks[b.name] == MarkState.push).toList();
    if (deletes.isEmpty && pushes.isEmpty) {
      _flash('No marks. Use Space to mark, or d / p for the highlighted branch.');
      return;
    }
    final lines = <String>['Apply marks:'];
    if (deletes.isNotEmpty) {
      lines.add('');
      lines.add('Delete (${deletes.length}):');
      for (final b in deletes) {
        final note = b.isMerged
            ? ''
            : b.isSquashMerged
                ? '  (squash-merged — force)'
                : '  (UNMERGED — force)';
        lines.add('  ✗ ${b.name}$note');
      }
    }
    if (pushes.isNotEmpty) {
      lines.add('');
      lines.add('Push (${pushes.length}):');
      for (final b in pushes) {
        lines.add('  ↑ ${b.name}${b.hasUpstream ? '' : '  (set upstream)'}');
      }
    }
    lines.add('');
    lines.add('Proceed? [y/n]');
    setState(() {
      _confirmPrompt = lines.join('\n');
      _confirmAction = () => unawaited(_runApply(deletes, pushes));
    });
  }

  // All branches (not just visible) so marks hidden by a filter still apply.
  List<BranchInfo> get _visibleOrAll => _all;

  Future<void> _runApply(
      List<BranchInfo> deletes, List<BranchInfo> pushes) async {
    setState(() {
      _busy = true;
      _status = 'Applying…';
    });
    var deleted = 0, pushed = 0, failed = 0;
    for (final b in pushes) {
      final res = await component.git
          .push(b.name, setUpstream: !b.hasUpstream);
      res.ok ? pushed++ : failed++;
    }
    for (final b in deletes) {
      if (b.isProtected) {
        failed++;
        continue;
      }
      final res = await component.git.deleteLocal(b.name, force: !b.isMerged);
      res.ok ? deleted++ : failed++;
    }
    _marks.clear();
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    _flash('Applied: $deleted deleted, $pushed pushed'
        '${failed > 0 ? ', $failed failed' : ''}.');
  }

  Future<void> _runDeletes(List<BranchInfo> branches) async {
    setState(() => _busy = true);
    var ok = 0, failed = 0;
    String? lastError;
    for (final b in branches) {
      final res = await component.git.deleteLocal(b.name, force: !b.isMerged);
      if (res.ok) {
        ok++;
      } else {
        failed++;
        lastError = res.firstError;
      }
    }
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    _flash(failed == 0
        ? '✓ Deleted $ok branch(es).'
        : '✗ $failed failed: ${lastError ?? ''}');
  }

  Future<void> _runPushes(List<BranchInfo> branches) async {
    setState(() {
      _busy = true;
      _status = 'Pushing ${branches.length == 1 ? branches.first.name : '${branches.length} branches'}…';
    });
    var ok = 0, failed = 0;
    String? lastError;
    for (final b in branches) {
      final res = await component.git.push(b.name, setUpstream: !b.hasUpstream);
      if (res.ok) {
        ok++;
      } else {
        failed++;
        lastError = res.firstError;
      }
    }
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    _flash(failed == 0
        ? '✓ Pushed $ok branch(es).'
        : '✗ $failed failed: ${lastError ?? ''}');
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          Divider(style: DividerStyle.single, color: Colors.gray),
          Expanded(child: _buildBody()),
          Divider(style: DividerStyle.single, color: Colors.gray),
          _buildFooter(),
        ],
      ),
    );
  }

  Component _buildHeader() {
    final merged = _all.where((b) => b.isEffectivelyMerged && !b.isProtected).length;
    final summary = StringBuffer('git_branches  ›  ${component.repoName}');
    summary.write('   ${_all.length} branches · $merged merged');
    if (_hasMarks) summary.write('   ✗$_deleteCount  ↑$_pushCount');
    summary.write('   [${_sort.label} · ${_filter.label}]');
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Text(summary.toString(),
          style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
          maxLines: 1),
    );
  }

  Component _buildBody() {
    if (_confirmPrompt != null) return _buildConfirm();
    if (_showHelp) return _buildHelp();
    if (_loading) {
      return Center(child: Text('Loading branches…', style: TextStyle(color: Colors.gray)));
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
          child: Text('No branches match the current filter.',
              style: TextStyle(color: Colors.gray)));
    }
    return ListView.builder(
      controller: _scrollController,
      keyboardScrollable: false,
      itemExtent: 1,
      itemCount: visible.length,
      itemBuilder: (context, index) => _buildRow(visible[index], index),
    );
  }

  Component _buildRow(BranchInfo b, int index) {
    final selected = index == _selected;
    final mark = _marks[b.name] ?? MarkState.none;

    final (markGlyph, markColor) = switch (mark) {
      MarkState.delete => ('✗', Colors.red),
      MarkState.push => ('↑', Colors.green),
      MarkState.none => (' ', Colors.white),
    };

    // Name color by state.
    Color nameColor;
    if (b.isProtected) {
      nameColor = Colors.cyan;
    } else if (b.isEffectivelyMerged) {
      nameColor = Colors.green;
    } else if (_isStale(b)) {
      nameColor = Colors.yellow;
    } else {
      nameColor = Colors.white;
    }

    final badges = <Component>[];
    void badge(String text, Color color) =>
        badges.add(Text(' $text', style: TextStyle(color: color)));
    if (b.isCurrent) badge('current', Colors.cyan);
    if (b.isDefault && !b.isCurrent) badge('default', Colors.blue);
    if (b.isMerged && !b.isProtected) badge('merged', Colors.green);
    if (b.isSquashMerged) badge('squashed', Colors.green);
    if (_isStale(b)) badge('stale', Colors.yellow);
    if (b.upstreamGone) badge('gone', Colors.red);
    if (!b.hasUpstream && !b.isProtected) badge('no-upstream', Colors.brightBlack);
    if (b.ahead > 0) badge('↑${b.ahead}', Colors.brightCyan);
    if (b.behind > 0) badge('↓${b.behind}', Colors.magenta);

    return Container(
      decoration:
          selected ? BoxDecoration(color: Color.fromRGB(40, 50, 65)) : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text('${selected ? '▶' : ' '} ',
              style: TextStyle(color: Colors.cyan)),
          SizedBox(
              width: 2,
              child: Text(markGlyph,
                  style: TextStyle(color: markColor, fontWeight: FontWeight.bold))),
          SizedBox(
            width: 30,
            child: Text(_trim(b.name, 30),
                style: TextStyle(
                    color: selected ? Colors.brightWhite : nameColor,
                    fontWeight: selected ? FontWeight.bold : null),
                overflow: TextOverflow.ellipsis,
                maxLines: 1),
          ),
          SizedBox(
              width: 14,
              child: Text(b.relativeDate,
                  style: TextStyle(color: Colors.brightBlack),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1)),
          Expanded(child: Row(children: badges)),
        ],
      ),
    );
  }

  Component _buildFooter() {
    final hints = _hasMarks
        ? 'space mark   ⏎ apply marks   esc clear   ↑↓ move   o sort   f filter   ? help   q quit'
        : '↑↓ move   space mark   d delete   p push   ⏎ apply   o sort   f filter   r refresh   ? help   q quit';
    final msg = _status;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: msg != null
          ? Text(msg, style: TextStyle(color: Colors.yellow), overflow: TextOverflow.ellipsis, maxLines: 1)
          : Text(hints, style: TextStyle(color: Colors.brightBlack), overflow: TextOverflow.ellipsis, maxLines: 1),
    );
  }

  Component _buildConfirm() {
    final lines = (_confirmPrompt ?? '').split('\n');
    return Center(
      child: Container(
        padding: EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: Color.fromRGB(55, 35, 35),
          border: BoxBorder.all(color: Colors.red),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Text(l, style: TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Component _buildHelp() {
    const lines = [
      'git_branches — find merged & stale local branches, then clean up',
      '',
      '  ↑ ↓        move selection',
      '  space      cycle mark: none → ✗ delete → ↑ push → none',
      '  ⏎          apply all marks (delete ✗, push ↑) with confirmation',
      '  esc        clear all marks',
      '',
      '  d          delete the highlighted branch now (when nothing marked)',
      '  p          push the highlighted branch now (when nothing marked)',
      '',
      '  o          cycle sort: stalest first / recent first / name',
      '  f          cycle filter: all / merged / unmerged',
      '  r          reload branches',
      '  q          quit',
      '',
      'Delete is local-only: -d for merged, -D (force) otherwise.',
      'Squash/rebase-merged branches are detected and shown "squashed" —',
      'their work is already on the default branch, so they are safe to delete.',
      'Push uses `git push` (-u origin <branch> when there is no upstream).',
      'The current and default branches are protected from deletion.',
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final l in lines) Text(l, style: TextStyle(color: Colors.gray))],
      ),
    );
  }

  String _trim(String text, int max) {
    if (text.length <= max) return text;
    if (max <= 1) return '…';
    return '${text.substring(0, max - 1)}…';
  }

  void _move(int delta) {
    final v = _visible;
    if (v.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, v.length - 1));
    _scrollController.ensureIndexVisible(index: _selected);
  }

  // ---- Key handling ---------------------------------------------------------

  bool _handleKey(KeyboardEvent event) {
    if (_busy) return true;
    final key = event.logicalKey;

    if (_confirmPrompt != null) {
      if (key == LogicalKey.keyY) {
        final action = _confirmAction;
        setState(() {
          _confirmPrompt = null;
          _confirmAction = null;
        });
        action?.call();
        return true;
      }
      if (key == LogicalKey.keyN || key == LogicalKey.escape) {
        setState(() {
          _confirmPrompt = null;
          _confirmAction = null;
        });
        return true;
      }
      return true;
    }

    if (key == LogicalKey.keyQ) {
      shutdownApp();
      return true;
    }
    if (key == LogicalKey.question) {
      setState(() => _showHelp = !_showHelp);
      return true;
    }
    if (_showHelp) {
      if (key == LogicalKey.escape || key == LogicalKey.arrowLeft) {
        setState(() => _showHelp = false);
        return true;
      }
      return false;
    }

    if (key == LogicalKey.arrowUp) {
      _move(-1);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      _move(1);
      return true;
    }
    if (key == LogicalKey.space) {
      final b = _highlighted;
      if (b != null) _cycleMark(b);
      return true;
    }
    if (key == LogicalKey.enter) {
      _applyMarks();
      return true;
    }
    if (key == LogicalKey.escape) {
      if (_hasMarks) {
        setState(() => _marks.clear());
        _flash('Cleared marks.');
      }
      return true;
    }
    if (key == LogicalKey.keyD) {
      if (_hasMarks) {
        _flash('You have pending marks — press ⏎ to apply or esc to clear.');
      } else {
        final b = _highlighted;
        if (b != null) _quickDelete(b);
      }
      return true;
    }
    if (key == LogicalKey.keyP) {
      if (_hasMarks) {
        _flash('You have pending marks — press ⏎ to apply or esc to clear.');
      } else {
        final b = _highlighted;
        if (b != null) _quickPush(b);
      }
      return true;
    }
    if (key == LogicalKey.keyO) {
      setState(() => _sort = _sort.next);
      return true;
    }
    if (key == LogicalKey.keyF) {
      setState(() {
        _filter = _filter.next;
        _selected = 0;
      });
      return true;
    }
    if (key == LogicalKey.keyR) {
      unawaited(_load());
      return true;
    }
    return false;
  }
}
