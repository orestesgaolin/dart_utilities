import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../chain/chain_service.dart';
import '../chain/sync_engine.dart';
import '../git/git_repo.dart';
import '../git/github.dart';
import '../models.dart';
import '../storage/database.dart';
import 'app_intent.dart';

/// Which screen the TUI is currently showing.
enum _View { repos, chains, chainDetail, history, help }

/// Interactive terminal UI for browsing repos, visualizing branch chains and
/// their PRs, and triggering syncs.
class GitChainApp extends StatefulComponent {
  const GitChainApp({
    required this.db,
    required this.service,
    required this.intent,
    this.initialRepo,
    this.initialGit,
    super.key,
  });

  final ChainDatabase db;
  final ChainService service;
  final AppIntent intent;

  /// When launched inside a repo, jump straight to its chains.
  final Repo? initialRepo;
  final GitRepo? initialGit;

  @override
  State<GitChainApp> createState() => _GitChainAppState();
}

class _GitChainAppState extends State<GitChainApp> {
  _View _view = _View.repos;

  /// View to return to when help is closed.
  _View _helpReturnView = _View.repos;
  final _scrollController = ScrollController();

  // Current view data.
  List<Repo> _repos = [];
  List<Chain> _chains = [];
  List<BranchStatus> _statuses = [];
  Map<String, PullRequest> _prsByBranch = {};
  List<SyncRun> _runs = [];

  /// Whether the current chain's status/PRs have finished loading at least
  /// once (so we can distinguish "loading" from "loaded, no PR").
  bool _detailLoaded = false;

  // Per-session caches keyed by chain id, so revisiting a chain is instant and
  // refreshes in the background.
  final _statusCache = <int, List<BranchStatus>>{};
  final _prCache = <int, Map<String, PullRequest>>{};

  /// Expanded branch positions (stack index) → cached commit list.
  final _expanded = <int>{};
  final _commitsCache = <String, List<Commit>>{};

  // Current context.
  Repo? _repo;
  GitRepo? _git;
  Chain? _chain;

  /// The branch currently checked out in the repo (for the ● marker).
  String? _currentBranch;

  // Selection per view.
  int _repoIndex = 0;
  int _chainIndex = 0;
  int _branchIndex = 0;
  int _runIndex = 0;

  bool _loading = false;
  String? _status;

  /// Auto-clears transient status messages (e.g. "Opening PR…").
  Timer? _statusTimer;

  // Overlay: strategy chooser before a sync.
  bool _chooseStrategy = false;

  // Overlay: checkout choice when the working tree is dirty.
  bool _checkoutChoice = false;
  String? _checkoutBranch;

  // Overlay: sync choice when the working tree is dirty.
  bool _syncDirtyChoice = false;
  SyncStrategy? _syncDirtyStrategy;

  /// True while an in-app sync is running; shows the progress overlay and
  /// swallows input.
  bool _syncing = false;

  /// Live log lines emitted by the sync engine, shown in the progress overlay.
  List<String> _syncLog = [];
  // Overlay: confirm a destructive action; runs [_confirmAction] on yes.
  String? _confirmPrompt;
  void Function()? _confirmAction;

  @override
  void initState() {
    super.initState();
    if (component.initialRepo != null) {
      _repo = component.initialRepo;
      _git = component.initialGit;
      unawaited(_openRepo(component.initialRepo!, git: component.initialGit));
    } else {
      _loadRepos();
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Sets a status message that clears itself after a few seconds.
  void _flash(String message) {
    _statusTimer?.cancel();
    setState(() => _status = message);
    _statusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _status = null);
    });
  }

  // ---- Data loading ---------------------------------------------------------

  void _loadRepos() {
    setState(() {
      _repos = component.db.listRepos();
      _view = _View.repos;
      _repoIndex = _repoIndex.clamp(0, _repos.isEmpty ? 0 : _repos.length - 1);
    });
  }

  Future<void> _openRepo(Repo repo, {GitRepo? git}) async {
    setState(() {
      _repo = repo;
      _git = git ?? GitRepo(repo.path);
      _loading = true;
      _status = 'Loading chains for ${repo.name}…';
      _view = _View.chains;
      _chainIndex = 0;
    });
    component.db.touchRepo(repo.id);

    var chains = component.db.listChains(repo.id);
    if (chains.isEmpty) {
      // Hybrid: auto-detect from PRs on first open.
      final detected = await component.service.detectChains(repo);
      for (final d in detected) {
        component.service.saveDetectedChain(repo, d);
      }
      chains = component.db.listChains(repo.id);
    }
    if (!mounted) return;
    setState(() {
      _chains = chains;
      _loading = false;
      _status = chains.isEmpty ? 'No chains. Press [i] to import from open PRs.' : null;
    });
  }

  Future<void> _redetectChains() async {
    final repo = _repo;
    if (repo == null) return;
    setState(() {
      _loading = true;
      _status = 'Detecting chains from PRs…';
    });
    final detected = await component.service.detectChains(repo);
    var added = 0;
    for (final d in detected) {
      if (component.service.saveDetectedChain(repo, d) != null) added++;
    }
    if (!mounted) return;
    setState(() {
      _chains = component.db.listChains(repo.id);
      _loading = false;
      _status = added == 0
          ? 'No new chains found (need open PRs with stacked bases).'
          : 'Imported $added chain(s) from PRs.';
    });
  }

  Future<void> _openChain(Chain chain) async {
    final cachedStatus = _statusCache[chain.id];
    final cachedPrs = _prCache[chain.id];
    final hasCache = cachedStatus != null && cachedPrs != null;

    setState(() {
      _chain = chain;
      _view = _View.chainDetail;
      _branchIndex = 0;
      _expanded.clear();
      // Show cached data instantly; otherwise show a loading state.
      _statuses = cachedStatus ?? [];
      _prsByBranch = cachedPrs ?? {};
      _detailLoaded = hasCache;
      _loading = !hasCache;
      _status = hasCache ? null : 'Reading branch status…';
    });

    // Always refresh in the background (silently when we already had a cache).
    await _refreshStatuses(silent: hasCache);
  }

  Future<void> _refreshStatuses({bool silent = false}) async {
    final repo = _repo;
    final git = _git;
    final chain = _chain;
    if (repo == null || git == null || chain == null) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _status = 'Reading branch status…';
      });
    }

    // Refresh PR numbers and gather live git status.
    final refreshed = await component.service.refreshChainPrs(repo, chain);
    final statuses = await git.chainStatus(refreshed);
    final prs = await component.service.fetchPullRequests(repo);
    final byBranch = {for (final pr in prs) pr.headRef: pr};
    final current = await git.currentBranch();

    // Update the per-session cache.
    _statusCache[chain.id] = statuses;
    _prCache[chain.id] = byBranch;
    _commitsCache.clear(); // commits may have changed after a refresh

    if (!mounted || _chain?.id != chain.id) return;
    setState(() {
      _chain = refreshed;
      _statuses = statuses;
      _prsByBranch = byBranch;
      _currentBranch = current;
      _chains = component.db.listChains(repo.id);
      _detailLoaded = true;
      _loading = false;
      if (!silent) _status = null;
    });
  }

  /// Loads the commits for an expanded branch (stack index [stackIndex]).
  Future<void> _loadCommits(int stackIndex) async {
    final git = _git;
    final chain = _chain;
    if (git == null || chain == null) return;
    final branch = chain.branches[stackIndex + 1].branch;
    final parent = chain.branches[stackIndex].branch;
    final key = '$parent..$branch';
    if (_commitsCache.containsKey(key)) return;
    final commits = await git.commitsBetween(parent, branch);
    if (!mounted) return;
    setState(() => _commitsCache[key] = commits);
  }

  Future<void> _checkoutSelected() async {
    final git = _git;
    final chain = _chain;
    if (git == null || chain == null) return;
    final idx = _branchIndex + 1;
    if (idx < 1 || idx >= chain.branches.length) return;
    final branch = chain.branches[idx].branch;

    // A dirty tree would block (or drag changes into) the checkout — offer a
    // choice: stash & restore, or check out keeping the changes (skip stash).
    if (await git.isDirty()) {
      if (!mounted) return;
      setState(() {
        _checkoutChoice = true;
        _checkoutBranch = branch;
      });
      return;
    }
    await _checkout(branch, stash: false);
  }

  Future<void> _checkout(String branch, {required bool stash}) async {
    final git = _git;
    if (git == null) return;

    String? label;
    if (stash) {
      label = GitRepo.stashLabel('checkout $branch');
      _flash('Stashing changes…');
      final pushed = await git.stashPush(label);
      if (!mounted) return;
      if (!pushed.ok) {
        _flash('✗ stash failed: ${pushed.stderr.trim().split('\n').first}');
        return;
      }
    }

    final result = await git.checkout(branch);
    if (!mounted) return;
    if (!result.ok) {
      final err = result.stderr.trim().split('\n').first;
      if (label != null) {
        // Restore onto the branch we were on before the failed switch.
        await git.stashPopByMessage(label);
      }
      _flash('✗ checkout failed: $err');
      return;
    }

    if (label == null) {
      _flash('✓ Checked out $branch');
      await _refreshStatuses(silent: true);
      return;
    }

    // Restore the stash onto the freshly checked-out branch.
    final popError = await git.stashPopByMessage(label);
    if (!mounted) return;
    if (popError == null) {
      _flash('✓ Checked out $branch, changes restored');
    } else {
      _flash('⚠ On $branch — stash "$label" kept ($popError)');
    }
    await _refreshStatuses(silent: true);
  }

  void _openHistory() {
    final chain = _chain;
    if (chain == null) return;
    setState(() {
      _runs = component.db.listSyncRuns(chain.id);
      _view = _View.history;
      _runIndex = 0;
    });
  }

  // ---- Actions --------------------------------------------------------------

  /// Runs the sync inside the TUI with live progress. Git operations are
  /// captured subprocesses that don't touch the screen, so the app stays open
  /// for the common (conflict-free) case. If a branch conflicts — which needs
  /// the interactive `git mergetool` — we hand off to the shell and re-run.
  Future<void> _runSyncInApp(SyncStrategy strategy) async {
    final repo = _repo;
    final git = _git;
    final chain = _chain;
    if (repo == null || git == null || chain == null) return;

    // A dirty tree blocks rebase/merge. Detect it upfront and let the user
    // choose: stash & restore, proceed without stashing, or cancel.
    if (await git.isDirty()) {
      if (!mounted) return;
      setState(() {
        _chooseStrategy = false;
        _syncDirtyChoice = true;
        _syncDirtyStrategy = strategy;
      });
      return;
    }
    await _doSync(strategy, stash: false);
  }

  Future<void> _doSync(SyncStrategy strategy,
      {required bool stash, bool allowDirty = false}) async {
    final repo = _repo;
    final git = _git;
    final chain = _chain;
    if (repo == null || git == null || chain == null) return;

    setState(() {
      _chooseStrategy = false;
      _syncing = true;
      _syncLog = ['Starting ${strategy.label} of "${chain.name}"…'];
    });

    String? stashLabel;
    if (stash) {
      stashLabel = GitRepo.stashLabel('pre-sync ${chain.name}');
      setState(() => _syncLog = [..._syncLog, '⟳ Stashing local changes…']);
      final pushed = await git.stashPush(stashLabel);
      if (!pushed.ok) {
        if (!mounted) return;
        setState(() => _syncing = false);
        _flash('✗ stash failed: ${pushed.stderr.trim().split('\n').first}');
        return;
      }
    }

    SyncRequest? handoff;
    final engine = SyncEngine(
      repo: git,
      log: (message) {
        if (mounted) setState(() => _syncLog = [..._syncLog, message]);
      },
      resolveConflict: (branch, files) async {
        // We can't run an interactive merge tool inside the TUI, so abort to
        // leave the tree clean and hand the sync off to the shell, which will
        // skip the branches we already synced and resolve this one. The shell
        // run inherits our stash/allow-dirty decision so it doesn't re-prompt.
        handoff = SyncRequest(
          repo: repo,
          chain: chain,
          strategy: strategy,
          stashLabel: stashLabel,
          allowDirty: allowDirty,
        );
        return false;
      },
    );

    final outcome = await engine.run(chain, strategy, allowDirty: allowDirty);

    if (handoff != null) {
      // Conflict — finish in the shell with the merge tool. Keep our stash in
      // place; the shell run will restore it once the sync completes there.
      if (!mounted) return;
      component.intent.syncRequest = handoff;
      TerminalBinding.instance.shutdown();
      return;
    }

    component.db.recordSyncRun(
      chainId: chain.id,
      strategy: strategy,
      status: outcome.status,
      summary: outcome.summary,
      startedAt: outcome.startedAt,
      finishedAt: outcome.finishedAt,
      steps: outcome.steps,
    );

    String? restoreNote;
    if (stashLabel != null) {
      final err = await git.stashPopByMessage(stashLabel);
      restoreNote = err == null
          ? null
          : ' (stash "$stashLabel" kept — $err)';
    }

    // Drop caches so the refreshed status reflects the rebase.
    _statusCache.remove(chain.id);
    _prCache.remove(chain.id);
    _commitsCache.clear();
    if (!mounted) return;
    setState(() => _syncing = false);
    await _refreshStatuses(silent: true);
    if (!mounted) return;
    _flash(outcome.status == 'ok'
        ? '✓ Synced — ${outcome.summary}${restoreNote ?? ''}'
        : 'Sync ${outcome.status} — ${outcome.summary}${restoreNote ?? ''}');
  }

  void _openSelectedPr() {
    final pr = _selectedPr;
    if (pr != null) {
      GitHub.openUrl(pr.url);
      _flash('Opening PR #${pr.number} in browser…');
    } else {
      _flash('No PR associated with this branch.');
    }
  }

  PullRequest? get _selectedPr {
    final chain = _chain;
    if (chain == null) return null;
    final idx = _branchIndex + 1; // skip target
    if (idx < 1 || idx >= chain.branches.length) return null;
    return _prsByBranch[chain.branches[idx].branch];
  }

  void _deleteSelectedChain() {
    if (_chains.isEmpty) return;
    final chain = _chains[_chainIndex];
    setState(() {
      _confirmPrompt = 'Delete chain "${chain.name}"? [y/n]';
      _confirmAction = () {
        component.db.deleteChain(chain.id);
        setState(() {
          _chains = component.db.listChains(_repo!.id);
          _chainIndex =
              _chainIndex.clamp(0, _chains.isEmpty ? 0 : _chains.length - 1);
          _status = 'Deleted chain.';
        });
      };
    });
  }

  void _deleteSelectedRepo() {
    if (_repos.isEmpty) return;
    final repo = _repos[_repoIndex];
    setState(() {
      _confirmPrompt = 'Stop tracking "${repo.name}"? (chains & history lost) [y/n]';
      _confirmAction = () {
        component.db.deleteRepo(repo.id);
        setState(() {
          _repos = component.db.listRepos();
          _repoIndex =
              _repoIndex.clamp(0, _repos.isEmpty ? 0 : _repos.length - 1);
          _status = 'Stopped tracking repo.';
        });
      };
    });
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
    final crumbs = StringBuffer('git_chain');
    if (_repo != null) crumbs.write('  ›  ${_repo!.name}');
    if (_view == _View.chainDetail && _chain != null) {
      crumbs.write('  ›  ${_chain!.name}');
    }
    if (_view == _View.history && _chain != null) {
      crumbs.write('  ›  ${_chain!.name}  ›  history');
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Text(
        crumbs.toString(),
        style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );
  }

  Component _buildBody() {
    if (_syncing) return _buildSyncProgress();
    if (_confirmPrompt != null) return _buildConfirm();
    if (_checkoutChoice) return _buildCheckoutChoice();
    if (_syncDirtyChoice) return _buildSyncDirtyChoice();
    if (_chooseStrategy) return _buildStrategyChooser();
    return switch (_view) {
      _View.repos => _buildReposView(),
      _View.chains => _buildChainsView(),
      _View.chainDetail => _buildChainDetailView(),
      _View.history => _buildHistoryView(),
      _View.help => _buildHelpView(),
    };
  }

  Component _buildFooter() {
    String hints;
    switch (_view) {
      case _View.repos:
        hints = '↑↓ select   ⏎ open   d untrack   r refresh   ? help   q quit';
      case _View.chains:
        hints = '↑↓ select   ⏎ open   i import-PRs   d delete   ← back   ? help   q quit';
      case _View.chainDetail:
        hints =
            '↑↓ branch  e expand  c checkout  s sync  o open-PR  r refresh  h history  ? help  ← back';
      case _View.history:
        hints = '↑↓ scroll   ← back   ? help   q quit';
      case _View.help:
        hints = '? / ← / esc   close help   q quit';
    }
    final msg = _status;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: msg != null
          ? Text(msg, style: TextStyle(color: Colors.yellow),
              overflow: TextOverflow.ellipsis, maxLines: 1)
          : Text(hints, style: TextStyle(color: Colors.brightBlack),
              overflow: TextOverflow.ellipsis, maxLines: 1),
    );
  }

  // ---- Views ----------------------------------------------------------------

  Component _buildReposView() {
    if (_repos.isEmpty) {
      return Center(
        child: Text(
          'No repositories tracked yet.\nRun `git_chain` inside a git repo to add one.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      keyboardScrollable: false,
      itemExtent: 1,
      itemCount: _repos.length,
      itemBuilder: (context, index) {
        final repo = _repos[index];
        final selected = index == _repoIndex;
        final chainCount = component.db.listChains(repo.id).length;
        return _row(
          selected: selected,
          children: [
            Text(selected ? '▶ ' : '  '),
            Expanded(
              child: Text(repo.name,
                  style: TextStyle(
                      color: selected ? Colors.cyan : Colors.white,
                      fontWeight: selected ? FontWeight.bold : null),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1),
            ),
            SizedBox(
              width: 16,
              child: Text('$chainCount chain(s)',
                  style: TextStyle(color: Colors.brightBlack),
                  textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }

  Component _buildChainsView() {
    if (_chains.isEmpty) {
      return Center(
        child: Text(
          _loading
              ? 'Loading…'
              : 'No chains for this repo.\nPress [i] to import from open PRs.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      keyboardScrollable: false,
      itemExtent: 1,
      itemCount: _chains.length,
      itemBuilder: (context, index) {
        final chain = _chains[index];
        final selected = index == _chainIndex;
        final depth = chain.branches.length - 1;
        return _row(
          selected: selected,
          children: [
            Text(selected ? '▶ ' : '  '),
            // Left-aligned, fixed-width name column (trimmed with …).
            SizedBox(
              width: 26,
              child: Text(
                _trim(chain.name, 26),
                style: TextStyle(
                    color: selected ? Colors.cyan : Colors.white,
                    fontWeight: selected ? FontWeight.bold : null),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            Text('  '),
            Expanded(
              child: Text(
                _chainPreview(chain),
                style: TextStyle(color: Colors.brightBlack),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            SizedBox(
              width: 12,
              child: Text('$depth branch(es)',
                  style: TextStyle(color: Colors.brightBlack),
                  textAlign: TextAlign.right),
            ),
          ],
        );
      },
    );
  }

  /// Trims [text] to at most [max] columns, appending an ellipsis when cut.
  String _trim(String text, int max) {
    if (text.length <= max) return text;
    if (max <= 1) return '…';
    return '${text.substring(0, max - 1)}…';
  }

  String _chainPreview(Chain chain) {
    final names = chain.branches.map((b) => b.branch).toList();
    final joined = names.join(' ← ');
    return joined.length > 60 ? '${joined.substring(0, 57)}…' : joined;
  }

  Component _buildChainDetailView() {
    final chain = _chain;
    if (chain == null) return const SizedBox.shrink();
    // One row per branch (target + stack), with optional commit sub-rows.
    final rows = <Component>[];
    for (var i = 0; i < chain.branches.length; i++) {
      rows.add(_buildBranchRow(chain, i));
      // Expanded commits live below their stack branch (i >= 1).
      if (i >= 1 && _expanded.contains(i - 1)) {
        rows.addAll(_buildCommitRows(chain, i));
      }
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  List<Component> _buildCommitRows(Chain chain, int i) {
    final parent = chain.branches[i - 1].branch;
    final branch = chain.branches[i].branch;
    final commits = _commitsCache['$parent..$branch'];
    final indent = '  ' * (i + 1);
    if (commits == null) {
      return [
        _row(
          selected: false,
          children: [
            Text(indent),
            Text('Loading commits…', style: TextStyle(color: Colors.brightBlack)),
          ],
        ),
      ];
    }
    if (commits.isEmpty) {
      return [
        _row(
          selected: false,
          children: [
            Text(indent),
            Text('(no commits ahead of $parent)',
                style: TextStyle(color: Colors.brightBlack)),
          ],
        ),
      ];
    }
    return [
      for (final c in commits)
        _row(
          selected: false,
          children: [
            Text('$indent· ', style: TextStyle(color: Colors.gray)),
            Text('${c.shortSha} ',
                style: TextStyle(color: Colors.brightYellow)),
            Expanded(
              child: Text(c.subject,
                  style: TextStyle(color: Colors.gray),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1),
            ),
          ],
        ),
    ];
  }

  Component _buildBranchRow(Chain chain, int i) {
    final branch = chain.branches[i];
    final isTarget = i == 0;
    final selected = !isTarget && (i - 1) == _branchIndex;

    final isCurrent = branch.branch == _currentBranch;
    final indent = '  ' * i;
    final expandMark = !isTarget && _expanded.contains(i - 1) ? '▾' : '▸';
    final connector = isTarget ? '● ' : '└─$expandMark ';

    // Find live status (statuses are indexed for stack branches only).
    BranchStatus? status;
    if (!isTarget && (i - 1) < _statuses.length) status = _statuses[i - 1];
    final pr = _prsByBranch[branch.branch];

    // Branch name color by state.
    Color nameColor;
    if (isTarget) {
      nameColor = Colors.blue;
    } else if (status != null && !status.exists) {
      nameColor = Colors.brightBlack;
    } else if (status != null && status.needsSync) {
      nameColor = Colors.yellow;
    } else {
      nameColor = Colors.green;
    }

    final children = <Component>[
      // Current-branch (HEAD) marker — updates after a checkout.
      SizedBox(
        width: 2,
        child: Text(isCurrent ? '*' : ' ',
            style: TextStyle(color: Colors.brightCyan, fontWeight: FontWeight.bold)),
      ),
      Text('$indent$connector', style: TextStyle(color: Colors.gray)),
      // Left-aligned, fixed-width, trimmed branch name.
      SizedBox(
        width: 34,
        child: Text(_trim(branch.branch, 34),
            style: TextStyle(
                color: selected ? Colors.cyan : nameColor,
                fontWeight: selected ? FontWeight.bold : null),
            overflow: TextOverflow.ellipsis,
            maxLines: 1),
      ),
    ];

    if (isTarget) {
      children.add(Text('  (target)', style: TextStyle(color: Colors.brightBlack)));
    } else if (!_detailLoaded) {
      // Don't show "(no PR)" before data arrives.
      children.add(Text('  Loading…', style: TextStyle(color: Colors.brightBlack)));
    } else {
      // PR badge.
      if (pr != null) {
        final draft = pr.isDraft ? ' draft' : '';
        children.add(Text('  #${pr.number}$draft',
            style: TextStyle(color: pr.isDraft ? Colors.gray : Colors.magenta)));
        if (pr.assignees.isNotEmpty) {
          final who = pr.assignees.length == 1
              ? '@${pr.assignees.first}'
              : '@${pr.assignees.first}+${pr.assignees.length - 1}';
          children.add(Text(' $who', style: TextStyle(color: Colors.blue)));
        }
      } else {
        children.add(Text('  (no PR)', style: TextStyle(color: Colors.brightBlack)));
      }
      // Status badge.
      children.add(Text('  ${_statusBadge(status)}',
          style: TextStyle(color: _statusColor(status))));
    }

    return _row(
      selected: selected,
      children: [Expanded(child: Row(children: children))],
    );
  }

  String _statusBadge(BranchStatus? s) {
    if (!_detailLoaded) return 'Loading…';
    if (s == null) return '…';
    if (!s.exists) return 'missing locally';
    final parts = <String>[];
    if (s.behind > 0) {
      parts.add('⟳ ${s.behind} behind');
    } else {
      parts.add('✓ in sync');
    }
    if (s.ahead > 0) parts.add('↑${s.ahead}');
    if (s.needsPush) parts.add('push ${s.upstreamAhead}');
    return parts.join('  ');
  }

  Color _statusColor(BranchStatus? s) {
    if (s == null) return Colors.brightBlack;
    if (!s.exists) return Colors.red;
    if (s.needsSync) return Colors.yellow;
    return Colors.green;
  }

  Component _buildHistoryView() {
    if (_runs.isEmpty) {
      return Center(
        child: Text('No sync history for this chain yet.',
            style: TextStyle(color: Colors.gray)),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      keyboardScrollable: false,
      itemExtent: 1,
      itemCount: _runs.length,
      itemBuilder: (context, index) {
        final run = _runs[index];
        final selected = index == _runIndex;
        final when = _formatDate(run.startedAt);
        final statusColor = switch (run.status) {
          'ok' => Colors.green,
          'conflict' => Colors.yellow,
          'aborted' => Colors.brightBlack,
          _ => Colors.red,
        };
        return _row(
          selected: selected,
          children: [
            SizedBox(width: 18, child: Text(when, style: TextStyle(color: Colors.gray))),
            SizedBox(
                width: 9,
                child: Text(run.strategy.label,
                    style: TextStyle(color: Colors.brightBlack))),
            SizedBox(
                width: 10,
                child: Text(run.status, style: TextStyle(color: statusColor))),
            Expanded(
              child: Text(run.summary,
                  style: TextStyle(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1),
            ),
          ],
        );
      },
    );
  }

  Component _buildHelpView() {
    const lines = [
      'git_chain — stacked branch chain manager',
      '',
      'Repos view',
      '  ↑ ↓        select repository',
      '  ⏎          open repository chains',
      '  d          stop tracking the repository',
      '  r          refresh repo list',
      '',
      'Chains view',
      '  ⏎          open chain detail',
      '  i          import/detect chains from open PRs',
      '  d          delete chain',
      '  ← / esc    back to repos',
      '',
      'Chain detail',
      '  ↑ ↓        select branch in the stack',
      '  e          expand/collapse commits vs. parent (no merges)',
      '  c          checkout selected branch (if dirty: stash or keep changes)',
      '  s          synchronize chain (choose rebase / merge)',
      '  o          open selected branch PR in browser',
      '  r          refresh branch status & PRs',
      '  h          view sync history',
      '',
      'Sync conflicts open in your configured git mergetool.',
      'When the tree is dirty, checkout and sync offer to stash your changes',
      'under an explicit "git_chain: …" label and restore them afterwards.',
      'Press q to quit.',
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final l in lines) Text(l, style: TextStyle(color: Colors.gray))],
      ),
    );
  }

  // ---- Overlays -------------------------------------------------------------

  Component _buildStrategyChooser() {
    final chain = _chain;
    return Center(
      child: Container(
        padding: EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: Color.fromRGB(30, 40, 55),
          border: BoxBorder.all(color: Colors.cyan),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Synchronize "${chain?.name ?? ''}"',
                style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
            Text(''),
            Text('Choose how to bring each branch up to its parent:',
                style: TextStyle(color: Colors.white)),
            Text(''),
            Text('  [r]  rebase onto parent  (linear history, force-push)',
                style: TextStyle(color: Colors.green)),
            Text('  [m]  merge parent in     (merge commits, no force-push)',
                style: TextStyle(color: Colors.green)),
            Text('  [esc] cancel', style: TextStyle(color: Colors.brightBlack)),
          ],
        ),
      ),
    );
  }

  Component _buildCheckoutChoice() {
    return Center(
      child: Container(
        padding: EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: Color.fromRGB(30, 40, 55),
          border: BoxBorder.all(color: Colors.cyan),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Checkout "${_checkoutBranch ?? ''}"',
                style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
            Text(''),
            Text('The working tree has uncommitted changes:',
                style: TextStyle(color: Colors.white)),
            Text(''),
            Text('  [s]  stash, checkout, then restore',
                style: TextStyle(color: Colors.green)),
            Text('  [k]  checkout and keep changes (no stash)',
                style: TextStyle(color: Colors.green)),
            Text('  [esc] cancel', style: TextStyle(color: Colors.brightBlack)),
          ],
        ),
      ),
    );
  }

  Component _buildSyncDirtyChoice() {
    final strategy = _syncDirtyStrategy;
    return Center(
      child: Container(
        padding: EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: Color.fromRGB(30, 40, 55),
          border: BoxBorder.all(color: Colors.cyan),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Synchronize "${_chain?.name ?? ''}" (${strategy?.label ?? ''})',
                style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
            Text(''),
            Text('The working tree has uncommitted changes:',
                style: TextStyle(color: Colors.white)),
            Text(''),
            Text('  [s]  stash, ${strategy?.label ?? 'sync'}, then restore',
                style: TextStyle(color: Colors.green)),
            Text('  [k]  ${strategy?.label ?? 'sync'} without stashing (keep changes)',
                style: TextStyle(color: Colors.green)),
            if (strategy == SyncStrategy.rebase)
              Text('       note: rebase needs a clean tree and may refuse',
                  style: TextStyle(color: Colors.brightBlack)),
            Text('  [esc] cancel', style: TextStyle(color: Colors.brightBlack)),
          ],
        ),
      ),
    );
  }

  Component _buildSyncProgress() {
    // Show the most recent log lines.
    const maxLines = 16;
    final lines = _syncLog.length > maxLines
        ? _syncLog.sublist(_syncLog.length - maxLines)
        : _syncLog;
    return Center(
      child: Container(
        padding: EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: Color.fromRGB(30, 40, 55),
          border: BoxBorder.all(color: Colors.cyan),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Synchronizing "${_chain?.name ?? ''}" …',
                style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
            Text(''),
            for (final line in lines)
              Text(line,
                  style: TextStyle(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1),
          ],
        ),
      ),
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
            for (final line in lines)
              Text(line,
                  style:
                      TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  // ---- Shared row helper ----------------------------------------------------

  Component _row({required bool selected, required List<Component> children}) {
    return Container(
      decoration:
          selected ? BoxDecoration(color: Color.fromRGB(40, 50, 65)) : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(children: children),
    );
  }

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _scrollToSelected(int index) {
    _scrollController.ensureIndexVisible(index: index);
  }

  // ---- Key handling ---------------------------------------------------------

  bool _handleKey(KeyboardEvent event) {
    // While a sync runs, swallow all input.
    if (_syncing) return true;
    // Overlays take priority.
    if (_confirmPrompt != null) return _handleConfirmKey(event);
    if (_checkoutChoice) return _handleCheckoutChoiceKey(event);
    if (_syncDirtyChoice) return _handleSyncDirtyKey(event);
    if (_chooseStrategy) return _handleStrategyKey(event);

    final key = event.logicalKey;

    // Global. Stop via the binding (not shutdownApp/exit) so runApp returns to
    // the caller, which flushes the terminal before exiting — otherwise stray
    // capability-query responses leak into the shell.
    if (key == LogicalKey.keyQ) {
      TerminalBinding.instance.shutdown();
      return true;
    }
    if (key == LogicalKey.question ||
        (key == LogicalKey.slash && event.isShiftPressed)) {
      setState(() {
        if (_view == _View.help) {
          _view = _helpReturnView; // toggle closed
        } else {
          _helpReturnView = _view;
          _view = _View.help;
        }
      });
      return true;
    }

    switch (_view) {
      case _View.repos:
        return _handleReposKey(event);
      case _View.chains:
        return _handleChainsKey(event);
      case _View.chainDetail:
        return _handleChainDetailKey(event);
      case _View.history:
        return _handleHistoryKey(event);
      case _View.help:
        if (_isBack(key)) {
          setState(() => _view = _helpReturnView);
          return true;
        }
        return false;
    }
  }

  bool _isBack(LogicalKey key) =>
      key == LogicalKey.escape ||
      key == LogicalKey.arrowLeft ||
      key == LogicalKey.backspace;

  bool _handleReposKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (_repos.isEmpty) return false;
    if (key == LogicalKey.arrowUp) {
      setState(() => _repoIndex = (_repoIndex - 1).clamp(0, _repos.length - 1));
      _scrollToSelected(_repoIndex);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      setState(() => _repoIndex = (_repoIndex + 1).clamp(0, _repos.length - 1));
      _scrollToSelected(_repoIndex);
      return true;
    }
    if (key == LogicalKey.enter || key == LogicalKey.arrowRight) {
      unawaited(_openRepo(_repos[_repoIndex]));
      return true;
    }
    if (key == LogicalKey.keyD) {
      _deleteSelectedRepo();
      return true;
    }
    if (key == LogicalKey.keyR) {
      _loadRepos();
      return true;
    }
    return false;
  }

  bool _handleChainsKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (_isBack(key)) {
      _loadRepos();
      return true;
    }
    if (key == LogicalKey.keyI) {
      unawaited(_redetectChains());
      return true;
    }
    if (_chains.isEmpty) return false;
    if (key == LogicalKey.arrowUp) {
      setState(() => _chainIndex = (_chainIndex - 1).clamp(0, _chains.length - 1));
      _scrollToSelected(_chainIndex);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      setState(() => _chainIndex = (_chainIndex + 1).clamp(0, _chains.length - 1));
      _scrollToSelected(_chainIndex);
      return true;
    }
    if (key == LogicalKey.enter || key == LogicalKey.arrowRight) {
      unawaited(_openChain(_chains[_chainIndex]));
      return true;
    }
    if (key == LogicalKey.keyD) {
      _deleteSelectedChain();
      return true;
    }
    return false;
  }

  bool _handleChainDetailKey(KeyboardEvent event) {
    final key = event.logicalKey;
    final chain = _chain;
    if (_isBack(key)) {
      setState(() => _view = _View.chains);
      return true;
    }
    final stackLen = (chain?.branches.length ?? 1) - 1;
    if (key == LogicalKey.arrowUp) {
      setState(() => _branchIndex =
          (_branchIndex - 1).clamp(0, stackLen <= 0 ? 0 : stackLen - 1));
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      setState(() => _branchIndex =
          (_branchIndex + 1).clamp(0, stackLen <= 0 ? 0 : stackLen - 1));
      return true;
    }
    if (key == LogicalKey.keyS) {
      if (chain != null && chain.branches.length > 1) {
        setState(() => _chooseStrategy = true);
      } else {
        setState(() => _status = 'Chain has no stacked branches to sync.');
      }
      return true;
    }
    if (key == LogicalKey.keyE) {
      _toggleExpanded();
      return true;
    }
    if (key == LogicalKey.keyC) {
      unawaited(_checkoutSelected());
      return true;
    }
    if (key == LogicalKey.keyO) {
      _openSelectedPr();
      return true;
    }
    if (key == LogicalKey.keyR) {
      unawaited(_refreshStatuses());
      return true;
    }
    if (key == LogicalKey.keyH) {
      _openHistory();
      return true;
    }
    return false;
  }

  void _toggleExpanded() {
    final chain = _chain;
    if (chain == null || chain.branches.length <= 1) return;
    final stackIndex = _branchIndex;
    setState(() {
      if (_expanded.contains(stackIndex)) {
        _expanded.remove(stackIndex);
      } else {
        _expanded.add(stackIndex);
      }
    });
    if (_expanded.contains(stackIndex)) {
      unawaited(_loadCommits(stackIndex));
    }
  }

  bool _handleHistoryKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (_isBack(key)) {
      setState(() => _view = _View.chainDetail);
      return true;
    }
    if (_runs.isEmpty) return false;
    if (key == LogicalKey.arrowUp) {
      setState(() => _runIndex = (_runIndex - 1).clamp(0, _runs.length - 1));
      _scrollToSelected(_runIndex);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      setState(() => _runIndex = (_runIndex + 1).clamp(0, _runs.length - 1));
      _scrollToSelected(_runIndex);
      return true;
    }
    return false;
  }

  bool _handleStrategyKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKey.escape) {
      setState(() => _chooseStrategy = false);
      return true;
    }
    if (key == LogicalKey.keyR) {
      unawaited(_runSyncInApp(SyncStrategy.rebase));
      return true;
    }
    if (key == LogicalKey.keyM) {
      unawaited(_runSyncInApp(SyncStrategy.merge));
      return true;
    }
    return false;
  }

  bool _handleCheckoutChoiceKey(KeyboardEvent event) {
    final key = event.logicalKey;
    final branch = _checkoutBranch;
    if (key == LogicalKey.escape) {
      setState(() {
        _checkoutChoice = false;
        _checkoutBranch = null;
      });
      return true;
    }
    if (branch == null) return true;
    if (key == LogicalKey.keyS) {
      setState(() {
        _checkoutChoice = false;
        _checkoutBranch = null;
      });
      unawaited(_checkout(branch, stash: true));
      return true;
    }
    if (key == LogicalKey.keyK) {
      setState(() {
        _checkoutChoice = false;
        _checkoutBranch = null;
      });
      unawaited(_checkout(branch, stash: false));
      return true;
    }
    return true;
  }

  bool _handleSyncDirtyKey(KeyboardEvent event) {
    final key = event.logicalKey;
    final strategy = _syncDirtyStrategy;
    if (key == LogicalKey.escape) {
      setState(() {
        _syncDirtyChoice = false;
        _syncDirtyStrategy = null;
      });
      return true;
    }
    if (strategy == null) return true;
    if (key == LogicalKey.keyS) {
      setState(() {
        _syncDirtyChoice = false;
        _syncDirtyStrategy = null;
      });
      unawaited(_doSync(strategy, stash: true));
      return true;
    }
    if (key == LogicalKey.keyK) {
      setState(() {
        _syncDirtyChoice = false;
        _syncDirtyStrategy = null;
      });
      unawaited(_doSync(strategy, stash: false, allowDirty: true));
      return true;
    }
    return true;
  }

  bool _handleConfirmKey(KeyboardEvent event) {
    final key = event.logicalKey;
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
    return false;
  }
}
