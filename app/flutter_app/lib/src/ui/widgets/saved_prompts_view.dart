import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/saved_prompt.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/saved_prompts_provider.dart';
import 'package:my_dashboard/src/ui/widgets/prompt_dialogs.dart';

class SavedPromptsView extends ConsumerStatefulWidget {
  const SavedPromptsView({super.key});
  @override
  ConsumerState<SavedPromptsView> createState() => _SavedPromptsViewState();
}

class _SavedPromptsViewState extends ConsumerState<SavedPromptsView> {
  String _query = '';
  bool _busy = false;
  String? _errorKey;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _remove(SavedPrompt saved) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(ref, 'prompt.delete_title')),
        content: Text(t(ref, 'prompt.delete_note')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t(ref, 'action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t(ref, 'prompt.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      await ref.read(savedPromptsProvider.notifier).remove(saved.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tRead(ref, 'prompt.deleted'))));
      }
    } on SavedPromptsConflictException {
      ref.invalidate(savedPromptsProvider);
      if (mounted) setState(() => _errorKey = 'prompt.conflict');
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'prompt.change_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(savedPromptsProvider);
    return saved.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t(ref, 'prompt.saved_load_failed')),
              TextButton(
                onPressed: () => ref.invalidate(savedPromptsProvider),
                child: Text(t(ref, 'prompt.retry')),
              ),
            ],
          ),
        ),
      ),
      data: (items) {
        final query = _query.trim().toLowerCase();
        final filtered =
            items
                .where(
                  (item) =>
                      query.isEmpty ||
                      item.text.toLowerCase().contains(query) ||
                      item.title.toLowerCase().contains(query),
                )
                .toList()
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(t(ref, 'prompt.saved_note')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  t(ref, 'prompt.saved_count', {'count': '${items.length}'}),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : () => showPromptEditor(context),
                  icon: const Icon(Icons.add),
                  label: Text(t(ref, 'prompt.new')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('saved-prompts-search'),
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: t(ref, 'prompt.search'),
              ),
            ),
            if (_errorKey != null) Text(t(ref, _errorKey!)),
            if (_busy) const LinearProgressIndicator(),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(t(ref, 'prompt.saved_empty')),
              ),
            for (final item in filtered)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title.isEmpty
                            ? t(ref, 'prompt.untitled')
                            : item.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(item.text),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                copyPromptText(context, ref, item.text),
                            icon: const Icon(Icons.copy_outlined),
                            label: Text(t(ref, 'prompt.copy')),
                          ),
                          TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => showPromptEditor(context, saved: item),
                            icon: const Icon(Icons.edit_outlined),
                            label: Text(t(ref, 'prompt.edit')),
                          ),
                          TextButton.icon(
                            onPressed: _busy ? null : () => _remove(item),
                            icon: const Icon(Icons.delete_outline),
                            label: Text(t(ref, 'prompt.delete')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
