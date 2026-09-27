/// Composition points used by the app's optional, user-configured integrations.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final dashboardHomeSectionsProvider = Provider<List<Widget>>((ref) => const []);
final dashboardSetupSectionsProvider = Provider<List<Widget>>(
  (ref) => const [],
);
final dashboardExtensionRefreshingProvider = Provider<bool>((ref) => false);
final dashboardExtensionRefreshProvider = Provider<Future<void> Function()>(
  (ref) => () async {},
);

typedef DashboardTrayLabels = List<String> Function(WidgetRef ref);
List<String> emptyDashboardTrayLabels(WidgetRef ref) => const [];
final dashboardTrayLabelsProvider = Provider<DashboardTrayLabels>(
  (ref) => emptyDashboardTrayLabels,
);
