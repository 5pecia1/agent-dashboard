import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/prompt_analytics.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/prompt_history_provider.dart';
import 'package:my_dashboard/src/state/saved_prompts_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/prompt_dialogs.dart';
import 'package:my_dashboard/src/ui/widgets/prompt_pattern_card.dart';
import 'package:my_dashboard/src/ui/widgets/saved_prompts_view.dart';

const _initialPatternLimit = 40;
const _filterWidth = 200.0;
const _searchDelay = Duration(milliseconds: 200);
const _tabCount = 2;
const _supportedFilters = [
  'claude-code',
  'codex',
  'devin',
  'grok',
  'antigravity',
  'opencode',
];

class PromptLibraryPage extends ConsumerStatefulWidget {
  const PromptLibraryPage({super.key});
  @override
  ConsumerState<PromptLibraryPage> createState() => _PromptLibraryPageState();
}

class _PromptLibraryPageState extends ConsumerState<PromptLibraryPage>
    with SingleTickerProviderStateMixin {
  int _days = 7;
  String? _source;
  String _query = '';
  String _view = 'phrases';
  int _patternLimit = _initialPatternLimit;
  Timer? _searchDebounce;
  Object? _analysisEvents;
  String? _analysisSource;
  String? _analysisQuery;
  int? _analysisDays;
  PromptAnalysis? _analysis;
  final _searchController = TextEditingController();
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabCount, vsync: this);
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final previous = ref.read(promptHistoryProvider).asData?.value;
      if (previous?.lastRefreshedAt != null &&
          previous?.refreshing == false &&
          previous?.loadingMore == false) {
        unawaited(ref.read(promptHistoryProvider.notifier).refresh());
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _tabs.dispose();
    super.dispose();
  }

  PromptAnalysis _analyze(PromptHistoryState history) {
    if (_analysis != null &&
        identical(_analysisEvents, history.events) &&
        _analysisSource == _source &&
        _analysisDays == _days &&
        _analysisQuery == _query) {
      return _analysis!;
    }
    _analysisEvents = history.events;
    _analysisSource = _source;
    _analysisDays = _days;
    _analysisQuery = _query;
    return _analysis = analyzePrompts(
      history.events,
      source: _source,
      since: _days == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              history.lastRefreshedAt ?? DateTime.now().millisecondsSinceEpoch,
            ).subtract(Duration(days: _days)).millisecondsSinceEpoch,
      query: _query,
    );
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(promptHistoryProvider);
    final state = history.asData?.value;
    final savedActive = _tabs.index == 1;
    final saved = savedActive ? ref.watch(savedPromptsProvider) : null;
    final savedBusy = ref.watch(savedPromptsBusyProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: context.tokens.bg,
        appBar: AppBar(
          title: Text(t(ref, 'prompt.title')),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: t(ref, 'prompt.refresh'),
              onPressed: savedActive
                  ? saved?.isLoading == true || savedBusy
                        ? null
                        : () => ref.invalidate(savedPromptsProvider)
                  : state?.refreshing == true || state?.loadingMore == true
                  ? null
                  : () => ref.read(promptHistoryProvider.notifier).refresh(),
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: [
              Tab(text: t(ref, 'prompt.tab.stats')),
              Tab(text: t(ref, 'prompt.tab.saved')),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabs,
          children: [
            history.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => _errorView(),
              data: (value) => _stats(value),
            ),
            const SavedPromptsView(),
          ],
        ),
      ),
    );
  }

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t(ref, 'prompt.load_failed')),
          TextButton(
            onPressed: () => ref.read(promptHistoryProvider.notifier).refresh(),
            child: Text(t(ref, 'prompt.retry')),
          ),
        ],
      ),
    ),
  );

  Widget _stats(PromptHistoryState history) {
    if (history.error != null && history.events.isEmpty) return _errorView();
    final analysis = _analyze(history);
    final patterns = switch (_view) {
      'terms' => analysis.terms,
      'full' => analysis.fullPrompts,
      _ => analysis.phrases,
    };
    final sessions = analysis.prompts.map((event) => event.sessionKey).toSet();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(t(ref, 'prompt.scope')),
        if (history.lastRefreshedAt != null)
          Text(
            t(ref, 'prompt.checked', {
              'time': promptTimeLabel(history.lastRefreshedAt!),
            }),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: _filterWidth,
              child: DropdownButtonFormField<int>(
                isExpanded: true,
                key: const ValueKey('prompt-period'),
                initialValue: _days,
                decoration: InputDecoration(labelText: t(ref, 'prompt.period')),
                items: [
                  DropdownMenuItem(
                    value: 7,
                    child: Text(t(ref, 'prompt.period.week')),
                  ),
                  DropdownMenuItem(
                    value: 30,
                    child: Text(t(ref, 'prompt.period.month')),
                  ),
                  DropdownMenuItem(
                    value: 0,
                    child: Text(t(ref, 'prompt.period.all')),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _days = value ?? 7;
                  _patternLimit = _initialPatternLimit;
                }),
              ),
            ),
            SizedBox(
              width: _filterWidth,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                key: const ValueKey('prompt-source'),
                initialValue: _source ?? '',
                decoration: InputDecoration(labelText: t(ref, 'prompt.source')),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(t(ref, 'prompt.all_sources')),
                  ),
                  for (final source in _supportedFilters)
                    DropdownMenuItem(
                      value: source,
                      child: Text(promptSourceLabel(ref, source)),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _source = value == '' ? null : value;
                  _patternLimit = _initialPatternLimit;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('prompt-search'),
          controller: _searchController,
          onChanged: (value) {
            _searchDebounce?.cancel();
            _searchDebounce = Timer(_searchDelay, () {
              if (!mounted) return;
              setState(() {
                _query = value;
                _patternLimit = _initialPatternLimit;
              });
            });
          },
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: t(ref, 'prompt.search'),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final kind in ['phrases', 'terms', 'full'])
              ChoiceChip(
                label: Text(t(ref, 'prompt.$kind')),
                selected: _view == kind,
                onSelected: (_) => setState(() {
                  _view = kind;
                  _patternLimit = _initialPatternLimit;
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_source != 'antigravity')
          Text(
            t(ref, 'prompt.summary', {
              'prompts': '${analysis.prompts.length}',
              'sessions': '${sessions.length}',
              'loaded': '${history.scannedCount}',
            }),
          ),
        if (_query.trim().isNotEmpty) Text(t(ref, 'prompt.search_scope')),
        if (analysis.unsupportedSources.isNotEmpty)
          Text(
            t(ref, 'prompt.unsupported', {
              'sources': analysis.unsupportedSources.entries
                  .map(
                    (entry) =>
                        '${promptSourceLabel(ref, entry.key)} (${entry.value})',
                  )
                  .join(' · '),
            }),
          ),
        if (analysis.automaticMessageCount > 0)
          Text(
            t(ref, 'prompt.automatic_excluded', {
              'count': '${analysis.automaticMessageCount}',
            }),
          ),
        if (analysis.unreadableInputCount > 0)
          Text(
            t(ref, 'prompt.unreadable_excluded', {
              'count': '${analysis.unreadableInputCount}',
            }),
          ),
        Text(t(ref, 'prompt.top_limit', {'count': '$kPromptPatternLimit'})),
        if (analysis.missingContentCount > 0)
          Text(
            t(ref, 'prompt.missing', {
              'count': '${analysis.missingContentCount}',
            }),
          ),
        if (analysis.possibleTruncationCount > 0)
          Text(
            t(ref, 'prompt.truncation', {
              'count': '${analysis.possibleTruncationCount}',
            }),
          ),
        if (_source == 'antigravity') Text(t(ref, 'prompt.antigravity')),
        if (history.hasMore) Text(t(ref, 'prompt.partial')),
        if (history.error != null) ...[
          Text(t(ref, 'prompt.stale')),
          TextButton(
            onPressed: history.refreshing || history.loadingMore
                ? null
                : () => ref.read(promptHistoryProvider.notifier).refresh(),
            child: Text(t(ref, 'prompt.retry')),
          ),
        ],
        if (history.refreshing || history.loadingMore)
          const LinearProgressIndicator(),
        if (patterns.isEmpty && !history.refreshing)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              t(
                ref,
                _view == 'phrases' && analysis.prompts.isNotEmpty
                    ? 'prompt.empty_phrases'
                    : 'prompt.empty',
              ),
            ),
          ),
        for (final pattern in patterns.take(_patternLimit))
          PromptPatternCard(pattern: pattern),
        if (patterns.length > _patternLimit)
          TextButton(
            onPressed: () =>
                setState(() => _patternLimit += _initialPatternLimit),
            child: Text(t(ref, 'prompt.more_patterns')),
          ),
        if (history.hasMore)
          OutlinedButton.icon(
            onPressed: history.loadingMore || history.refreshing
                ? null
                : () => ref.read(promptHistoryProvider.notifier).loadOlder(),
            icon: const Icon(Icons.history),
            label: Text(t(ref, 'prompt.older')),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}
