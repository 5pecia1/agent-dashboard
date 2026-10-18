import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/agy_usage_provider.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/integrations/ui/widgets/config_read_retry_row.dart';
import 'package:my_dashboard/src/state/config_provider.dart';

class AgySetup extends ConsumerStatefulWidget {
  const AgySetup({super.key});
  @override
  ConsumerState<AgySetup> createState() => _AgySetupState();
}

class _AgySetupState extends ConsumerState<AgySetup> {
  bool _enabled = false;
  bool _loading = true;
  bool _busy = false;
  Object? _loadError;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await ref.read(configLoadFnProvider)();
      if (!mounted) return;
      setState(() {
        _enabled = config.agyEnabled;
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

  Future<void> _set(bool enabled) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref.read(configPatchFnProvider)(
        (current) => current.withAgy(enabled),
      );
      if (!mounted) return;
      ref.read(agyUsageControllerProvider.notifier).configure(enabled);
      setState(() {
        _enabled = enabled;
        _message = enabled ? 'agy.saved' : 'agy.disconnected';
      });
    } catch (_) {
      if (mounted) setState(() => _message = 'setup.save_error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = ref.watch(agyUsageSupportedProvider);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(t(ref, 'agy.title')),
      subtitle: Text(t(ref, supported ? 'agy.setup_hint' : 'agy.macos_only')),
      children: [
        if (_loadError != null)
          ConfigReadRetryRow(onRetry: _busy ? null : _retryLoad),
        if (!supported)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t(ref, 'agy.macos_only_body')),
          )
        else
          SwitchListTile(
            key: const ValueKey('agy-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(t(ref, 'agy.enable')),
            value: _enabled,
            onChanged: _loading || _busy ? null : _set,
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(t(ref, _message!)),
          ),
      ],
    );
  }
}
