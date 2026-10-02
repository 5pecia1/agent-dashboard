import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/data/teamclaude_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/teamclaude_provider.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/config_read_retry_row.dart';

class TeamClaudeSetup extends ConsumerStatefulWidget {
  const TeamClaudeSetup({super.key});
  @override
  ConsumerState<TeamClaudeSetup> createState() => _TeamClaudeSetupState();
}

class _TeamClaudeSetupState extends ConsumerState<TeamClaudeSetup> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _message;

  /// 저장된 설정을 읽지 못한 이유. 있는 동안 [_loading]을 풀지 않는다 —
  /// 입력과 연결/해제가 잠겨 있어야 다음 저장이 저장된 연결을 지우지 못한다.
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await ref.read(configLoadFnProvider)();
      if (!mounted) return;
      setState(() {
        _url.text = values.teamClaude?.baseUrl ?? '';
        _key.text = values.teamClaude?.apiKey ?? '';
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  Future<void> _retryLoad() async {
    setState(() => _busy = true);
    try {
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool disconnect = false}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final connection = disconnect
          ? null
          : TeamClaudeConnection.parse(_url.text, _key.text);
      await ref.read(configPatchFnProvider)(
        (current) => current.withTeamClaude(connection),
      );
      if (!mounted) return;
      ref.read(teamClaudeControllerProvider.notifier).configure(connection);
      if (disconnect) {
        _url.clear();
        _key.clear();
      }
      setState(
        () => _message = disconnect
            ? 'teamclaude.disconnected'
            : 'teamclaude.saved',
      );
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = 'setup.save_error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(t(ref, 'teamclaude.title')),
    subtitle: Text(t(ref, 'teamclaude.setup_hint')),
    children: [
      if (_loadError != null)
        ConfigReadRetryRow(onRetry: _busy ? null : _retryLoad),
      TextField(
        key: const ValueKey('teamclaude-url'),
        controller: _url,
        enabled: !_loading && !_busy,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(labelText: t(ref, 'teamclaude.url')),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('teamclaude-key'),
        controller: _key,
        enabled: !_loading && !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: t(ref, 'teamclaude.key'),
          helperText: t(ref, 'teamclaude.key_hint'),
          helperMaxLines: 3,
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: _loading || _busy ? null : () => _save(),
            child: Text(t(ref, 'teamclaude.connect')),
          ),
          TextButton(
            onPressed: _loading || _busy ? null : () => _save(disconnect: true),
            child: Text(t(ref, 'teamclaude.disconnect')),
          ),
        ],
      ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t(ref, _message!)),
        ),
    ],
  );
}
