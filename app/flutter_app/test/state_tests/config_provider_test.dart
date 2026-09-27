/// `config_provider.dart`를 실제 파일/localStorage 없이 닫는다.
///
/// [DashboardConfigValues]의 (역)직렬화·[dashboardApiConfigOverrideFor]는
/// 순수 값 변환이라 IO 없이 확인할 수 있다. [configLoadFnProvider]/
/// [configSaveFnProvider]는 시임 계약(override 가능한 자리라는 것)만
/// 확인한다 — 실제 io/web 브리지(`config_store_io.dart`/`config_store_web.dart`)
/// 를 호출하면 이 테스트 머신의 실제 `~/.local/state/`를 건드리게 되므로
/// 여기서는 절대 그 기본값을 실행하지 않는다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/state/config_provider.dart';

void main() {
  group('DashboardConfigValues', () {
    test('empty는 세 값 모두 없고 isEmpty가 true다', () {
      expect(DashboardConfigValues.empty.isEmpty, isTrue);
      expect(DashboardConfigValues.empty.serverUrl, isNull);
      expect(DashboardConfigValues.empty.clientToken, isNull);
      expect(DashboardConfigValues.empty.cursor, isNull);
    });

    test('값이 하나라도 있으면 isEmpty가 false다', () {
      expect(
        const DashboardConfigValues(serverUrl: 'https://x.test').isEmpty,
        isFalse,
      );
    });

    test('toJson/fromJson이 왕복한다', () {
      const original = DashboardConfigValues(
        serverUrl: 'https://api.example.workers.dev',
        clientToken: 'client-token-abc',
        cursor: 42,
      );

      final restored = DashboardConfigValues.fromJson(original.toJson());

      expect(restored, original);
    });

    test('fromJson은 cursor가 double로 와도 int로 접는다', () {
      final restored = DashboardConfigValues.fromJson(<String, Object?>{
        'server_url': null,
        'client_token': null,
        'cursor': 42.0,
      });
      expect(restored.cursor, 42);
    });

    test('fromJson은 모르는/빠진 키를 조용히 접는다', () {
      final restored = DashboardConfigValues.fromJson(<String, Object?>{});
      expect(restored, DashboardConfigValues.empty);
    });

    test('copyWith는 넘기지 않은 필드를 그대로 보존한다', () {
      const original = DashboardConfigValues(
        serverUrl: 'https://a.test',
        clientToken: 'token-a',
        cursor: 1,
      );

      final updated = original.copyWith(cursor: 2);

      expect(updated.serverUrl, 'https://a.test');
      expect(updated.clientToken, 'token-a');
      expect(updated.cursor, 2);
    });

    test('==/hashCode는 세 필드 전부로 비교한다', () {
      const a = DashboardConfigValues(serverUrl: 'https://a.test', cursor: 1);
      const b = DashboardConfigValues(serverUrl: 'https://a.test', cursor: 1);
      const c = DashboardConfigValues(serverUrl: 'https://a.test', cursor: 2);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('themeMode도 toJson/fromJson이 왕복한다', () {
      const original = DashboardConfigValues(
        serverUrl: 'https://api.example.workers.dev',
        themeMode: 'dark',
      );

      final restored = DashboardConfigValues.fromJson(original.toJson());

      expect(restored, original);
      expect(restored.themeMode, 'dark');
    });

    test('fromJson은 theme_mode가 문자열이 아니면 조용히 null로 접는다', () {
      final restored = DashboardConfigValues.fromJson(<String, Object?>{
        'theme_mode': 42,
      });
      expect(restored.themeMode, isNull);
    });

    test('copyWith(themeMode: ...)는 다른 필드를 보존하고 themeMode만 바꾼다', () {
      const original = DashboardConfigValues(
        serverUrl: 'https://a.test',
        themeMode: 'light',
      );

      final updated = original.copyWith(themeMode: 'dark');

      expect(updated.serverUrl, 'https://a.test');
      expect(updated.themeMode, 'dark');
    });

    test('themeMode가 다르면 서로 다른 값으로 취급된다', () {
      const a = DashboardConfigValues(themeMode: 'light');
      const b = DashboardConfigValues(themeMode: 'dark');
      expect(a, isNot(b));
    });
  });

  group('dashboardApiConfigOverrideFor', () {
    test('serverUrl이 없으면(첫 실행) null을 돌려준다(U-fix: placeholder URL 금지)', () {
      expect(
        dashboardApiConfigOverrideFor(DashboardConfigValues.empty),
        isNull,
      );
    });

    test('저장된 serverUrl/clientToken이 있으면 그것으로 override를 만든다', () {
      final override = dashboardApiConfigOverrideFor(
        const DashboardConfigValues(
          serverUrl: 'https://saved.example.dev',
          clientToken: 'saved-token',
        ),
        timeout: const Duration(seconds: 3),
      );
      expect(override, isNotNull);

      final container = ProviderContainer(overrides: [override!]);
      addTearDown(container.dispose);

      final config = container.read(dashboardApiConfigProvider);
      expect(config.baseUrl, Uri.parse('https://saved.example.dev'));
      expect(config.clientToken, 'saved-token');
      expect(config.timeout, const Duration(seconds: 3));
    });
  });

  group('dashboardConfigValuesProvider', () {
    test('override하지 않고 읽으면 실패한다(부팅이 반드시 채워야 한다)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // riverpod 3은 provider가 던진 예외를 한 겹 감싸므로(dashboard_api_test.dart의
      // "설정 provider를 override하지 않으면 즉시 알려 준다"와 같은 관용) 타입 대신
      // 안내 문구가 사용자에게 닿는지를 본다.
      expect(
        () => container.read(dashboardConfigValuesProvider),
        throwsA(
          predicate<Object>(
            (Object error) =>
                error.toString().contains('dashboardConfigValuesProvider'),
            'dashboardConfigValuesProvider override를 안내하는 예외',
          ),
        ),
      );
    });

    test('override하면 그 값을 그대로 읽는다', () {
      const values = DashboardConfigValues(serverUrl: 'https://x.test');
      final container = ProviderContainer(
        overrides: [dashboardConfigValuesProvider.overrideWithValue(values)],
      );
      addTearDown(container.dispose);

      expect(container.read(dashboardConfigValuesProvider), values);
    });
  });

  group('저장소 시임 (Provider<Fn> 계층)', () {
    test('configLoadFnProvider/configSaveFnProvider는 override 가능하다', () async {
      DashboardConfigValues? saved;
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(
            () async =>
                const DashboardConfigValues(serverUrl: 'https://mem.test'),
          ),
          configSaveFnProvider.overrideWithValue((values) async {
            saved = values;
          }),
        ],
      );
      addTearDown(container.dispose);

      final loaded = await container.read(configLoadFnProvider)();
      expect(loaded.serverUrl, 'https://mem.test');

      const toSave = DashboardConfigValues(cursor: 7);
      await container.read(configSaveFnProvider)(toSave);
      expect(saved, toSave);
    });
  });

  group('configPatchFnProvider (1.5계층: 직렬화된 읽기-수정-쓰기 패치)', () {
    test('mutate가 바꾼 필드만 저장소에 반영되고 나머지는 다시 읽은 값 그대로다', () async {
      final store = _MemoryConfigStore(
        const DashboardConfigValues(serverUrl: 'https://a.test', cursor: 1),
      );
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue(store.save),
        ],
      );
      addTearDown(container.dispose);

      await container.read(configPatchFnProvider)(
        (current) => current.copyWith(cursor: 2),
      );

      expect(store.values.serverUrl, 'https://a.test');
      expect(store.values.cursor, 2);
    });

    test('mutate 결과가 방금 읽은 값과 같으면 다시 쓰지 않는다', () async {
      final store = _MemoryConfigStore(const DashboardConfigValues(cursor: 7));
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue(store.save),
        ],
      );
      addTearDown(container.dispose);

      await container.read(configPatchFnProvider)(
        (current) => current.copyWith(cursor: 7),
      );

      expect(store.saves, isEmpty, reason: '같은 값을 매번 다시 쓰면 낭비다(3초 폴링마다)');
    });

    test('클로버링 회귀: 테마를 저장한 뒤 커서를 저장해도 테마가 살아있다', () async {
      final store = _MemoryConfigStore();
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue(store.save),
        ],
      );
      addTearDown(container.dispose);
      final patch = container.read(configPatchFnProvider);

      // 설정 화면이 테마를 즉시 저장한다.
      await patch((current) => current.copyWith(themeMode: 'dark'));
      // 이어서 sync_controller가 자기 몫(cursor)만 저장한다 — 예전 버그는
      // 이 두 번째 저장이 themeMode를 null로 되돌렸다(부팅 스냅샷 기반
      // 전체 덮어쓰기였기 때문).
      await patch((current) => current.copyWith(cursor: 168));

      final reloaded = await container.read(configLoadFnProvider)();
      expect(reloaded.themeMode, 'dark', reason: '커서 저장이 테마를 지우면 안 된다(버그 A)');
      expect(reloaded.cursor, 168);
    });

    test('클로버링 회귀: resident를 저장한 뒤 커서를 저장해도 resident가 살아있다', () async {
      final store = _MemoryConfigStore();
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue(store.save),
        ],
      );
      addTearDown(container.dispose);
      final patch = container.read(configPatchFnProvider);

      await patch((current) => current.copyWith(resident: false));
      await patch((current) => current.copyWith(cursor: 168));

      final reloaded = await container.read(configLoadFnProvider)();
      expect(
        reloaded.resident,
        isFalse,
        reason: '커서 저장이 resident를 지우면 안 된다(버그 A)',
      );
      expect(reloaded.cursor, 168);
    });

    test('거의 동시에 들어온 두 패치도 순서대로 처리되어 서로의 필드를 지우지 않는다(경합 방지)', () async {
      final store = _MemoryConfigStore();
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue(store.save),
        ],
      );
      addTearDown(container.dispose);
      final patch = container.read(configPatchFnProvider);

      // 둘 다 서로를 기다리지 않고 곧바로 이어서 부른다 — 직렬화 큐가
      // 없다면 두 번째 호출의 load()가 첫 번째 호출의 save()보다 먼저
      // 끝나 서로의 필드를 지우는 경합이 난다.
      final first = patch((current) => current.copyWith(themeMode: 'dark'));
      final second = patch((current) => current.copyWith(resident: false));
      await Future.wait<void>([first, second]);

      expect(store.values.themeMode, 'dark');
      expect(store.values.resident, isFalse);
      expect(
        store.saves,
        hasLength(2),
        reason: '두 저장이 다 반영돼야 한다(하나가 다른 하나를 덮으면 안 된다)',
      );
    });

    test('앞선 패치가 실패해도 뒤에 줄 선 패치는 정상 진행된다', () async {
      final store = _MemoryConfigStore();
      var saveCalls = 0;
      final container = ProviderContainer(
        overrides: [
          configLoadFnProvider.overrideWithValue(store.load),
          configSaveFnProvider.overrideWithValue((values) async {
            saveCalls += 1;
            if (saveCalls == 1) {
              throw const FormatException('디스크 권한 없음(가짜)');
            }
            await store.save(values);
          }),
        ],
      );
      addTearDown(container.dispose);
      final patch = container.read(configPatchFnProvider);

      await expectLater(
        patch((current) => current.copyWith(themeMode: 'dark')),
        throwsA(isA<FormatException>()),
      );
      // 실패는 호출자에게만 전달되고, 큐 자체는 막히지 않는다.
      await patch((current) => current.copyWith(cursor: 5));

      expect(store.values.cursor, 5);
    });
  });
}

/// 메모리에만 남는 가짜 설정 저장소 — 실제 `~/.local/state/`를 건드리지
/// 않는다(위 `dashboardConfigValuesProvider` 그룹의 override 관용과 같은
/// 이유).
class _MemoryConfigStore {
  _MemoryConfigStore([this.values = DashboardConfigValues.empty]);

  DashboardConfigValues values;
  final List<DashboardConfigValues> saves = <DashboardConfigValues>[];

  Future<DashboardConfigValues> load() async => values;

  Future<void> save(DashboardConfigValues next) async {
    values = next;
    saves.add(next);
  }
}
