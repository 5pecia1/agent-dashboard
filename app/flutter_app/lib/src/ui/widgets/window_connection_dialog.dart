import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/window_connection.dart';
import 'package:my_dashboard/src/i18n/t.dart';
import 'package:my_dashboard/src/state/window_connections_provider.dart';
import 'package:my_dashboard/src/state/window_navigation_provider.dart';
import 'package:my_dashboard/src/util/project_path.dart';

const _dialogContentWidth = 560.0;
const _dialogContentMaxHeight = 620.0;
const _dialogScreenHeightFraction = 0.72;
const _identityMaxHeight = 240.0;
const _identityHeightFraction = 0.45;
const _targetHeaderKey = ValueKey('window-connection-target');
const _windowOptionsKey = ValueKey('window-connection-options');

/// Choosing a window does not mark an alert read. Only the caller's confirmed
/// native focus operation may do so. Saving a rule is an explicit action.
class WindowConnectionDialog extends ConsumerStatefulWidget {
  const WindowConnectionDialog({
    super.key,
    required this.connectionKey,
    required this.scan,
    this.project,
    this.host,
    this.rule,
    this.manageOnly = false,
    this.onShowSession,
  });

  final WindowConnectionKey? connectionKey;
  final WindowScan scan;
  // Partial alert identity is still useful even when it cannot form a saved key.
  final String? project;
  final String? host;
  final WindowConnectionRule? rule;
  final bool manageOnly;
  final VoidCallback? onShowSession;

  @override
  ConsumerState<WindowConnectionDialog> createState() =>
      _WindowConnectionDialogState();
}

class _WindowConnectionDialogState
    extends ConsumerState<WindowConnectionDialog> {
  final _pattern = TextEditingController();
  final _search = TextEditingController();
  final _identityScroll = ScrollController();
  final _optionsScroll = ScrollController();
  late WindowScan _scan;
  WindowCandidate? _selected;
  String? _bundleId;
  String? _appFilter;
  bool _exact = false;
  bool _remember = true;
  bool _showAll = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan = widget.scan;
    _bundleId = widget.rule?.bundleId;
    _pattern.text = widget.rule?.titlePattern ?? '';
    _exact = widget.rule?.exactTitle ?? false;
    _remember = widget.connectionKey != null;
    _showAll = widget.rule != null;
  }

  @override
  void dispose() {
    _pattern.dispose();
    _search.dispose();
    _identityScroll.dispose();
    _optionsScroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
      _selected = null;
    });
    try {
      final scan = await ref.read(windowScanProvider)(bundleId: _appFilter);
      if (mounted) setState(() => _scan = scan);
    } catch (_) {
      if (mounted) setState(() => _error = 'window.failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _select(WindowCandidate window) {
    final key = widget.connectionKey;
    final suggested = key == null
        ? const <WindowCandidate>[]
        : windowSuggestionsFor(key, [window]);
    setState(() {
      _selected = window;
      if (!(_rule()?.matches(window) ?? false)) {
        _pattern.text = suggested.isNotEmpty
            ? projectBasename(key!.project)
            : window.title;
        _exact = suggested.isEmpty;
      }
      _bundleId = window.bundleId;
      _error = null;
    });
  }

  WindowConnectionRule? _rule() {
    final key = widget.connectionKey;
    final bundle = _bundleId;
    if (key == null || bundle == null || _pattern.text.trim().isEmpty) {
      return null;
    }
    return WindowConnectionRule(
      key: key,
      bundleId: bundle,
      titlePattern: _pattern.text,
      exactTitle: _exact,
    );
  }

  Future<void> _submit({required bool open}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_remember || !open) {
        final rule = _rule();
        if (rule == null) {
          setState(() {
            _busy = false;
            _error = 'window.rule_required';
          });
          return;
        }
        await ref.read(windowConnectionsProvider.notifier).upsert(rule);
      }
      if (mounted) Navigator.of(context).pop(open ? _selected : null);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'window.save_failed';
        });
      }
    }
  }

  Widget _targetHeader(BuildContext context, String? project, String? host) {
    final theme = Theme.of(context);
    final unknown = t(ref, 'window.identity_unknown');
    return DecoratedBox(
      key: _targetHeaderKey,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t(ref, 'window.target_project'),
              style: theme.textTheme.labelMedium,
            ),
            Text(
              project == null ? unknown : projectBasename(project),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t(ref, 'window.alert_host'),
              style: theme.textTheme.labelMedium,
            ),
            SelectableText(host ?? unknown),
            const SizedBox(height: 8),
            Text(t(ref, 'window.project'), style: theme.textTheme.labelMedium),
            SelectableText(
              project ?? unknown,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              t(
                ref,
                widget.connectionKey == null
                    ? 'window.missing_identity'
                    : 'window.scope_note',
              ),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.connectionKey;
    final suggestions = key == null
        ? <WindowCandidate>[]
        : windowSuggestionsFor(key, _scan.windows);
    final candidates = _showAll || suggestions.isEmpty
        ? _scan.windows
        : suggestions;
    final query = _search.text.toLowerCase();
    final visible = candidates
        .where((w) => '${w.appName} ${w.title}'.toLowerCase().contains(query))
        .toList();
    final rule = _rule();
    final count = rule == null ? 0 : _scan.windows.where(rule.matches).length;
    final project =
        _knownIdentity(widget.project) ?? _knownIdentity(key?.project);
    final host = _knownIdentity(widget.host) ?? _knownIdentity(key?.host);
    final title = project == null
        ? t(ref, 'window.connect')
        : t(ref, 'window.connect_project', {
            'project': projectBasename(project),
          });
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Tooltip(
        message: title,
        child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      content: SizedBox(
        width: _dialogContentWidth,
        height:
            (MediaQuery.sizeOf(context).height * _dialogScreenHeightFraction)
                .clamp(0.0, _dialogContentMaxHeight),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (constraints.maxHeight * _identityHeightFraction)
                      .clamp(0.0, _identityMaxHeight),
                ),
                child: Scrollbar(
                  controller: _identityScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _identityScroll,
                    child: _targetHeader(context, project, host),
                  ),
                ),
              ),
              const Divider(height: 24),
              Expanded(
                child: Scrollbar(
                  controller: _optionsScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    key: _windowOptionsKey,
                    controller: _optionsScroll,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          t(ref, 'window.local_windows'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        if (!_scan.trusted) ...[
                          Text(t(ref, 'window.permission')),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => ref.read(
                                    windowAccessibilitySettingsProvider,
                                  )(),
                            child: Text(t(ref, 'window.open_settings')),
                          ),
                        ],
                        if (_scan.trusted && !_scan.complete)
                          Text(t(ref, 'window.partial')),
                        if (widget.rule != null)
                          Text(
                            t(ref, 'window.saved_rule', {
                              'app': widget.rule!.bundleId,
                              'title': widget.rule!.titlePattern,
                            }),
                          ),
                        if (_scan.applications.isNotEmpty)
                          DropdownButtonFormField<String>(
                            initialValue: _appFilter ?? '',
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: t(ref, 'window.application'),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(t(ref, 'window.all_apps')),
                              ),
                              if (_appFilter != null &&
                                  !_scan.applications.any(
                                    (app) => app.bundleId == _appFilter,
                                  ))
                                DropdownMenuItem(
                                  value: _appFilter,
                                  child: Text(_appFilter!),
                                ),
                              for (final app in _scan.applications)
                                DropdownMenuItem(
                                  value: app.bundleId,
                                  child: Text(app.appName),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (value) {
                                    setState(() {
                                      _appFilter = value == '' ? null : value;
                                      _showAll = true;
                                    });
                                    _refresh();
                                  },
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _search,
                                decoration: InputDecoration(
                                  labelText: t(ref, 'window.search'),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            IconButton(
                              tooltip: t(ref, 'window.refresh'),
                              onPressed: _busy ? null : _refresh,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                        if (suggestions.isNotEmpty)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(t(ref, 'window.show_all')),
                            value: _showAll,
                            onChanged: _busy
                                ? null
                                : (value) =>
                                      setState(() => _showAll = value ?? false),
                          ),
                        if (_busy) const LinearProgressIndicator(),
                        if (visible.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              t(
                                ref,
                                _scan.trusted
                                    ? 'window.none'
                                    : 'window.permission_retry',
                              ),
                            ),
                          ),
                        if (visible.isNotEmpty)
                          SizedBox(
                            height: 200,
                            child: ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final window = visible[index];
                                final selected =
                                    _selected?.token == window.token;
                                return ListTile(
                                  selected: selected,
                                  leading: Icon(
                                    selected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                  ),
                                  title: Text(
                                    window.title.isEmpty
                                        ? t(ref, 'window.untitled')
                                        : window.title,
                                  ),
                                  subtitle: Text(window.appName),
                                  onTap: _busy ? null : () => _select(window),
                                );
                              },
                            ),
                          ),
                        if (key != null) ...[
                          if (!widget.manageOnly)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(t(ref, 'window.remember')),
                              value: _remember,
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(
                                      () => _remember = value ?? false,
                                    ),
                            ),
                          if (_remember || widget.manageOnly) ...[
                            TextField(
                              controller: _pattern,
                              enabled: !_busy,
                              decoration: InputDecoration(
                                labelText: t(ref, 'window.title_pattern'),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(t(ref, 'window.exact')),
                              value: _exact,
                              onChanged: _busy
                                  ? null
                                  : (value) =>
                                        setState(() => _exact = value ?? false),
                            ),
                            Text(
                              t(ref, 'window.match_count', {'count': '$count'}),
                            ),
                            Text(
                              t(ref, 'window.rule_note'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(t(ref, _error!)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.onShowSession != null)
          TextButton(
            onPressed: _busy ? null : widget.onShowSession,
            child: Text(t(ref, 'window.show_session')),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t(ref, 'action.cancel')),
        ),
        if (widget.manageOnly)
          FilledButton(
            onPressed: _busy || rule == null
                ? null
                : () => _submit(open: false),
            child: Text(t(ref, 'action.save')),
          )
        else
          FilledButton(
            onPressed: _busy || _selected == null
                ? null
                : () => _submit(open: true),
            child: Text(
              t(ref, _remember ? 'window.save_and_open' : 'window.open'),
            ),
          ),
      ],
    );
  }
}

String? _knownIdentity(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}
