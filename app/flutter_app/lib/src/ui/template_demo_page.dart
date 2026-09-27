/// 스캐폴드 원본의 템플릿 인사말/capability 데모 화면 (T-wire로 강등).
///
/// T15 이전에는 이 화면이 [SolApp]의 홈이었다 — 이 템플릿의 세 기반 조각
/// (테마 토큰, i18n 어댑터, FFI capability 시임)을 한 화면에서 확인할 수
/// 있는 최소 예시였다. T-wire가 홈을 `sessions_page.dart`(T15)로 바꾸면서
/// 이 화면은 삭제 대신 진단 화면 하위 경로로 강등한다(표준 골격이 보여주는
/// 세 조각의 예시는 여전히 값어치가 있다 — `diagnostics_page.dart`에서
/// 진입한다).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/capability_ids.dart';
import 'package:my_dashboard/src/state/capability_provider.dart';
import 'package:my_dashboard/src/theme/app_tokens.dart';

/// 이 화면이 지원 여부를 물어보는 예시 capability id. app-core의 실제
/// 카탈로그에 있는 id를 가리킨다(`capability_ids.dart`).
const String _demoCapabilityId = kCapabilityDesktopWindowControl;

class TemplateDemoPage extends ConsumerWidget {
  const TemplateDemoPage({super.key, this.greeting = ''});

  final String greeting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final statusKey = ref.watch(
      capabilityStatusKeyProvider(_demoCapabilityId),
    );
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(title: Text(t(ref, 'app.title'))),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(greeting, key: const ValueKey('rust-greeting')),
            Text(t(ref, 'app.title'), style: TextStyle(color: tokens.fg)),
            const SizedBox(height: 8),
            Text(t(ref, statusKey), style: TextStyle(color: tokens.fg2)),
          ],
        ),
      ),
    );
  }
}
