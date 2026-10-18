import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:my_dashboard/src/data/dashboard_history.dart';

const int promptPreviewCharacterLimit = 300;
const String _claudeSource = 'claude-code';
const String _codexSource = 'codex';
const String _systemNotification = '[SYSTEM NOTIFICATION - NOT USER INPUT]';
const String _taskClose = '</task-notification>';
const String _pasteClose = '</pasted_content>';
const String _partialPasteClosePrefix = '</pasted_';
const String _replyOpen = '<send_user_message_question_reply>';
const String _replyClose = '</send_user_message_question_reply>';
const Set<String> _replyKeys = <String>{'answer', 'question', 'questionItemId'};
const List<String> _codexAmbientPromptHeads = <String>[
  'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.\n\n'
      'I will present you with two categories of content:',
  '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what '
      'this user can do with Codex in this Projectless task\n\n',
  '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what '
      'this user can do with Codex in this local project: ',
];

// A tag mention or arbitrary XML is not enough to establish machine authorship.
// These prefixes match the source-specific envelopes verified in collected rows.
final RegExp _taskPrefix = RegExp(
  r'^<task-notification>\s*<task-id>[^<>]+</task-id>\s*'
  r'<(?:tool-use-id|output-file|status|summary)>',
);
final RegExp _pasteOpen = RegExp(r'^<pasted_content id="[0-9a-fA-F]{4}">');
final RegExp _leadingReplyShape = RegExp(
  r'^\s*\[\s*\{\s*"(?:answer|question|questionItemId)"\s*:\s*',
);

@immutable
class PromptInputContent {
  const PromptInputContent({
    required this.text,
    this.automatic = false,
    this.unreadable = false,
    this.mayBeClipped = false,
  });

  /// The input content used for analysis and copying. The event itself
  /// remains unchanged, including source wrappers and automatic notifications.
  final String? text;
  final bool automatic;
  final bool unreadable;

  /// An analyzed body reaches the saved raw boundary. A complete decoded answer
  /// or a closed paste body does not inherit clipping from envelope metadata.
  final bool mayBeClipped;
}

/// Inspect source-specific automatic messages and known root input envelopes.
/// Content pasted by a user is unwrapped once and is never reclassified.
PromptInputContent inspectPromptInput(DashboardHistoryEvent event) {
  final raw = event.message;
  if (raw == null) return const PromptInputContent(text: null);
  final root = raw.trimLeft();
  if (event.source == _claudeSource) {
    if (root.startsWith(_systemNotification) ||
        (_taskPrefix.hasMatch(root) && !_hasHumanTail(root, _taskClose))) {
      return const PromptInputContent(text: null, automatic: true);
    }
    final paste = _pasteOpen.matchAsPrefix(root);
    if (paste != null) {
      final body = root.substring(paste.end);
      if (raw.length >= promptPreviewCharacterLimit) {
        final fragment = body.lastIndexOf(_partialPasteClosePrefix);
        if (fragment >= 0 &&
            body.length - fragment < _pasteClose.length &&
            _pasteClose.startsWith(body.substring(fragment))) {
          return PromptInputContent(
            text: body.substring(0, fragment),
            mayBeClipped: true,
          );
        }
      }
      final close = root.lastIndexOf(_pasteClose);
      if (close < 0) {
        return PromptInputContent(
          text: body,
          mayBeClipped: raw.length >= promptPreviewCharacterLimit,
        );
      }
      final tail = root.substring(close + _pasteClose.length);
      return PromptInputContent(
        text: root.substring(paste.end, close) + tail,
        mayBeClipped:
            tail.trim().isNotEmpty && raw.length >= promptPreviewCharacterLimit,
      );
    }
  } else if (event.source == _codexSource) {
    if (_codexAmbientPromptHeads.any(root.startsWith)) {
      return const PromptInputContent(text: null, automatic: true);
    }
    if (root.startsWith(_replyOpen)) return _inspectReply(raw, root);
  }
  return _rawInput(raw);
}

PromptInputContent _rawInput(String raw) => PromptInputContent(
  text: raw,
  mayBeClipped: raw.length >= promptPreviewCharacterLimit,
);

bool _hasHumanTail(String root, String closingTag) {
  final close = root.indexOf(closingTag);
  return close >= 0 &&
      root.substring(close + closingTag.length).trim().isNotEmpty;
}

PromptInputContent _inspectReply(String raw, String root) {
  var payload = root.substring(_replyOpen.length);
  // A closing tag inside a JSON answer is literal input. An outer boundary is
  // confirmed only when the preceding complete JSON has the known schema.
  var close = payload.indexOf(_replyClose);
  while (close >= 0) {
    final answers = _tryDecodeReply(payload.substring(0, close));
    if (answers != null) {
      return payload.substring(close + _replyClose.length).trim().isNotEmpty
          ? _rawInput(raw)
          : PromptInputContent(text: answers);
    }
    close = payload.indexOf(_replyClose, close + _replyClose.length);
  }
  if (payload.trimRight().endsWith(_replyClose)) {
    payload = payload.substring(0, payload.lastIndexOf(_replyClose));
  } else if (raw.length >= promptPreviewCharacterLimit) {
    final fragment = payload.lastIndexOf('</');
    if (fragment >= 0 && _replyClose.startsWith(payload.substring(fragment))) {
      payload = payload.substring(0, fragment);
    }
  }
  final unknownOrUnreadable = _leadingReplyShape.hasMatch(payload)
      ? _unreadableReply
      : _rawInput(raw);
  try {
    final answers = _decodeReply(payload);
    return answers == null ? _rawInput(raw) : PromptInputContent(text: answers);
  } on FormatException {
    // A complete first answer does not prove that later answers survived.
    // Keep unknown schemas literal; disclose recognized unreadable replies.
    return unknownOrUnreadable;
  }
}

String? _tryDecodeReply(String payload) {
  try {
    return _decodeReply(payload);
  } on FormatException {
    return null;
  }
}

String? _decodeReply(String payload) {
  final decoded = jsonDecode(payload);
  if (decoded is! List || decoded.isEmpty) return null;
  final answers = <String>[];
  for (final item in decoded) {
    if (item is! Map ||
        item.length != _replyKeys.length ||
        !_replyKeys.every((key) => item[key] is String)) {
      return null;
    }
    answers.add(item['answer'] as String);
  }
  return answers.join('\n');
}

const PromptInputContent _unreadableReply = PromptInputContent(
  text: null,
  unreadable: true,
);
