import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/data/dashboard_api.dart';
import 'package:my_dashboard/src/integrations/data/grok_bot_models.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_api.dart';
import 'package:my_dashboard/src/integrations/data/grok_usage_models.dart';
import 'package:my_dashboard/src/integrations/platform/grok_auth.dart';
import 'package:my_dashboard/src/integrations/platform/grok_bot_auth.dart';

const Duration kGrokUsagePollInterval = Duration(seconds: 30);

bool grokUsageHostSupported() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

final grokUsageSupportedProvider = Provider<bool>(
  (ref) => grokUsageHostSupported(),
);
final grokInitialEnabledProvider = Provider<bool>((ref) => false);
final grokInitialBotEnabledProvider = Provider<bool>((ref) => false);
final grokAuthReadProvider = Provider<GrokAuthReadResult Function()>(
  (ref) => readInstalledGrokAuth,
);
final grokBotPreviewProvider = Provider<GrokBotPreview Function()>(
  (ref) => readInstalledGrokBotPreview,
);
final grokBotUnlockProvider =
    Provider<Future<GrokBotAuthReadResult> Function(GrokBotPreview preview)>(
      (ref) => unlockInstalledGrokBot,
    );
final grokBillingBaseProvider = Provider<Uri>(
  (ref) => resolveGrokBillingBase(),
);
final grokUsageApiProvider = Provider(
  (ref) => GrokUsageApi(ref.watch(httpSendProvider)),
);

class GrokUsageState {
  const GrokUsageState({
    bool enabled = false,
    bool? cliEnabled,
    this.botEnabled = false,
    this.reading,
    this.botReading,
    this.updatedAt,
    this.errorKey,
    this.botErrorKey,
    this.noticeKey,
    this.botNoticeKey,
    this.loading = false,
  }) : cliEnabled = cliEnabled ?? enabled;

  final bool cliEnabled;
  final bool botEnabled;
  final GrokUsageReading? reading;
  final GrokUsageReading? botReading;
  final DateTime? updatedAt;
  final String? errorKey;
  final String? botErrorKey;
  final String? noticeKey;
  final String? botNoticeKey;
  final bool loading;

  bool get enabled => cliEnabled || botEnabled;
}

final grokUsageControllerProvider =
    NotifierProvider<GrokUsageController, GrokUsageState>(
      GrokUsageController.new,
    );

class _ChannelResult {
  const _ChannelResult({
    this.reading,
    this.errorKey,
    this.noticeKey,
    this.blockHash,
    this.clearBlock = false,
    this.blockKeychain = false,
  });

  final GrokUsageReading? reading;
  final String? errorKey;
  final String? noticeKey;
  final int? blockHash;
  final bool clearBlock;
  final bool blockKeychain;
}

/// 거절된 토큰은 그 출처만 다시 치지 않는다. CLI와 Grok Bot은 서로 지우지 않는다.
class GrokUsageController extends Notifier<GrokUsageState> {
  Timer? _timer;
  int _generation = 0;
  bool _active = true;
  bool _disposed = false;
  Future<void>? _pending;
  int? _blockedCli;
  int? _blockedBot;
  bool _botKeychainBlocked = false;

  @override
  GrokUsageState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _timer?.cancel();
    });
    final supported = ref.read(grokUsageSupportedProvider);
    final cli = ref.read(grokInitialEnabledProvider) && supported;
    final bot = ref.read(grokInitialBotEnabledProvider) && supported;
    if (cli || bot) _timer = Timer(Duration.zero, refresh);
    return GrokUsageState(cliEnabled: cli, botEnabled: bot);
  }

  void configure(bool enabled) => _applySources(cli: enabled);

  void configureBot(bool enabled) => _applySources(bot: enabled);

  void _applySources({bool? cli, bool? bot}) {
    _generation++;
    _pending = null;
    _blockedCli = null;
    _blockedBot = null;
    _botKeychainBlocked = false;
    _timer?.cancel();
    final supported = ref.read(grokUsageSupportedProvider);
    final nextCli = (cli ?? state.cliEnabled) && supported;
    final nextBot = (bot ?? state.botEnabled) && supported;
    state = GrokUsageState(cliEnabled: nextCli, botEnabled: nextBot);
    if (state.enabled) unawaited(refresh());
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _timer?.cancel();
    if (active && state.enabled) {
      _blockedCli = null;
      _blockedBot = null;
      _botKeychainBlocked = false;
      unawaited(refresh(userInitiated: true));
    }
  }

  Future<void> refresh({bool userInitiated = false}) {
    if (_disposed || !state.enabled) return Future.value();
    if (userInitiated) {
      _blockedCli = null;
      _blockedBot = null;
      _botKeychainBlocked = false;
    }
    if (_pending != null) return _pending!;
    _timer?.cancel();
    final generation = _generation;
    final previous = state;
    state = GrokUsageState(
      cliEnabled: previous.cliEnabled,
      botEnabled: previous.botEnabled,
      reading: previous.reading,
      botReading: previous.botReading,
      updatedAt: previous.updatedAt,
      errorKey: previous.errorKey,
      botErrorKey: previous.botErrorKey,
      noticeKey: previous.noticeKey,
      botNoticeKey: previous.botNoticeKey,
      loading: true,
    );
    return _pending = _fetch(
      generation,
      previous,
      userInitiated: userInitiated,
    );
  }

  Future<void> _fetch(
    int generation,
    GrokUsageState previous, {
    required bool userInitiated,
  }) async {
    var cliReading = previous.cliEnabled ? previous.reading : null;
    var cliError = previous.cliEnabled ? previous.errorKey : null;
    var cliNotice = previous.cliEnabled ? previous.noticeKey : null;
    var botReading = previous.botEnabled ? previous.botReading : null;
    var botError = previous.botEnabled ? previous.botErrorKey : null;
    var botNotice = previous.botEnabled ? previous.botNoticeKey : null;
    var updatedAt = previous.updatedAt;
    try {
      if (previous.cliEnabled) {
        final cli = await _fetchCli(previous);
        if (_disposed || generation != _generation) return;
        cliReading = cli.reading;
        cliError = cli.errorKey;
        cliNotice = cli.noticeKey;
        if (cli.clearBlock) _blockedCli = null;
        if (cli.blockHash != null) _blockedCli = cli.blockHash;
        if (cli.errorKey == null) updatedAt = DateTime.now();
      }
      if (previous.botEnabled) {
        final bot = await _fetchBot(previous, userInitiated: userInitiated);
        if (_disposed || generation != _generation) return;
        botReading = bot.reading;
        botError = bot.errorKey;
        botNotice = bot.noticeKey;
        if (bot.clearBlock) _blockedBot = null;
        if (bot.blockHash != null) _blockedBot = bot.blockHash;
        _botKeychainBlocked = bot.blockKeychain;
        if (bot.errorKey == null) updatedAt = DateTime.now();
      }
      if (_disposed || generation != _generation) return;
      state = GrokUsageState(
        cliEnabled: previous.cliEnabled,
        botEnabled: previous.botEnabled,
        reading: cliReading,
        botReading: botReading,
        updatedAt: updatedAt,
        errorKey: cliError,
        botErrorKey: botError,
        noticeKey: cliNotice,
        botNoticeKey: botNotice,
      );
    } finally {
      if (!_disposed && generation == _generation) {
        _pending = null;
        if (_active && state.enabled) {
          _timer = Timer(kGrokUsagePollInterval, refresh);
        }
      }
    }
  }

  Future<_ChannelResult> _fetchCli(GrokUsageState previous) async {
    final auth = ref.read(grokAuthReadProvider)();
    final session = auth.session;
    if (auth.status != GrokAuthStatus.ready || session == null) {
      return _ChannelResult(
        reading: previous.reading,
        errorKey: switch (auth.status) {
          GrokAuthStatus.expired => 'grok.sign_in_expired',
          GrokAuthStatus.invalid => 'grok.auth_unreadable',
          GrokAuthStatus.unsupported => 'grok.macos_only',
          _ => 'grok.signed_out',
        },
      );
    }
    final fingerprint = session.accessToken.hashCode;
    if (fingerprint == _blockedCli) {
      return _ChannelResult(
        reading: previous.reading,
        errorKey: previous.errorKey ?? 'grok.unauthorized',
        blockHash: fingerprint,
      );
    }
    try {
      final reading = await ref
          .read(grokUsageApiProvider)
          .fetch(base: ref.read(grokBillingBaseProvider), session: session);
      return _ChannelResult(reading: reading, clearBlock: true);
    } on GrokUsageFailure catch (error) {
      if (error.labelKey == 'grok.no_usage') {
        return _ChannelResult(noticeKey: error.labelKey, clearBlock: true);
      }
      return _ChannelResult(
        reading: previous.reading,
        errorKey: error.labelKey,
        blockHash: error.labelKey == 'grok.unauthorized' ? fingerprint : null,
      );
    } catch (_) {
      return _ChannelResult(
        reading: previous.reading,
        errorKey: 'grok.network_error',
      );
    }
  }

  Future<_ChannelResult> _fetchBot(
    GrokUsageState previous, {
    required bool userInitiated,
  }) async {
    final preview = ref.read(grokBotPreviewProvider)();
    if (preview.status != GrokBotAuthStatus.ready) {
      return _ChannelResult(
        reading: previous.botReading,
        errorKey: switch (preview.status) {
          GrokBotAuthStatus.unreadable => 'grok.bot_unreadable',
          GrokBotAuthStatus.unsupported => 'grok.macos_only',
          GrokBotAuthStatus.keychainDenied => 'grok.bot_keychain_denied',
          _ => 'grok.bot_signed_out',
        },
        clearBlock: true,
      );
    }
    final hash = preview.ciphertextHash;
    if (!userInitiated && hash != null && hash == _blockedBot) {
      return _ChannelResult(
        reading: previous.botReading,
        errorKey: previous.botErrorKey ?? 'grok.bot_unauthorized',
        blockHash: hash,
      );
    }
    if (!userInitiated && _botKeychainBlocked) {
      return _ChannelResult(
        reading: previous.botReading,
        errorKey: previous.botErrorKey ?? 'grok.bot_keychain_denied',
        blockKeychain: true,
      );
    }
    final unlocked = await ref.read(grokBotUnlockProvider)(preview);
    final token = unlocked.accessToken;
    if (unlocked.status != GrokBotAuthStatus.ready ||
        token == null ||
        token.isEmpty) {
      final denied = unlocked.status == GrokBotAuthStatus.keychainDenied;
      return _ChannelResult(
        reading: previous.botReading,
        errorKey: switch (unlocked.status) {
          GrokBotAuthStatus.keychainDenied => 'grok.bot_keychain_denied',
          GrokBotAuthStatus.missing => 'grok.bot_signed_out',
          GrokBotAuthStatus.unsupported => 'grok.macos_only',
          _ => 'grok.bot_unreadable',
        },
        blockKeychain: denied,
        clearBlock: true,
      );
    }
    try {
      final reading = await ref
          .read(grokUsageApiProvider)
          .fetchBot(accessToken: token);
      return _ChannelResult(reading: reading, clearBlock: true);
    } on GrokUsageFailure catch (error) {
      if (error.labelKey == 'grok.bot_no_usage') {
        return _ChannelResult(noticeKey: error.labelKey, clearBlock: true);
      }
      return _ChannelResult(
        reading: previous.botReading,
        errorKey: error.labelKey,
        blockHash: error.labelKey == 'grok.bot_unauthorized' ? hash : null,
      );
    } catch (_) {
      return _ChannelResult(
        reading: previous.botReading,
        errorKey: 'grok.bot_network_error',
      );
    }
  }
}
