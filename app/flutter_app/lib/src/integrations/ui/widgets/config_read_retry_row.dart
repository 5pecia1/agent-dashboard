import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

/// 연동 패널이 저장된 설정을 읽지 못했을 때의 한 줄 안내와 "다시 시도".
///
/// 패널은 그동안 입력과 연결 버튼을 잠근다 — 빈 값으로 저장하면 저장된
/// 연결과 서버 자격증명이 지워진다(`state/config_provider.dart`의
/// `ConfigLoadFn` 계약). 자동으로 다시 읽지 않는다: 패널은 펼쳤을 때만
/// 보이고, 사용자가 고친 뒤 직접 누른다.
class ConfigReadRetryRow extends ConsumerWidget {
  const ConfigReadRetryRow({super.key, required this.onRetry});

  /// null이면 버튼이 꺼진다(다시 읽는 중).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            t(ref, 'config.read_failed.inline'),
            style: TextStyle(color: context.tokens.warn),
          ),
        ),
        TextButton(onPressed: onRetry, child: Text(t(ref, 'action.retry'))),
      ],
    ),
  );
}
