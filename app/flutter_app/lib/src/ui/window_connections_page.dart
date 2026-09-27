import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/ui/widgets/window_connection_dialog.dart';
import 'package:my_dashboard/src/util/project_path.dart';

class WindowConnectionsPage extends ConsumerStatefulWidget {
  const WindowConnectionsPage({super.key});

  @override
  ConsumerState<WindowConnectionsPage> createState() => _WindowConnectionsPageState();
}

class _WindowConnectionsPageState extends ConsumerState<WindowConnectionsPage> {
  bool _busy = false;
  String? _error;

  Future<void> _edit(WindowConnectionKey key, WindowConnectionRule? rule) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scan = await ref.read(windowScanProvider)();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) =>
            WindowConnectionDialog(connectionKey: key, scan: scan, rule: rule, manageOnly: true),
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'window.failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(WindowConnectionKey key) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(windowConnectionsProvider.notifier).remove(key);
    } catch (_) {
      if (mounted) setState(() => _error = 'window.save_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final key = await showDialog<WindowConnectionKey>(
      context: context,
      builder: (_) => const _NewConnectionDialog(),
    );
    if (key == null || !mounted) return;
    final rules = ref.read(windowConnectionsProvider).asData?.value ?? [];
    await _edit(key, rules.where((rule) => rule.key == key).firstOrNull);
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(windowConnectionsProvider);
    final sessions = ref.watch(syncControllerProvider).sync.sessions.values;
    return Scaffold(
      appBar: AppBar(title: Text(t(ref, 'window.manage'))),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t(ref, 'window.load_failed')),
              TextButton(
                onPressed: () => ref.invalidate(windowConnectionsProvider),
                child: Text(t(ref, 'window.refresh')),
              ),
            ],
          ),
        ),
        data: (saved) {
          final keys = <WindowConnectionKey>{...saved.map((rule) => rule.key)};
          for (final session in sessions) {
            final key = WindowConnectionKey.fromSession(session);
            if (key != null) keys.add(key);
          }
          final ordered = keys.toList()
            ..sort((a, b) => '${a.host}\n${a.project}'.compareTo('${b.host}\n${b.project}'));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(t(ref, 'window.manage_note')),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.add),
                  label: Text(t(ref, 'window.add')),
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) Text(t(ref, _error!)),
              if (ordered.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(t(ref, 'window.no_connections')),
                ),
              for (final key in ordered)
                Builder(
                  builder: (context) {
                    final rule = saved.where((rule) => rule.key == key).firstOrNull;
                    return Card(
                      child: ListTile(
                        title: Text(
                          // i18n-exempt: 사용자 프로젝트와 호스트 표시명
                          '${projectBasename(key.project)} · ${key.host}',
                        ),
                        subtitle: Text(
                          // i18n-exempt: 사용자 경로와 저장한 창 제목 조건
                          '${key.project}\n${rule == null ? t(ref, 'window.unconnected') : '${rule.bundleId} · ${rule.titlePattern}'}',
                        ),
                        isThreeLine: true,
                        onTap: _busy ? null : () => _edit(key, rule),
                        trailing: rule == null
                            ? const Icon(Icons.link)
                            : IconButton(
                                tooltip: t(ref, 'window.disconnect'),
                                icon: const Icon(Icons.link_off),
                                onPressed: _busy ? null : () => _remove(key),
                              ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NewConnectionDialog extends ConsumerStatefulWidget {
  const _NewConnectionDialog();
  @override
  ConsumerState<_NewConnectionDialog> createState() => _NewConnectionDialogState();
}

class _NewConnectionDialogState extends ConsumerState<_NewConnectionDialog> {
  final _host = TextEditingController();
  final _project = TextEditingController();
  @override
  void dispose() {
    _host.dispose();
    _project.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t(ref, 'window.add')),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _host,
            decoration: InputDecoration(labelText: t(ref, 'window.host')),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _project,
            decoration: InputDecoration(labelText: t(ref, 'window.project')),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(t(ref, 'action.cancel')),
      ),
      FilledButton(
        onPressed: _host.text.trim().isEmpty || _project.text.trim().isEmpty
            ? null
            : () => Navigator.of(
                context,
              ).pop(WindowConnectionKey(host: _host.text, project: _project.text)),
        child: Text(t(ref, 'window.choose')),
      ),
    ],
  );
}
