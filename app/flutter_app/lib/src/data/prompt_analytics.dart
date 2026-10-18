import 'package:flutter/foundation.dart' show immutable;
import 'package:my_dashboard/src/data/dashboard_history.dart';
import 'package:my_dashboard/src/data/prompt_input_content.dart';

export 'package:my_dashboard/src/data/prompt_input_content.dart'
    show promptPreviewCharacterLimit;

const Set<String> supportedPromptSources = <String>{
  'claude-code',
  'codex',
  'devin',
  'grok',
  // OpenCode's plugin forwards the latest inbox text as the UserPromptSubmit
  // message with no source envelope, so it is analyzed as raw input.
  'opencode',
};
const int kPromptPatternLimit = 100;
const int kPromptPatternExamples = 3;
const int kPromptPatternVariants = 8;
const int _minimumPhraseWords = 2;
const int _maximumPhraseWords = 4;
const int _minimumRepeatedSubmissions = 2;

final RegExp _whitespace = RegExp(r'\s+', unicode: true);
final RegExp _words = RegExp(r'\S+', unicode: true);
final RegExp _lines = RegExp(r'[^\r\n]+');
final RegExp _lastToken = RegExp(r'\S+$', unicode: true);
final RegExp _wordContent = RegExp(r'[\p{L}\p{N}_]', unicode: true);
final RegExp _termWrappers = RegExp(
  r'''^["'“”‘’`()\[\]{},;]+|["'“”‘’`()\[\]{},;]+$''',
);
final RegExp _listPrefix = RegExp(
  r'^[ \t]*(?:\d+[.)]|[-•])[ \t]+',
  multiLine: true,
);
final RegExp _listMarkerOnly = RegExp(r'^(?:\d+[.)]|[-•])$');
final RegExp _terminalPunctuation = RegExp(r'\.+$');
final RegExp _technicalSyntaxMarkers = RegExp(r'[./\\:=`-]');
// Preserve ambiguous technical syntax rather than merging distinct paths,
// versions, options or shell commands by removing meaningful punctuation.
final RegExp _codeish = RegExp(
  r'[/\\:=`]|[\p{L}\p{N}]\.[\p{L}\p{N}]|(?:^|\s)\.{1,2}\p{L}|(?:^|\s)--?\p{L}',
  unicode: true,
);
final RegExp _commandPrefix = RegExp(
  r'^[ \t]*(?:git|npm|pnpm|yarn|mise|flutter|dart|bash|sh|zsh|python3?|uv|cargo|cd|ls|rg|curl|node|echo|printf)(?=\s|$)',
  multiLine: true,
);
final RegExp _koreanRequestSuffix = RegExp(
  r'^[A-Za-z0-9_\p{Script=Hangul}]*(?:줘|주세요)[.!?]*$',
  unicode: true,
);
final RegExp _literalArgumentCommandPrefix = RegExp(
  r'^(?:echo|printf)(?=\s|$)',
);
// A dot is a boundary only after a whitespace-delimited token, so internal
// dots in file names, versions and URLs stay in the same original span.
final RegExp _sentenceBoundary = RegExp(r'[.!?](?=\s|$)|\r?\n', unicode: true);

String _normalize(String text) => text.trim().replaceAll(_whitespace, ' ');

bool _isCommand(String text) {
  final line = text.replaceAll(_listPrefix, '').trim();
  if (!_commandPrefix.hasMatch(line)) return false;
  // A Hangul/identifier token ending in a request suffix is a prose heuristic,
  // not an intent parser. Quotes, backticks, paths and options fail that grammar.
  // Unquoted CLI arguments can still be ambiguous; output commands stay literal.
  if (_literalArgumentCommandPrefix.hasMatch(line)) return true;
  final lastToken = _lastToken.firstMatch(line)?.group(0) ?? line;
  return !_koreanRequestSuffix.hasMatch(lastToken);
}

bool _hasTechnicalSyntax(String text) =>
    _technicalSyntaxMarkers.hasMatch(text) && _codeish.hasMatch(text);

({String key, int start, int end})? _expressionSpan(
  String raw, {
  bool preservePunctuation = false,
}) {
  var body = raw.trim();
  if (body.isEmpty || _listMarkerOnly.hasMatch(body)) return null;
  var start = raw.indexOf(body);
  var end = start + body.length;
  final marker = _listPrefix.matchAsPrefix(body);
  if (marker != null) {
    start += marker.end;
    body = body.substring(marker.end);
  }
  if (!preservePunctuation) {
    final punctuation = _terminalPunctuation.firstMatch(body);
    if (punctuation != null) {
      final lastToken = _lastToken.firstMatch(body)?.group(0) ?? body;
      if (!_hasTechnicalSyntax(lastToken)) end = start + punctuation.start;
    }
  }
  final key = _normalize(raw.substring(start, end));
  return key.isEmpty || !_wordContent.hasMatch(key)
      ? null
      : (key: key, start: start, end: end);
}

@immutable
class PromptPattern {
  PromptPattern({
    required this.text,
    required this.normalizedKey,
    required this.submissionCount,
    required this.occurrenceCount,
    required this.sessionCount,
    required this.lastUsedAt,
    this.mayBeClipped = false,
    List<DashboardHistoryEvent> examples = const <DashboardHistoryEvent>[],
    List<String> variants = const <String>[],
  }) : examples = List<DashboardHistoryEvent>.unmodifiable(examples),
       variants = List<String>.unmodifiable(
         variants.isEmpty ? <String>[text] : variants,
       );

  /// An actual input span, decoded when wrapped by its source. Grouping
  /// normalization is never used as clipboard content.
  final String text;
  final String normalizedKey;
  final int submissionCount;
  final int occurrenceCount;
  final int sessionCount;
  final int lastUsedAt;

  /// At least one contributing input span touches a possibly clipped body end.
  /// This is a warning, not proof that text was truncated.
  final bool mayBeClipped;
  final List<DashboardHistoryEvent> examples;
  final List<String> variants;
}

@immutable
class PromptAnalysis {
  PromptAnalysis({
    List<DashboardHistoryEvent> prompts = const <DashboardHistoryEvent>[],
    List<PromptPattern> terms = const <PromptPattern>[],
    List<PromptPattern> phrases = const <PromptPattern>[],
    List<PromptPattern> fullPrompts = const <PromptPattern>[],
    this.missingContentCount = 0,
    this.automaticMessageCount = 0,
    this.unreadableInputCount = 0,
    this.possibleTruncationCount = 0,
    this.observedEventsCount = 0,
    Map<String, int> unsupportedSources = const <String, int>{},
  }) : prompts = List<DashboardHistoryEvent>.unmodifiable(prompts),
       terms = List<PromptPattern>.unmodifiable(terms),
       phrases = List<PromptPattern>.unmodifiable(phrases),
       fullPrompts = List<PromptPattern>.unmodifiable(fullPrompts),
       unsupportedSources = Map<String, int>.unmodifiable(unsupportedSources);

  final List<DashboardHistoryEvent> prompts;
  final List<PromptPattern> terms;
  final List<PromptPattern> phrases;
  final List<PromptPattern> fullPrompts;
  final int missingContentCount;
  final int automaticMessageCount;
  final int unreadableInputCount;
  final int possibleTruncationCount;
  final int observedEventsCount;
  final Map<String, int> unsupportedSources;
}

/// Counts saved user submissions, not transport retries or inferred intent.
/// Periods are [since, until). Textually identical rows with different IDs count
/// separately. Unsupported and synthesized sources never enter the corpus.
/// Search filters returned patterns after counting the complete selected corpus.
PromptAnalysis analyzePrompts(
  Iterable<DashboardHistoryEvent> events, {
  String? source,
  int? since,
  int? until,
  String query = '',
}) {
  final unique = <int, DashboardHistoryEvent>{};
  for (final event in events) {
    unique.putIfAbsent(event.id, () => event);
  }
  final observed = unique.values.where(
    (event) =>
        event.isUserPrompt &&
        (source == null || event.source == source) &&
        (since == null || event.receivedAt >= since) &&
        (until == null || event.receivedAt < until),
  );
  final prompts = <DashboardHistoryEvent>[];
  var missingContentCount = 0;
  var automaticMessageCount = 0;
  var unreadableInputCount = 0;
  var observedEventsCount = 0;
  var possibleTruncationCount = 0;
  final unsupportedSources = <String, int>{};
  final search = _normalize(query).toLowerCase();
  final content = <int, PromptInputContent>{};
  for (final event in observed) {
    observedEventsCount++;
    if (!supportedPromptSources.contains(event.source)) {
      unsupportedSources.update(
        event.source,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      continue;
    }
    final message = event.message;
    if (message == null || message.trim().isEmpty) {
      missingContentCount++;
      continue;
    }
    final input = inspectPromptInput(event);
    if (input.automatic) {
      automaticMessageCount++;
      continue;
    }
    if (input.unreadable) {
      unreadableInputCount++;
      continue;
    }
    if (input.text == null || input.text!.trim().isEmpty) {
      missingContentCount++;
      continue;
    }
    prompts.add(event);
    content[event.id] = input;
    if (input.mayBeClipped) {
      possibleTruncationCount++;
    }
  }
  prompts.sort((a, b) {
    final time = b.receivedAt.compareTo(a.receivedAt);
    return time == 0 ? b.id.compareTo(a.id) : time;
  });
  final terms = <String, _PatternCount>{};
  final phrases = <String, _PatternCount>{};
  final fullPrompts = <String, _PatternCount>{};
  for (final event in prompts) {
    final input = content[event.id]!;
    final message = input.text!;
    final termSpans = <String, _Occurrences>{};
    for (final line in _lines.allMatches(message)) {
      final lineText = line.group(0)!;
      final commandContext = _isCommand(lineText);
      for (final match in _words.allMatches(lineText)) {
        final raw = match.group(0)!;
        final term = commandContext ? raw : raw.replaceAll(_termWrappers, '');
        if (_wordContent.hasMatch(term)) {
          final start = line.start + match.start + raw.indexOf(term);
          _addSpan(
            termSpans,
            term,
            start,
            start + term.length,
            preservePunctuation: commandContext,
          );
        }
      }
    }
    _addSubmission(terms, termSpans, event, input, search);
    final phraseSpans = <String, _Occurrences>{};
    var sentenceStart = 0;
    final listMarkers = _listPrefix.allMatches(message).toList();
    for (final boundary in _sentenceBoundary.allMatches(message)) {
      if (listMarkers.any(
        (marker) =>
            boundary.start >= marker.start && boundary.end <= marker.end,
      )) {
        continue;
      }
      final end = boundary.group(0)!.contains('\n')
          ? boundary.start
          : boundary.end;
      _addPhraseSpans(phraseSpans, message, sentenceStart, end);
      sentenceStart = boundary.end;
    }
    _addPhraseSpans(phraseSpans, message, sentenceStart, message.length);
    _addSubmission(phrases, phraseSpans, event, input, search);
    _addSubmission(
      fullPrompts,
      <String, _Occurrences>{
        _normalize(message): _Occurrences(message)..add(0, message.length),
      },
      event,
      input,
      search,
    );
  }
  return PromptAnalysis(
    prompts: prompts,
    terms: _rank(terms, minimumSubmissions: 1),
    phrases: _rank(phrases, suppressContained: true),
    fullPrompts: _rank(fullPrompts, minimumSubmissions: 1),
    missingContentCount: missingContentCount,
    automaticMessageCount: automaticMessageCount,
    unreadableInputCount: unreadableInputCount,
    possibleTruncationCount: possibleTruncationCount,
    observedEventsCount: observedEventsCount,
    unsupportedSources: unsupportedSources,
  );
}

void _addPhraseSpans(
  Map<String, _Occurrences> target,
  String text,
  int start,
  int end,
) {
  final segment = text.substring(start, end);
  final matches = _words.allMatches(segment).toList();
  if (matches.isEmpty) return;
  // Leading/trailing whitespace is not a phrase, but internal spacing is kept.
  final first = start + matches.first.start;
  final last = start + matches.last.end;
  final commandContext = _isCommand(segment);
  _addSpan(
    target,
    text.substring(first, last),
    first,
    last,
    preservePunctuation: commandContext,
  );
  for (var index = 0; index < matches.length; index++) {
    for (var size = _minimumPhraseWords; size <= _maximumPhraseWords; size++) {
      if (index + size > matches.length) break;
      final spanStart = start + matches[index].start;
      final spanEnd = start + matches[index + size - 1].end;
      _addSpan(
        target,
        text.substring(spanStart, spanEnd),
        spanStart,
        spanEnd,
        preservePunctuation: commandContext,
      );
    }
  }
}

void _addSpan(
  Map<String, _Occurrences> target,
  String raw,
  int start,
  int end, {
  bool preservePunctuation = false,
}) {
  final expression = _expressionSpan(
    raw,
    preservePunctuation: preservePunctuation,
  );
  if (expression == null) return;
  // A list-prefixed sentence and its body n-gram identify the same occurrence.
  // Keep the original copy variant/end separately from those canonical bounds.
  target
      .putIfAbsent(expression.key, () => _Occurrences(raw))
      .add(
        start + expression.start,
        start + expression.end,
        rawEnd: end,
        variant: raw,
      );
}

class _Occurrences {
  _Occurrences(this.raw);
  final String raw;
  final Set<(int, int)> spans = <(int, int)>{};
  final Set<String> rawVariants = <String>{};
  int furthestEnd = 0;
  void add(int start, int end, {int? rawEnd, String? variant}) {
    spans.add((start, end));
    rawVariants.add(variant ?? raw);
    final spanEnd = rawEnd ?? end;
    if (spanEnd > furthestEnd) furthestEnd = spanEnd;
  }
}

class _PatternCount {
  _PatternCount(this.raw, this.key);
  final String raw;
  final String key;
  int occurrenceCount = 0;
  int lastUsedAt = 0;
  bool mayBeClipped = false;
  bool matchesQuery = false;
  final List<int> eventIds = <int>[];
  final Set<String> sessions = <String>{};
  final List<DashboardHistoryEvent> examples = <DashboardHistoryEvent>[];
  final Set<String> variants = <String>{};

  void add(
    _Occurrences occurrences,
    DashboardHistoryEvent event,
    PromptInputContent input,
    String query,
  ) {
    occurrenceCount += occurrences.spans.length;
    eventIds.add(event.id);
    sessions.add(event.sessionKey);
    if (event.receivedAt > lastUsedAt) lastUsedAt = event.receivedAt;
    if (examples.length < kPromptPatternExamples) examples.add(event);
    if (!matchesQuery && (query.isEmpty || key.toLowerCase().contains(query))) {
      matchesQuery = true;
    }
    for (final variant in occurrences.rawVariants) {
      if (variants.length < kPromptPatternVariants) variants.add(variant);
      if (!matchesQuery && _normalize(variant).toLowerCase().contains(query)) {
        matchesQuery = true;
      }
    }
    if (input.mayBeClipped && occurrences.furthestEnd == input.text!.length) {
      mayBeClipped = true;
    }
  }

  PromptPattern toPattern() => PromptPattern(
    text: raw,
    normalizedKey: key,
    submissionCount: eventIds.length,
    occurrenceCount: occurrenceCount,
    sessionCount: sessions.length,
    lastUsedAt: lastUsedAt,
    mayBeClipped: mayBeClipped,
    examples: examples,
    variants: variants.toList(),
  );
}

void _addSubmission(
  Map<String, _PatternCount> totals,
  Map<String, _Occurrences> spans,
  DashboardHistoryEvent event,
  PromptInputContent input,
  String query,
) {
  for (final entry in spans.entries) {
    totals
        .putIfAbsent(entry.key, () => _PatternCount(entry.value.raw, entry.key))
        .add(entry.value, event, input, query);
  }
}

List<PromptPattern> _rank(
  Map<String, _PatternCount> counts, {
  int minimumSubmissions = _minimumRepeatedSubmissions,
  bool suppressContained = false,
}) {
  final candidates =
      counts.values
          .where(
            (candidate) =>
                candidate.eventIds.length >= minimumSubmissions &&
                candidate.matchesQuery,
          )
          .toList()
        ..sort((a, b) {
          var result = b.eventIds.length.compareTo(a.eventIds.length);
          if (result == 0) result = b.key.length.compareTo(a.key.length);
          if (result == 0) result = b.lastUsedAt.compareTo(a.lastUsedAt);
          return result == 0 ? a.key.compareTo(b.key) : result;
        });
  final selected = <_PatternCount>[];
  for (final candidate in candidates) {
    if (suppressContained &&
        selected.any((longer) {
          if (longer.eventIds.length != candidate.eventIds.length ||
              !_containsTokenSequence(longer.key, candidate.key)) {
            return false;
          }
          for (var index = 0; index < longer.eventIds.length; index++) {
            if (longer.eventIds[index] != candidate.eventIds[index]) {
              return false;
            }
          }
          return true;
        })) {
      continue;
    }
    selected.add(candidate);
    if (selected.length == kPromptPatternLimit) break;
  }
  return selected.map((count) => count.toPattern()).toList();
}

bool _containsTokenSequence(String longer, String shorter) {
  final longTokens = longer.split(' ');
  final shortTokens = shorter.split(' ');
  for (
    var start = 0;
    start + shortTokens.length <= longTokens.length;
    start++
  ) {
    var matches = true;
    for (var index = 0; index < shortTokens.length; index++) {
      if (longTokens[start + index] != shortTokens[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
