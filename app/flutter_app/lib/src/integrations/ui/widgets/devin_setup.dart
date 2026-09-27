import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:my_dashboard/src/integrations/data/devin_usage_models.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/integrations/state/usage_config.dart';
import 'package:my_dashboard/src/state/config_provider.dart';
import 'package:my_dashboard/src/integrations/state/devin_usage_provider.dart';

class DevinSetup extends ConsumerStatefulWidget {
  const DevinSetup({super.key});
  @override
  ConsumerState<DevinSetup> createState() => _DevinSetupState();
}

class _DevinSetupState extends ConsumerState<DevinSetup> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _url.text = kDevinDefaultApiServer;
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await ref.read(configLoadFnProvider)();
      if (!mounted) return;
      _url.text = values.devin?.baseUrl ?? kDevinDefaultApiServer;
      _key.text = values.devin?.apiKey ?? '';
    } catch (_) {
      if (mounted) _message = 'setup.save_error';
    } finally {
      if (mounted) setState(() => _loading = false);
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
          : DevinConnection.parse(_url.text, _key.text);
      await ref.read(configPatchFnProvider)(
        (current) => current.withDevin(connection),
      );
      if (!mounted) return;
      ref.read(devinUsageControllerProvider.notifier).configure(connection);
      if (disconnect) {
        _url.text = kDevinDefaultApiServer;
        _key.clear();
      }
      setState(
        () => _message = disconnect ? 'devin.disconnected' : 'devin.saved',
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
    title: Text(t(ref, 'devin.title')),
    subtitle: Text(t(ref, 'devin.setup_hint')),
    children: [
      TextField(
        key: const ValueKey('devin-url'),
        controller: _url,
        enabled: !_loading && !_busy,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(labelText: t(ref, 'devin.url')),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('devin-key'),
        controller: _key,
        enabled: !_loading && !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: t(ref, 'devin.key'),
          helperText: t(ref, 'devin.key_hint'),
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
            child: Text(t(ref, 'devin.connect')),
          ),
          TextButton(
            onPressed: _loading || _busy ? null : () => _save(disconnect: true),
            child: Text(t(ref, 'devin.disconnect')),
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
