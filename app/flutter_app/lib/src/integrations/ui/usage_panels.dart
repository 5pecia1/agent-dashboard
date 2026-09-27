import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_quota_panel.dart';

const double kUsagePanelsSideBySideMinWidth = 760;
const double kUsagePanelsSideBySideMaxTextScale = 1.2;

class UsagePanels extends ConsumerWidget {
  const UsagePanels({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTeamClaude = ref.watch(
      teamClaudeControllerProvider.select((state) => state.connection != null),
    );
    final hasDevin = ref.watch(
      devinUsageControllerProvider.select((state) => state.connection != null),
    );
    if (!hasTeamClaude && !hasDevin) return const SizedBox.shrink();
    if (!hasTeamClaude) return const DevinQuotaPanel();
    if (!hasDevin) return const TeamClaudePanel();
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide =
            constraints.maxWidth >= kUsagePanelsSideBySideMinWidth &&
            MediaQuery.textScalerOf(context).scale(1) <=
                kUsagePanelsSideBySideMaxTextScale;
        if (!sideBySide) {
          return const Column(children: [TeamClaudePanel(), DevinQuotaPanel()]);
        }
        return const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: TeamClaudePanel()),
            Expanded(child: DevinQuotaPanel()),
          ],
        );
      },
    );
  }
}

/// 완료 기준 2의 그룹+그리드 본문. 바깥 [ListView](이 화면의 유일한
/// 스크롤 소유자)와 스크롤을 다투지 않도록, 안쪽 [GridView]들은 전부
/// `shrinkWrap` + `NeverScrollableScrollPhysics`로 스스로는 스크롤하지
/// 않는다 — 실제 폭은 [LayoutBuilder]가 매 빌드마다 다시 재서
/// [sessionGridColumnCountFor]에 넘긴다(회전/리사이즈에도 다시 계산됨).
///
/// [groups]를 그대로 그리지 않고 [foldSessionGroupsForRender]를 거친다 —
/// 그 함수 doc comment에 남긴 진단대로, 1개짜리 그룹을 매번 헤더+그리드로
/// 독립시키면 갤러리가 세로 나열로 퇴화하기 때문이다.
