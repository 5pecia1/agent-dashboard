import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/data/dashboard_dto.dart';
import 'package:my_dashboard/src/data/sync_reducer.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/state/dashboard_provider.dart';
import 'package:my_dashboard/src/state/sync_controller.dart';

const deletionProject = '/workspace/project';
const deletionOtherProject = '/other/project';
const deletionFirstKey = 'claude-code:first';
const deletionSecondKey = 'codex:second';
const deletionOtherKey = 'devin:other';

SessionViewDto deletionSession(
  String key, {
  String project = deletionProject,
}) => SessionViewDto(
  key: key,
  sessionId: key.split(':').last,
  source: key.split(':').first,
  project: project,
  host: key == deletionSecondKey ? 'linux-host' : 'mac-host',
  state: 'waiting_input',
  lastTransitionId: 10,
  updatedAt: 1000,
);

TransitionDto deletionAlert(int id, String key) => TransitionDto(
  id: id,
  sessionKey: key,
  fromState: 'working',
  toState: 'waiting_input',
  occurredAt: 1000,
  createdAt: 1000,
  project: deletionProject,
);

class DeletionTestController extends SyncController {
  DeletionTestController(this.initial);
  final SyncControllerState initial;
  @override
  SyncControllerState build() => initial;

  void addSession(SessionViewDto session) {
    state = state.copyWith(
      sync: state.sync.copyWith(
        sessions: {...state.sync.sessions, session.key: session},
      ),
    );
  }

  void addAlert(TransitionDto alert) {
    state = state.copyWith(
      sync: state.sync.copyWith(
        pendingAlerts: [...state.sync.pendingAlerts, alert],
      ),
    );
  }
}

class SessionDeletionHarness {
  SessionDeletionHarness({required HttpSendFn send}) {
    controller = DeletionTestController(
      SyncControllerState(
        sync: SyncState(
          cursor: 10,
          sessions: {
            deletionFirstKey: deletionSession(deletionFirstKey),
            deletionSecondKey: deletionSession(deletionSecondKey),
            deletionOtherKey: deletionSession(
              deletionOtherKey,
              project: deletionOtherProject,
            ),
          },
          pendingAlerts: [
            deletionAlert(8, deletionFirstKey),
            deletionAlert(9, deletionSecondKey),
            deletionAlert(10, deletionOtherKey),
          ],
        ),
      ),
    );
    container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(() => controller),
        httpSendProvider.overrideWithValue(send),
        dashboardInitialApiConfigProvider.overrideWithValue(
          DashboardApiConfig(
            baseUrl: Uri.parse('https://original.example.test'),
          ),
        ),
        dashboardApiConfigProviderOverride,
        dashboardConfigValuesProvider.overrideWithValue(
          const DashboardConfigValues(),
        ),
        syncNowMsFnProvider.overrideWithValue(() => 1000),
        i18nTranslateOverride.overrideWithValue((key, locale) => key),
        i18nTranslateArgsOverride.overrideWithValue(
          (key, locale, keys, values) => '$key ${values.join(' / ')}',
        ),
        stateLabelKeyFnProvider.overrideWithValue(
          (state) => 'state.${state.name}',
        ),
        isSessionStaleFnProvider.overrideWithValue(
          ({required int now, required int updatedAt, required int staleMs}) =>
              false,
        ),
      ],
    );
    container.read(syncControllerProvider);
  }

  late final DeletionTestController controller;
  late final ProviderContainer container;
  SyncControllerState get state => container.read(syncControllerProvider);
  int get revision =>
      container.read(dashboardApiConfigControllerProvider.notifier).revision;

  void changeConnection() {
    container
        .read(dashboardApiConfigControllerProvider.notifier)
        .apply(
          serverUrl: 'https://replacement.example.test',
          clientToken: null,
        );
  }
}
