import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/grok_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';

class GrokSetup extends ConsumerStatefulWidget {
  const GrokSetup({super.key});
  @override
  ConsumerState<GrokSetup> createState() => _GrokSetupState();
}

class _GrokSetupState extends ConsumerState<GrokSetup> {
  bool _enabled = false;
  bool _botEnabled = false;
  bool _loading = true;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await ref.read(configLoadFnProvider)();
      if (!mounted) return;
      _enabled = values.grokEnabled;
      _botEnabled = values.grokBotEnabled;
    } catch (_) {
      if (mounted) _message = 'setup.save_error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setBot(bool enabled) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref.read(configPatchFnProvider)(
        (current) => current.withGrokBot(enabled),
      );
      if (!mounted) return;
      ref.read(grokUsageControllerProvider.notifier).configureBot(enabled);
      setState(() {
        _botEnabled = enabled;
        _message = enabled ? 'grok.bot_saved' : 'grok.bot_disconnected';
      });
    } catch (_) {
      if (mounted) setState(() => _message = 'setup.save_error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _set(bool enabled) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref.read(configPatchFnProvider)(
        (current) => current.withGrok(enabled),
      );
      if (!mounted) return;
      ref.read(grokUsageControllerProvider.notifier).configure(enabled);
      setState(() {
        _enabled = enabled;
        _message = enabled ? 'grok.saved' : 'grok.disconnected';
      });
    } catch (_) {
      if (mounted) setState(() => _message = 'setup.save_error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = ref.watch(grokUsageSupportedProvider);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(t(ref, 'grok.title')),
      subtitle: Text(t(ref, supported ? 'grok.setup_hint' : 'grok.macos_only')),
      children: [
        if (!supported)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t(ref, 'grok.macos_only_body')),
          )
        else ...[
          SwitchListTile(
            key: const ValueKey('grok-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(t(ref, 'grok.enable')),
            value: _enabled,
            onChanged: _loading || _busy ? null : _set,
          ),
          SwitchListTile(
            key: const ValueKey('grok-bot-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(t(ref, 'grok.bot_enable')),
            value: _botEnabled,
            onChanged: _loading || _busy ? null : _setBot,
          ),
        ],
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(t(ref, _message!)),
          ),
      ],
    );
  }
}
