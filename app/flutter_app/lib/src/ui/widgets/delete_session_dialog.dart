/// 삭제 확인 다이얼로그 — 삭제 UI 사양이 요구하는 확인 단계 하나를
/// 세션 카드 hover ×([session_card.dart])와 세션 상세 화면 AppBar 삭제
/// 아이콘([session_detail_page.dart])이 함께 쓴다. 문구·버튼·동작이 두
/// 호출부에서 갈릴 이유가 없어(둘 다 같은 `DELETE /dashboard/sessions/
/// {key}`로 이어진다) 한 곳에 둔다 — 각자 따로 `showDialog`를 열면 문구가
/// 조용히 갈라질 위험이 있다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/i18n/t.dart';

/// 확인 다이얼로그를 띄우고 사용자가 삭제를 확정했는지 돌려준다.
///
/// 호출부는 build 단계가 아니라 아이콘의 `onPressed` 콜백이라 [t]가 아닌
/// [tRead]를 쓴다(`i18n/t.dart` 문서의 t/tRead 구분 — 다이얼로그는 한 번
/// 짓고 마는 화면이라 로케일 변경 구독이 필요 없다).
///
/// 다이얼로그 밖을 눌러 닫는 등 명시적 버튼 없이 닫히면 [showDialog]가
/// `null`을 돌려준다 — 취소와 같은 취급으로 `false`로 접는다.
Future<bool> showDeleteSessionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String projectLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tRead(ref, 'session.delete.dialog_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 프로젝트명 표시(삭제 UI 사양) — 이 다이얼로그가 지금 어느
          // 세션을 지우려는 것인지 확인시킨다. i18n 대상이 아니라 실제
          // 세션 데이터라 리터럴이 아닌 변수로 넘어온다.
          Text(
            projectLabel,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(tRead(ref, 'session.delete.dialog_body')),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(tRead(ref, 'action.cancel')),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(tRead(ref, 'session.delete.confirm_action')),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
