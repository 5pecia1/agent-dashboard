import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/prompt_analytics.dart';
import 'package:my_dashboard/src/data/prompt_input_content.dart';
import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/saved_prompts_provider.dart';

const _dialogWidth = 640.0;
const _editorMinLines = 4;
const _editorMaxLines = 10;

String promptTimeLabel(int epochMs) {
  final value = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
  String pair(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${pair(value.month)}-${pair(value.day)} '
      '${pair(value.hour)}:${pair(value.minute)}';
}

String promptSourceLabel(WidgetRef ref, String source) =>
    !{...supportedPromptSources, 'antigravity', 'generic'}.contains(source)
    ? source
    : t(
        ref,
        'session.source.${source == 'claude-code' ? 'claude_code' : source}',
      );

Future<void> copyPromptText(
  BuildContext context,
  WidgetRef ref,
  String text,
) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tRead(ref, 'prompt.copied'))));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tRead(ref, 'prompt.copy_failed'))));
    }
  }
}

Future<void> showPromptEditor(
  BuildContext context, {
  String text = '',
  String? source,
  String? sessionKey,
  SavedPrompt? saved,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PromptEditor(
    text: text,
    source: source,
    sessionKey: sessionKey,
    saved: saved,
  ),
);

Future<void> showPromptContext(BuildContext context, PromptPattern pattern) =>
    showDialog<void>(
      context: context,
      builder: (_) => _PromptContext(pattern: pattern),
    );

class _PromptEditor extends ConsumerStatefulWidget {
  const _PromptEditor({
    required this.text,
    this.source,
    this.sessionKey,
    this.saved,
  });
  final String text;
  final String? source;
  final String? sessionKey;
  final SavedPrompt? saved;

  @override
  ConsumerState<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends ConsumerState<_PromptEditor> {
  late final TextEditingController _title;
  late final TextEditingController _text;
  bool _busy = false;
  String? _errorKey;
  bool _editConflict = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.saved?.title ?? '');
    _text = TextEditingController(text: widget.saved?.text ?? widget.text);
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_text.text.trim().isEmpty ||
        _text.text.length > savedPromptMaxTextLength ||
        _title.text.length > savedPromptMaxTitleLength) {
      setState(() => _errorKey = 'prompt.editor.invalid');
      return;
    }
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      final controller = ref.read(savedPromptsProvider.notifier);
      final saved = widget.saved;
      if (saved == null) {
        await controller.create(
          text: _text.text,
          title: _title.text,
          source: widget.source,
          sessionKey: widget.sessionKey,
        );
      } else {
        await controller.upsert(
          saved.copyWith(
            title: _title.text,
            text: _text.text,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tRead(ref, 'prompt.saved'))));
    } on SavedPromptsConflictException {
      ref.invalidate(savedPromptsProvider);
      if (mounted) {
        setState(() {
          _editConflict = widget.saved != null;
          _errorKey = _editConflict
              ? 'prompt.edit_conflict'
              : 'prompt.conflict';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'prompt.save_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t(ref, widget.saved == null ? 'prompt.save' : 'prompt.edit')),
    content: SizedBox(
      width: _dialogWidth,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t(ref, 'prompt.saved_note')),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('prompt-editor-title'),
              controller: _title,
              enabled: !_busy,
              maxLength: savedPromptMaxTitleLength,
              decoration: InputDecoration(
                labelText: t(ref, 'prompt.editor.title'),
              ),
            ),
            TextField(
              key: const ValueKey('prompt-editor-text'),
              controller: _text,
              enabled: !_busy,
              minLines: _editorMinLines,
              maxLines: _editorMaxLines,
              maxLength: savedPromptMaxTextLength,
              decoration: InputDecoration(
                labelText: t(ref, 'prompt.editor.text'),
              ),
            ),
            if (_errorKey != null)
              Text(
                t(ref, _errorKey!, {'limit': '$savedPromptMaxTextLength'}),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (_editConflict)
        TextButton.icon(
          onPressed: () => copyPromptText(context, ref, _text.text),
          icon: const Icon(Icons.copy_outlined),
          label: Text(t(ref, 'prompt.copy')),
        ),
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: Text(t(ref, 'action.cancel')),
      ),
      FilledButton(
        onPressed: _busy || _editConflict ? null : _save,
        child: _busy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(t(ref, 'action.save')),
      ),
    ],
  );
}

class _PromptContext extends ConsumerWidget {
  const _PromptContext({required this.pattern});
  final PromptPattern pattern;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final examples = [
      for (final event in pattern.examples)
        (event: event, input: inspectPromptInput(event)),
    ];
    return AlertDialog(
      title: Text(t(ref, 'prompt.examples')),
      content: SizedBox(
        width: _dialogWidth,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: ListView(
          children: [
            Text(t(ref, 'prompt.stored_note')),
            ...[
              const SizedBox(height: 16),
              Text(t(ref, 'prompt.variants')),
              for (final variant in pattern.variants)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(variant),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  copyPromptText(context, ref, variant),
                              icon: const Icon(Icons.copy_outlined),
                              label: Text(t(ref, 'prompt.copy')),
                            ),
                            TextButton.icon(
                              onPressed: () =>
                                  showPromptEditor(context, text: variant),
                              icon: const Icon(Icons.bookmark_add_outlined),
                              label: Text(t(ref, 'prompt.save')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            for (final example in examples)
              if (example.input.text != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // i18n-exempt: translated agent label with a numeric local timestamp.
                          '${promptSourceLabel(ref, example.event.source)} · '
                          '${promptTimeLabel(example.event.receivedAt)}',
                        ),
                        if (example.event.displayTitle?.isNotEmpty ?? false)
                          Text(example.event.displayTitle!),
                        const SizedBox(height: 8),
                        SelectableText(example.input.text!),
                        if (example.input.mayBeClipped)
                          Text(t(ref, 'prompt.clipped')),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () => copyPromptText(
                                context,
                                ref,
                                example.input.text!,
                              ),
                              icon: const Icon(Icons.copy_outlined),
                              label: Text(t(ref, 'prompt.copy_input')),
                            ),
                            TextButton.icon(
                              onPressed: () => showPromptEditor(
                                context,
                                text: example.input.text!,
                                source: example.event.source,
                                sessionKey: example.event.sessionKey,
                              ),
                              icon: const Icon(Icons.bookmark_add_outlined),
                              label: Text(t(ref, 'prompt.save')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t(ref, 'prompt.close')),
        ),
      ],
    );
  }
}
