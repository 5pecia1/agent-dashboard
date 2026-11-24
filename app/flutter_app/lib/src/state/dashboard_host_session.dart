import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_dashboard/src/data/dashboard_api.dart';

/// An embedding application owns account selection, credential storage and refresh.
class DashboardHostSession {
  DashboardHostSession({
    required this.origin,
    required this.accessToken,
    required this.wrapApp,
    required this.connectionSettings,
  }) {
    final loopback =
        origin.scheme == 'http' &&
        const {'127.0.0.1', '::1', 'localhost'}.contains(origin.host);
    if ((!loopback && origin.scheme != 'https') ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        origin.hasQuery ||
        origin.hasFragment) {
      throw ArgumentError(
        'Expected an HTTPS dashboard origin or HTTP loopback.',
      );
    }
  }

  final Uri origin;

  /// Supply the current bearer for this account. After a 401, reuse a newer
  /// grant or refresh the rejected bearer. The host coalesces concurrent refreshes.
  /// Return null if the session has ended. Never return another account's grant.
  final Future<String?> Function({String? rejectedToken}) accessToken;

  /// Keep the supplied dashboard unmounted until authorized. Give it a new key
  /// when the account changes so its complete provider scope is disposed.
  final Widget Function(Widget dashboard) wrapApp;

  /// Replaces the manual connection fields inside the ordinary settings page.
  final WidgetBuilder connectionSettings;
}

final dashboardHostSessionProvider = Provider<DashboardHostSession?>(
  (ref) => null,
);

/// Only DashboardApi uses this transport. Other plugins have independent
/// credentials and continue to use their original HTTP transport.
HttpSendFn sessionTransport(
  DashboardHostSession session,
  HttpSendFn send, {
  required bool Function() active,
  required Duration timeout,
}) {
  Future<String?> token({String? rejected}) async {
    try {
      return await session.accessToken(rejectedToken: rejected);
    } on Object {
      // Underlying credential stores may include sensitive diagnostics.
      throw const DashboardNetworkFailure('Dashboard session is unavailable.');
    }
  }

  return (request) async {
    if (!active() ||
        !request.url.hasAuthority ||
        request.url.scheme != session.origin.scheme ||
        request.url.origin != session.origin.origin ||
        request.url.userInfo.isNotEmpty ||
        !request.url.path.startsWith('/dashboard/')) {
      throw const DashboardUnauthorized('Unavailable dashboard session.');
    }
    final clock = Stopwatch()..start();
    Future<ApiResponse> authorized(String? bearer) async {
      if (!active() || bearer == null || bearer.isEmpty) {
        throw const DashboardUnauthorized('A dashboard session is required.');
      }
      if (clock.elapsed >= timeout) {
        // The caller may already have reported its HTTP timeout while a
        // credential refresh was running. Do not issue a late mutation.
        throw const DashboardNetworkFailure(
          'Dashboard session request expired.',
        );
      }
      try {
        return await send(
          ApiRequest(
            method: request.method,
            url: request.url,
            headers: {...request.headers, 'Authorization': 'Bearer $bearer'},
            body: request.body,
            followRedirects: false,
          ),
        );
      } on Object {
        throw const DashboardNetworkFailure('Dashboard request failed.');
      }
    }

    final first = await token();
    var response = await authorized(first);
    if (response.statusCode == 401 && active() && clock.elapsed < timeout) {
      final refreshed = await token(rejected: first);
      if (request.method == 'GET' && refreshed != first) {
        response = await authorized(refreshed);
      }
    }
    if (!active()) {
      throw const DashboardUnauthorized('Unavailable dashboard session.');
    }
    // A response or exception from a host-managed authentication service can
    // echo its Authorization header. Status alone is sufficient to classify it.
    return response.isSuccess
        ? response
        : ApiResponse(statusCode: response.statusCode);
  };
}
