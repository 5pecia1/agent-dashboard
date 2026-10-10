import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';
import 'package:my_dashboard/src/util/project_path.dart';

const double _progressSize = 18;
const double _dialogMaxWidth = 440;

/// 확인창을 열 때 삭제 대상과 서버 연결을 고정한다.
Future<void> showDeleteProjectSessionsDialog(
  BuildContext context,
  WidgetRef ref, {
  required String project,
  required List<SessionViewDto> sessions,
}) async {
  if (project.isEmpty || sessions.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final revision = ref
      .read(dashboardApiConfigControllerProvider.notifier)
      .revision;
  final targets = List<SessionViewDto>.unmodifiable(sessions);
  final message = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeleteProjectSessionsDialog(
      project: project,
      sessions: targets,
      connectionRevision: revision,
    ),
  );
  // 삭제하면서 프로젝트 헤더가 사라져도 결과는 목록의 Scaffold에 표시한다.
  if (message != null && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DeleteProjectSessionsDialog extends ConsumerStatefulWidget {
  const _DeleteProjectSessionsDialog({
    required this.project,
    required this.sessions,
    required this.connectionRevision,
  });

  final String project;
  final List<SessionViewDto> sessions;
  final int connectionRevision;

  @override
  ConsumerState<_DeleteProjectSessionsDialog> createState() =>
      _DeleteProjectSessionsDialogState();
}

class _DeleteProjectSessionsDialogState
    extends ConsumerState<_DeleteProjectSessionsDialog> {
  bool _deleting = false;

  @override
  Widget build(BuildContext context) {
    final hosts = {
      for (final session in widget.sessions)
        session.host?.isNotEmpty == true
            ? session.host!
            : t(ref, 'session.card.host_unknown'),
    }.toList()..sort();
    return PopScope(
      canPop: !_deleting,
      child: AlertDialog(
        scrollable: true,
        title: Text(t(ref, 'session.group.delete_title')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                projectBasename(widget.project),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(widget.project),
              const SizedBox(height: 8),
              Text(
                t(ref, 'session.group.delete_hosts', {
                  'hosts': hosts.join(', '),
                }),
              ),
              const SizedBox(height: 16),
              Text(
                t(ref, 'session.group.delete_body', {
                  'count': '${widget.sessions.length}',
                }),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: _deleting ? null : () => Navigator.of(context).pop(),
            child: Text(t(ref, 'action.cancel')),
          ),
          FilledButton(
            onPressed: _deleting ? null : _delete,
            child: _deleting
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: _progressSize,
                        height: _progressSize,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(t(ref, 'session.group.deleting')),
                    ],
                  )
                : Text(t(ref, 'session.group.delete_action')),
          ),
        ],
      ),
    );
  }

  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    final result = await ref
        .read(syncControllerProvider.notifier)
        .deleteSessions(
          widget.sessions.map((session) => session.key),
          expectedConnectionRevision: widget.connectionRevision,
        );
    if (!mounted) return;
    final message = result.connectionChanged
        ? tRead(ref, 'session.group.delete_connection_changed')
        : result.failedCount > 0
        ? tRead(ref, 'session.group.delete_partial', {
            'deleted': '${result.deletedCount}',
            'failed': '${result.failedCount}',
          })
        : tRead(ref, 'session.group.delete_success', {
            'count': '${result.deletedCount}',
          });
    // PopScope도 완료 상태로 되돌려 결과를 정상적으로 닫는다.
    setState(() => _deleting = false);
    Navigator.of(context).pop(message);
  }
}
