import json
import os
import socket
import sys
import time
import unicodedata

MAX_TITLE_CHARS = 120
MAX_RESPONSE_BYTES = 65536
LOOKUP_TIMEOUT_SECONDS = 0.25
REQUEST_ID = 'my-dashboard-title'
AGENTS = {
    'claude-code': ('claude', 'herdr:claude'),
    'codex': ('codex', 'herdr:codex'),
    'devin': ('devin', 'herdr:devin'),
    'grok': ('grok', 'herdr:grok'),
    'antigravity': ('agy', 'herdr:antigravity_cli'),
}


def normalize_title(value):
    if not isinstance(value, str):
        return None
    text = ' '.join(value.split())
    text = ''.join(c for c in text if unicodedata.category(c) not in ('Cc', 'Cf')).strip()
    return text[:MAX_TITLE_CHARS] or None


def title_from_pane(pane, source, session_id):
    expected = AGENTS.get(source)
    if not expected or not isinstance(pane, dict) or not session_id or session_id == 'unknown':
        return None
    agent, reporter = expected
    session = pane.get('agent_session')
    if pane.get('agent') != agent or not isinstance(session, dict):
        return None
    if (session.get('agent'), session.get('source'), session.get('kind'), session.get('value')) != (agent, reporter, 'id', session_id):
        return None
    for key in ('title', 'label', 'terminal_title_stripped'):
        title = normalize_title(pane.get(key))
        if title:
            return title
    return None


def lookup_title(source, session_id, environ=None):
    env = os.environ if environ is None else environ
    if env.get('MY_DASHBOARD_INCLUDE_CONTENT') != '1' or env.get('HERDR_ENV') != '1':
        return None
    socket_path, pane_id = env.get('HERDR_SOCKET_PATH'), env.get('HERDR_PANE_ID')
    if not socket_path or not pane_id or source not in AGENTS or not session_id or session_id == 'unknown' or not hasattr(socket, 'AF_UNIX'):
        return None
    deadline = time.monotonic() + LOOKUP_TIMEOUT_SECONDS
    request = {'id': REQUEST_ID, 'method': 'pane.current', 'params': {'caller_pane_id': pane_id}}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(max(0.001, deadline - time.monotonic()))
            client.connect(socket_path)
            client.settimeout(max(0.001, deadline - time.monotonic()))
            client.sendall((json.dumps(request) + '\n').encode())
            data = bytearray()
            while b'\n' not in data:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or len(data) >= MAX_RESPONSE_BYTES:
                    return None
                client.settimeout(remaining)
                chunk = client.recv(min(4096, MAX_RESPONSE_BYTES - len(data)))
                if not chunk:
                    return None
                data.extend(chunk)
        response = json.loads(bytes(data).split(b'\n', 1)[0])
        if not isinstance(response, dict) or response.get('id') != REQUEST_ID:
            return None
        result = response.get('result')
        if not isinstance(result, dict) or result.get('type') != 'pane_current':
            return None
        return title_from_pane(result.get('pane'), source, session_id)
    except (OSError, ValueError, TypeError):
        return None


if __name__ == '__main__':
    title = lookup_title(*sys.argv[1:]) if len(sys.argv) == 3 else None
    print(json.dumps({'display_title': title} if title else {}, ensure_ascii=False))
