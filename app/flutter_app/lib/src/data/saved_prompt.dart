import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, listEquals;

const savedPromptMaxTextLength = 16384;
const savedPromptMaxTitleLength = 200;
const savedPromptMaxItems = 500;
const savedPromptsSchemaVersion = 1;

class SavedPromptsConflictException extends StateError {
  SavedPromptsConflictException()
    : super('Saved prompts changed elsewhere; reload before saving');
}

/// 이 기기나 브라우저에 보관하는 원문이다. 서버 자격증명은 저장하지 않는다.
@immutable
class SavedPrompt {
  factory SavedPrompt({
    required String id,
    required String title,
    required String text,
    required int createdAt,
    required int updatedAt,
    String? source,
    String? sessionKey,
  }) {
    if (id.trim().isEmpty || text.trim().isEmpty) {
      throw const FormatException('Saved prompt ID and text must not be blank');
    }
    if (text.length > savedPromptMaxTextLength ||
        title.trim().length > savedPromptMaxTitleLength) {
      throw const FormatException('Saved prompt exceeds the size limit');
    }
    if (createdAt < 0 || updatedAt < createdAt) {
      throw const FormatException('Invalid saved prompt timestamps');
    }
    return SavedPrompt._(
      id,
      title.trim(),
      text,
      createdAt,
      updatedAt,
      source,
      sessionKey,
    );
  }

  const SavedPrompt._(
    this.id,
    this.title,
    this.text,
    this.createdAt,
    this.updatedAt,
    this.source,
    this.sessionKey,
  );

  final String id;
  final String title;
  final String text;
  final int createdAt;
  final int updatedAt;
  final String? source;
  final String? sessionKey;

  factory SavedPrompt.fromJson(Map<Object?, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    final text = json['text'];
    final createdAt = json['createdAt'];
    final updatedAt = json['updatedAt'];
    final source = json['source'];
    final sessionKey = json['sessionKey'];
    if (id is! String ||
        title is! String ||
        text is! String ||
        createdAt is! int ||
        updatedAt is! int ||
        (source != null && source is! String) ||
        (sessionKey != null && sessionKey is! String)) {
      throw const FormatException('Invalid saved prompt entry');
    }
    return SavedPrompt(
      id: id,
      title: title,
      text: text,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: source as String?,
      sessionKey: sessionKey as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'text': text,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (source != null) 'source': source,
    if (sessionKey != null) 'sessionKey': sessionKey,
  };

  SavedPrompt copyWith({String? title, String? text, int? updatedAt}) =>
      SavedPrompt(
        id: id,
        title: title ?? this.title,
        text: text ?? this.text,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        source: source,
        sessionKey: sessionKey,
      );

  @override
  bool operator ==(Object other) =>
      other is SavedPrompt &&
      id == other.id &&
      title == other.title &&
      text == other.text &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt &&
      source == other.source &&
      sessionKey == other.sessionKey;

  @override
  int get hashCode =>
      Object.hash(id, title, text, createdAt, updatedAt, source, sessionKey);
}

/// 파일과 웹 저장소는 같은 버전과 검증 규칙을 사용한다.
List<SavedPrompt> decodeSavedPrompts(String text) {
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map<String, Object?> ||
      decoded['version'] is! int ||
      decoded['version'] != savedPromptsSchemaVersion) {
    throw const FormatException('Unsupported saved prompts format');
  }
  final rawPrompts = decoded['prompts'];
  if (rawPrompts is! List<Object?>) {
    throw const FormatException('Invalid saved prompts list');
  }
  final prompts = <SavedPrompt>[];
  for (final entry in rawPrompts) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException('Invalid saved prompt entry');
    }
    prompts.add(SavedPrompt.fromJson(entry));
  }
  validateSavedPrompts(prompts);
  return List.unmodifiable(prompts);
}

String encodeSavedPrompts(List<SavedPrompt> prompts) {
  validateSavedPrompts(prompts);
  return jsonEncode({
    'version': savedPromptsSchemaVersion,
    'prompts': [for (final prompt in prompts) prompt.toJson()],
  });
}

void validateSavedPrompts(List<SavedPrompt> prompts) {
  if (prompts.length > savedPromptMaxItems) {
    throw const FormatException('Saved prompt library is full');
  }
  final ids = <String>{};
  for (final prompt in prompts) {
    if (!ids.add(prompt.id)) {
      throw const FormatException('Duplicate saved prompt ID');
    }
  }
}

void validateSavedPromptsSnapshot(
  List<SavedPrompt> expected,
  List<SavedPrompt> current,
) {
  if (!listEquals(expected, current)) throw SavedPromptsConflictException();
}
