import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/prompt_analytics.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';
import 'package:my_dashboard/src/ui/widgets/prompt_dialogs.dart';

class PromptPatternCard extends ConsumerWidget {
  const PromptPatternCard({super.key, required this.pattern});
  final PromptPattern pattern;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              pattern.text,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (pattern.mayBeClipped)
              Text(
                t(ref, 'prompt.clipped'),
                style: TextStyle(color: tokens.warn),
              ),
            Text(
              t(ref, 'prompt.counts', {
                'submissions': '${pattern.submissionCount}',
                'sessions': '${pattern.sessionCount}',
                'occurrences': '${pattern.occurrenceCount}',
              }),
              style: TextStyle(color: tokens.fg2),
            ),
            Text(
              t(ref, 'prompt.last_used', {
                'time': promptTimeLabel(pattern.lastUsedAt),
              }),
              style: TextStyle(color: tokens.fg2),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => copyPromptText(context, ref, pattern.text),
                  icon: const Icon(Icons.copy_outlined),
                  label: Text(t(ref, 'prompt.copy')),
                ),
                TextButton.icon(
                  onPressed: () =>
                      showPromptEditor(context, text: pattern.text),
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(t(ref, 'prompt.save')),
                ),
                TextButton.icon(
                  onPressed: () => showPromptContext(context, pattern),
                  icon: const Icon(Icons.subject_outlined),
                  label: Text(t(ref, 'prompt.context')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
