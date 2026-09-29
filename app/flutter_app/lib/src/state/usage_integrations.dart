import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_extensions.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/i18n/usage_catalog.dart';
import 'package:my_dashboard/src/integrations/platform/tray_usage.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/ui/usage_panels.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/teamclaude_setup.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/devin_setup.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/grok_setup.dart';

/// User-configurable integrations included in every Agent Dashboard build.
/// Controllers only poll after the user supplies a connection.
List<Override> usageDashboardOverrides(DashboardConfigValues config) => [
  ...usageDashboardUiOverrides,
  teamClaudeInitialConnectionProvider.overrideWithValue(config.teamClaude),
  devinInitialConnectionProvider.overrideWithValue(config.devin),
  grokInitialEnabledProvider.overrideWithValue(config.grokEnabled),
  grokInitialBotEnabledProvider.overrideWithValue(config.grokBotEnabled),
  extensionTranslationProvider.overrideWithValue(usageTranslation),
];

// Tests may override controllers and translation separately while exercising the
// real integration wiring.
final usageDashboardUiOverrides = <Override>[
  dashboardHomeSectionsProvider.overrideWith((ref) => const [UsagePanels()]),
  dashboardSetupSectionsProvider.overrideWith(
    (ref) => const [TeamClaudeSetup(), DevinSetup(), GrokSetup()],
  ),
  dashboardExtensionRefreshingProvider.overrideWith(
    (ref) =>
        ref.watch(
          teamClaudeControllerProvider.select((state) => state.loading),
        ) ||
        ref.watch(
          devinUsageControllerProvider.select((state) => state.loading),
        ) ||
        ref.watch(grokUsageControllerProvider.select((state) => state.loading)),
  ),
  dashboardExtensionRefreshProvider.overrideWith(
    (ref) => () async {
      await Future.wait([
        ref.read(teamClaudeControllerProvider.notifier).refresh(),
        ref.read(devinUsageControllerProvider.notifier).refresh(),
        ref
            .read(grokUsageControllerProvider.notifier)
            .refresh(userInitiated: true),
      ]);
    },
  ),
  dashboardTrayLabelsProvider.overrideWith((ref) {
    final teamClaude = ref.watch(teamClaudeControllerProvider);
    final devin = ref.watch(devinUsageControllerProvider);
    final grok = ref.watch(grokUsageControllerProvider);
    return (widgetRef) => buildTrayUsageLabels(
      widgetRef,
      teamClaude: teamClaude,
      devin: devin,
      grok: grok,
    );
  }),
];
