import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_quota_panel.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/quota_widgets.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_panel.dart';

const double kUsagePanelsSideBySideMaxTextScale = 1.2;

/// 카드 좌우 마진 8 두 번과 안쪽 패딩 12 두 번.
const double kUsageCardChromeWidth = 12 * 2 + kUsagePanelHorizontalMargin * 2;

/// TeamClaude는 Claude와 Codex를 같이 두므로 조금 더 넓고, 남는 폭도 이 비율로 나눈다.
const int kTeamClaudeUsageFlex = 3;
const int kCompactUsageFlex = 2;

/// 제목, 요금제, 조회 시각이 한 줄에 들어가는 바깥 폭.
const double kCompactUsageMinWidth = 280;

double teamClaudeOuterMinWidth() =>
    kQuotaCompactDesktopWidth + kUsageCardChromeWidth;

double compactUsageOuterMinWidth(double textScale) =>
    kCompactUsageMinWidth * textScale;

/// 최소 폭의 합이 [width]에 들어가는 카드만 같은 줄에 둔다.
List<List<int>> packUsageCardLines(List<double> minWidths, double width) {
  final lines = <List<int>>[];
  var current = <int>[];
  var used = 0.0;
  for (var i = 0; i < minWidths.length; i++) {
    final minWidth = minWidths[i];
    if (current.isNotEmpty && used + minWidth > width) {
      lines.add(current);
      current = <int>[i];
      used = minWidth;
    } else {
      current.add(i);
      used += minWidth;
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}

/// 각 카드는 최소 폭을 보장하고, 남는 폭은 [flexes] 비율로 나눈다.
List<double> usageLineWidths({
  required List<int> flexes,
  required List<double> minWidths,
  required double width,
}) {
  final count = flexes.length;
  final widths = List<double>.from(minWidths);
  final leftover = width - minWidths.fold<double>(0, (sum, min) => sum + min);
  if (leftover <= 0 || count == 0) return widths;
  final flexSum = flexes.fold<int>(0, (sum, flex) => sum + flex);
  var given = 0.0;
  for (var i = 0; i < count; i++) {
    final extra = i == count - 1
        ? leftover - given
        : leftover * flexes[i] / flexSum;
    widths[i] += extra;
    given += extra;
  }
  return widths;
}

class _UsageSlot {
  const _UsageSlot({
    required this.minWidth,
    required this.flex,
    required this.child,
  });

  final double minWidth;
  final int flex;
  final Widget child;
}

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
    final hasGrok = ref.watch(
      grokUsageControllerProvider.select((state) => state.enabled),
    );
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final compact = compactUsageOuterMinWidth(scale);
    final slots = <_UsageSlot>[
      if (hasTeamClaude)
        _UsageSlot(
          minWidth: teamClaudeOuterMinWidth(),
          flex: kTeamClaudeUsageFlex,
          child: const TeamClaudePanel(),
        ),
      if (hasDevin)
        _UsageSlot(
          minWidth: compact,
          flex: kCompactUsageFlex,
          child: const DevinQuotaPanel(),
        ),
      if (hasGrok)
        _UsageSlot(
          minWidth: compact,
          flex: kCompactUsageFlex,
          child: const GrokQuotaPanel(),
        ),
    ];
    if (slots.isEmpty) return const SizedBox.shrink();
    if (slots.length == 1) return slots.single.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (scale > kUsagePanelsSideBySideMaxTextScale) {
          return Column(children: [for (final slot in slots) slot.child]);
        }
        final lines = packUsageCardLines([
          for (final slot in slots) slot.minWidth,
        ], constraints.maxWidth);
        return Column(
          children: [
            for (final indexes in lines)
              _UsageLine(
                width: constraints.maxWidth,
                slots: [for (final index in indexes) slots[index]],
              ),
          ],
        );
      },
    );
  }
}

class _EqualHeightRow extends MultiChildRenderObjectWidget {
  const _EqualHeightRow({required this.widths, required super.children});

  final List<double> widths;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEqualHeightRow(widths);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderEqualHeightRow renderObject,
  ) {
    renderObject.widths = widths;
  }
}

class _EqualHeightParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderEqualHeightRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualHeightParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EqualHeightParentData> {
  _RenderEqualHeightRow(this._widths);

  List<double> _widths;

  set widths(List<double> value) {
    if (listEquals(_widths, value)) return;
    _widths = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualHeightParentData) {
      child.parentData = _EqualHeightParentData();
    }
  }

  @override
  void performLayout() {
    // 첫 측정은 로딩 문구처럼 제약에 따라 나중에 잡히는 높이를 놓칠 수 있어
    // 무한 높이로 다시 재고, 그 최대 높이를 최소 높이로 맞춘다.
    var minHeight = 0.0;
    for (var pass = 0; pass < 3; pass++) {
      var nextMax = 0.0;
      var index = 0;
      var child = firstChild;
      while (child != null) {
        child.layout(
          BoxConstraints(
            minWidth: _widths[index],
            maxWidth: _widths[index],
            minHeight: minHeight,
            maxHeight: double.infinity,
          ),
          parentUsesSize: true,
        );
        if (child.size.height > nextMax) nextMax = child.size.height;
        child = childAfter(child);
        index++;
      }
      if (nextMax <= minHeight) break;
      minHeight = nextMax;
    }
    var x = 0.0;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      (child.parentData! as _EqualHeightParentData).offset = Offset(x, 0);
      x += _widths[index];
      child = childAfter(child);
      index++;
    }
    size = constraints.constrain(Size(x, minHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _UsageLine extends StatelessWidget {
  const _UsageLine({required this.width, required this.slots});

  final double width;
  final List<_UsageSlot> slots;

  @override
  Widget build(BuildContext context) {
    if (slots.length == 1) return slots.single.child;
    final widths = usageLineWidths(
      flexes: [for (final slot in slots) slot.flex],
      minWidths: [for (final slot in slots) slot.minWidth],
      width: width,
    );
    return _EqualHeightRow(
      widths: widths,
      children: [for (final slot in slots) slot.child],
    );
  }
}
