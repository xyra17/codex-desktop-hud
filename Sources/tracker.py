#!/usr/bin/env python3
"""Local Codex Desktop HUD sampler. Stdlib only; never stores conversation text."""
from __future__ import annotations
import argparse
import glob
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import sys
import time
from typing import Any

CODEX_HOME = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser()
CACHE_DIR = Path(os.environ.get('CODEX_HUD_CACHE_DIR', str(Path.home() / 'Library' / 'Caches' / 'CodexDesktopHUD'))).expanduser()
QUOTA_CACHE = CACHE_DIR / 'quota.json'
METRICS_CACHE = CACHE_DIR / 'metrics.json'


def number(x: Any) -> float | None:
    try:
        if x is None or isinstance(x, bool):
            return None
        v = float(x)
        if v != v or not -1e12 < v < 1e12:
            return None
        return v
    except (ValueError, TypeError):
        return None


def pct_left(value: Any) -> int | None:
    v = number(value)
    return None if v is None else round(max(0, min(100, 100 - v)))


def classify_limits(data: Any) -> dict:
    """Classify *by actual window duration*, never primary/secondary position."""
    out = {'five_hour': None, 'weekly': None}
    if not isinstance(data, dict):
        return out
    candidates = [data]
    by_id = data.get('rateLimitsByLimitId') or data.get('rate_limits_by_limit_id')
    if isinstance(by_id, dict):
        # Prefer the main Codex bucket over other metered buckets.
        candidates = [by_id['codex']] if isinstance(by_id.get('codex'), dict) else []
        if not candidates:
            candidates = list(by_id.values())
    if isinstance(data.get('rateLimits'), dict):
        candidates.append(data['rateLimits'])
    for item in candidates:
        if not isinstance(item, dict):
            continue
        for key in ('primary', 'secondary'):
            win = item.get(key)
            if not isinstance(win, dict):
                continue
            duration = number(win.get('windowDurationMins', win.get('window_minutes')))
            left = pct_left(win.get('usedPercent', win.get('used_percent')))
            if left is None or duration is None:
                continue
            if 270 <= duration <= 330 and out['five_hour'] is None:
                out['five_hour'] = left
            elif 9800 <= duration <= 10400 and out['weekly'] is None:
                out['weekly'] = left
    return out


def source_kind(meta: dict) -> str:
    if not isinstance(meta, dict):
        return 'unknown'
    origin = str(meta.get('originator') or '').lower()
    src = meta.get('source') or meta.get('thread_source') or ''
    if isinstance(src, dict):
        src = json.dumps(src, ensure_ascii=False)
    src = str(src).lower()
    if ('subagent' in src or meta.get('parent_thread_id') or
        (isinstance(meta.get('source'), dict) and 'subagent' in json.dumps(meta['source']).lower())):
        return 'subagent'
    if any(s in origin for s in ('desktop', 'codex_app')) or 'desktop' in src:
        return 'desktop'
    if 'vscode' in origin or 'vscode' in src:
        return 'vscode'
    if any(s in origin for s in ('exec', 'cli', 'terminal')):
        return 'cli'
    return 'unknown'


def session_meta(path: Path) -> dict:
    try:
        with path.open('rb') as f:
            for _ in range(8):
                line = f.readline(262144)
                if not line:
                    break
                data = json.loads(line)
                if data.get('type') == 'session_meta':
                    return data.get('payload') or {}
    except (OSError, ValueError, UnicodeDecodeError):
        pass
    return {}


def find_session(home: Path = CODEX_HOME) -> tuple[Path | None, str]:
    # Active files can be under old dated folders: do not filter folders by date.
    candidates = []
    roots = [home / 'sessions', home / 'archived_sessions']
    for root in roots:
        if not root.is_dir():
            continue
        for filename in glob.iglob(str(root / '**' / 'rollout-*.jsonl'), recursive=True):
            try:
                p = Path(filename)
                st = p.stat()
                if st.st_size > 0:
                    candidates.append((st.st_mtime, p))
            except OSError:
                pass
    candidates.sort(key=lambda p: p[0], reverse=True)
    # Try latest plausible sessions. Explicit desktop takes priority even if recent CLI exists.
    fallback = None
    for _, p in candidates[:100]:
        kind = source_kind(session_meta(p))
        if kind == 'desktop':
            return p, 'desktop'
        if kind not in ('subagent', 'vscode') and fallback is None:
            fallback = p
    return (fallback, 'fallback') if fallback else (None, 'none')


def listed_sessions(home: Path = CODEX_HOME) -> list[dict]:
    """Read only the desktop thread index; never open auth or conversation bodies."""
    databases = sorted(home.glob('state_*.sqlite'), key=lambda p: p.stat().st_mtime, reverse=True)
    for database in databases:
        try:
            with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=0.2) as conn:
                conn.row_factory = sqlite3.Row
                rows = conn.execute("SELECT id, title, rollout_path, source FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 200").fetchall()
            return [dict(row) for row in rows
                    if source_kind(session_meta(Path(row['rollout_path']))) == 'desktop']
        except (sqlite3.Error, OSError):
            continue
    return []


def selected_session(home: Path, thread_id: str | None, title: str | None) -> tuple[Path | None, str]:
    if not thread_id and not title:
        return find_session(home)
    sessions = listed_sessions(home)
    matches = [s for s in sessions if s['id'] == thread_id] if thread_id else [
        s for s in sessions if s['title'].strip() == title.strip()]
    if len(matches) == 1 and Path(matches[0]['rollout_path']).is_file():
        return Path(matches[0]['rollout_path']), 'bound-session' if thread_id else 'window-title'
    # Explicit binding must never silently display another chat's metrics.
    return (None, 'binding-unavailable') if thread_id else find_session(home)


def parse_session(path: Path, use_cache: bool = False) -> dict:
    # Resume from byte offset so frequent polls don't repeatedly scan large rollouts.
    # Only counters and last usage snapshots are persisted; never prompt or code text.
    cache = {}
    start = 0
    st = path.stat()
    if use_cache:
        try:
            previous = json.loads(METRICS_CACHE.read_text('utf-8'))
            if (previous.get('path') == str(path) and
                previous.get('identity') == [st.st_dev, st.st_ino] and
                isinstance(previous.get('offset'), int) and
                0 <= previous['offset'] <= st.st_size):
                if (previous.get('size') == st.st_size and
                    previous.get('mtime_ns') == st.st_mtime_ns):
                    return previous['metrics']
                # Incremental only on append; same-size edits require a full scan.
                if st.st_size > previous['offset']:
                    cache = previous.get('state') or {}
                    start = previous['offset']
        except (OSError, ValueError, TypeError, KeyError):
            pass
    turns = cache.get('turns', 0)
    messages = cache.get('messages', 0)
    steps = cache.get('steps', 0)
    input_total = cache.get('input_total')
    cached_total = cache.get('cached_total')
    window = cache.get('window')
    last_context_tokens = cache.get('last_context_tokens')
    latest_limits = cache.get('latest_limits')
    latest_limits_timestamp = cache.get('latest_limits_timestamp')
    context_source = cache.get('context_source')
    end_offset = start
    try:
        with path.open('rb') as f:
            f.seek(start)
            while True:
                pos = f.tell()
                raw = f.readline()
                if not raw:
                    break
                # Hold on to incomplete trailing JSONL record until the writer finishes.
                if not raw.endswith(b'\n'):
                    break
                end_offset = f.tell()
                try:
                    item = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    continue
                typ = item.get('type')
                event = item.get('payload') or {}
                if not isinstance(event, dict):
                    continue
                evtype = event.get('type')
                if typ == 'event_msg' and evtype == 'task_started':
                    turns += 1
                if typ == 'response_item':
                    if evtype == 'message' and event.get('role') == 'user':
                        messages += 1
                    if evtype in ('function_call', 'custom_tool_call', 'web_search_call'):
                        steps += 1
                if typ == 'event_msg' and evtype == 'token_count':
                    info = event.get('info') or {}
                    if not isinstance(info, dict):
                        info = {}
                    total = info.get('total_token_usage') or {}
                    last = info.get('last_token_usage') or {}
                    if not isinstance(total, dict):
                        total = {}
                    if not isinstance(last, dict):
                        last = {}
                    if number(total.get('input_tokens')) is not None:
                        input_total = max(0, number(total['input_tokens']))
                    if number(total.get('cached_input_tokens')) is not None:
                        cached_total = max(0, number(total['cached_input_tokens']))
                    w = number(info.get('model_context_window'))
                    if w and w > 0:
                        window = w
                    # Last response's input is the nearest available approximation
                    # to live context. Session cumulative input is NOT context.
                    last_input = number(last.get('input_tokens'))
                    last_output = number(last.get('output_tokens'))
                    reasoning = number(last.get('reasoning_output_tokens'))
                    if last_input is not None:
                        last_context_tokens = max(0, last_input + max(0, (last_output or 0) - (reasoning or 0)))
                        context_source = 'last_model_usage'
                    limits = event.get('rate_limits') or event.get('rateLimits')
                    if isinstance(limits, dict):
                        parsed = classify_limits(limits)
                        if parsed['five_hour'] is not None or parsed['weekly'] is not None:
                            latest_limits = parsed
                            ts = item.get('timestamp')
                            if isinstance(ts, str):
                                try:
                                    from datetime import datetime
                                    latest_limits_timestamp = datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
                                except ValueError:
                                    pass
    except OSError:
        pass
    cache_pct = None
    if input_total is not None and input_total > 0 and cached_total is not None:
        cache_pct = round(max(0, min(100, cached_total / input_total * 100)))
    context_pct = None
    if last_context_tokens is not None and window is not None and window > 0:
        context_pct = round(max(0, min(100, last_context_tokens / window * 100)))
    try:
        updated = path.stat().st_mtime
    except OSError:
        updated = None
    metrics = {
        'turns': turns if turns > 0 else messages if messages > 0 else None,
        'steps': steps,
        'cache_percent': cache_pct,
        'context_percent': context_pct,
        'context_estimated': context_pct is not None,
        'context_window_tokens': int(window) if window else None,
        'last_context_tokens': int(last_context_tokens) if last_context_tokens is not None else None,
        'last_usage_source': context_source,
        'session_updated_at': updated,
        'session_filename': path.name,
        'local_limits': latest_limits,
        'local_limits_timestamp': latest_limits_timestamp,
    }
    if use_cache:
        state = {'turns': turns, 'messages': messages, 'steps': steps,
                 'input_total': input_total, 'cached_total': cached_total,
                 'window': window, 'last_context_tokens': last_context_tokens,
                 'latest_limits': latest_limits, 'latest_limits_timestamp': latest_limits_timestamp,
                 'context_source': context_source}
        entry = {'path': str(path), 'identity': [st.st_dev, st.st_ino],
                 'size': st.st_size, 'mtime_ns': st.st_mtime_ns,
                 'offset': end_offset, 'state': state, 'metrics': metrics}
        try:
            safe_write_json(METRICS_CACHE, entry)
        except OSError:
            pass
    return metrics


def resolve_binary() -> str | None:
    override = os.environ.get('CODEX_HUD_BINARY')
    paths = [override] if override else [
        '/Applications/Codex.app/Contents/Resources/codex',
        '/Applications/ChatGPT.app/Contents/Resources/codex',
        str(Path.home() / 'Applications' / 'Codex.app' / 'Contents' / 'Resources' / 'codex'),
        str(Path.home() / 'Applications' / 'ChatGPT.app' / 'Contents' / 'Resources' / 'codex'),
        shutil.which('codex'),
    ]
    return next((p for p in paths if p and Path(p).is_file() and os.access(p, os.X_OK)), None)


def appserver_quota(binary: str, timeout: float = 12.0) -> dict:
    proc = subprocess.Popen([binary, 'app-server', '--listen', 'stdio://'],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    def send(obj: dict) -> None:
        assert proc.stdin
        proc.stdin.write((json.dumps(obj, separators=(',', ':')) + '\n').encode())
        proc.stdin.flush()
    def receive(deadline: float, ids: set[int]) -> dict[int, dict]:
        assert proc.stdout
        results: dict[int, dict] = {}
        buf = b''
        fd = proc.stdout.fileno()
        while time.monotonic() < deadline and not ids.issubset(results):
            try:
                rd, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
                if not rd:
                    break
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                buf += chunk
                while b'\n' in buf:
                    line, buf = buf.split(b'\n', 1)
                    try:
                        v = json.loads(line)
                        if isinstance(v, dict) and v.get('id') in ids:
                            results[v['id']] = v
                    except ValueError:
                        pass
            except (OSError, ValueError):
                break
        return results
    try:
        deadline = time.monotonic() + timeout
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'codex_desktop_hud', 'title': 'Codex Desktop HUD', 'version': '0.3.0'}}})
        init = receive(deadline, {1}).get(1)
        if not init or 'error' in init:
            raise RuntimeError('app-server initialize failed')
        send({'method': 'initialized', 'params': {}})
        send({'id': 2, 'method': 'account/read', 'params': {'refreshToken': False}})
        send({'id': 3, 'method': 'account/rateLimits/read'})
        res = receive(deadline, {2, 3})
        account = (res.get(2, {}).get('result') or {}).get('account') or {}
        rate_result = res.get(3, {}).get('result') or {}
        if not isinstance(account, dict):
            account = {}
        plan = account.get('planType')
        limits = classify_limits(rate_result)
        if not rate_result or 'error' in res.get(3, {}):
            return {'ok': False, 'error': 'rate limits unavailable', 'plan': plan, **limits}
        return {'ok': True, 'plan': plan, **limits}
    finally:
        try:
            if proc.stdin:
                proc.stdin.close()
            proc.terminate()
            proc.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()
            proc.wait()
        finally:
            if proc.stdout:
                proc.stdout.close()


def safe_write_json(dest: Path, data: dict) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = dest.with_name(dest.name + '.tmp.' + str(os.getpid()))
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(target, dest)
    finally:
        try:
            target.unlink()
        except FileNotFoundError:
            pass


def write_cache(data: dict) -> None:
    safe_write_json(QUOTA_CACHE, data)


def read_cache() -> dict:
    try:
        return json.loads(QUOTA_CACHE.read_text('utf-8'))
    except (OSError, ValueError):
        return {}


def refresh_quota() -> dict:
    binary = resolve_binary()
    result = {'ok': False, 'plan': None, 'five_hour': None, 'weekly': None}
    if not binary:
        result['error'] = 'Codex App bundled CLI not found'
    else:
        try:
            result = appserver_quota(binary)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
            result['error'] = str(e)[:180]
    result['fetched_at'] = time.time()
    try:
        write_cache(result)
    except OSError:
        pass
    return result


def snapshot(thread_id: str | None = None, title: str | None = None) -> dict:
    path, kind = selected_session(CODEX_HOME, thread_id, title)
    data = parse_session(path, use_cache=True) if path else {
        'turns': None, 'steps': None, 'cache_percent': None,
        'context_percent': None, 'context_estimated': False,
        'local_limits': None, 'local_limits_timestamp': None,
        'session_filename': None, 'session_updated_at': None,
    }
    quota = read_cache()
    age = time.time() - (number(quota.get('fetched_at')) or 0)
    # Live API data is authoritative for quota and plan, even if the session is old.
    if quota.get('ok') and 0 <= age < 600:
        limits = {'five_hour': quota.get('five_hour'), 'weekly': quota.get('weekly')}
        quota_source = 'app-server'
        plan = quota.get('plan')
    else:
        loc_age = time.time() - (number(data.get('local_limits_timestamp')) or 0)
        if 0 <= loc_age < 900 and isinstance(data.get('local_limits'), dict):
            limits = data['local_limits']
            quota_source = 'recent-session-log'
        else:
            limits = {'five_hour': None, 'weekly': None}
            quota_source = 'unavailable'
        plan = None
    return {'source': kind, 'plan': plan,
            'five_hour': limits.get('five_hour'), 'weekly': limits.get('weekly'),
            'quota_source': quota_source,
            'turns': data.get('turns'), 'steps': data.get('steps'),
            'context_percent': data.get('context_percent'),
            'context_estimated': data.get('context_estimated', False),
            'cache_percent': data.get('cache_percent'),
            'session_filename': data.get('session_filename'),
            'session_updated_at': data.get('session_updated_at')}


def main() -> None:
    parser = argparse.ArgumentParser(description='Codex Desktop HUD data collector')
    parser.add_argument('--thread-id', help='bind metrics to a desktop thread id')
    parser.add_argument('--window-title', help='match a unique desktop thread title')
    parser.add_argument('--sessions', action='store_true', help='list desktop threads for explicit binding')
    parser.add_argument('--quota', action='store_true', help='refresh account quota from local app-server')
    parser.add_argument('--doctor', action='store_true', help='print local diagnosis')
    parser.add_argument('--demo', action='store_true', help='print example data')
    args = parser.parse_args()
    if args.sessions:
        out = {'sessions': listed_sessions()}
    elif args.demo:
        out = {'source': 'demo', 'plan': 'pro', 'turns': 35, 'steps': 1203,
               'context_percent': 47, 'context_estimated': True, 'cache_percent': 99,
               'five_hour': 72, 'weekly': 41, 'quota_source': 'demo'}
    elif args.quota:
        out = refresh_quota()
    elif args.doctor:
        path, kind = find_session()
        out = {'python': sys.version.split()[0], 'codex_home': str(CODEX_HOME),
               'session': str(path) if path else None, 'source': kind,
               'app_server_binary': resolve_binary(), 'cache': str(QUOTA_CACHE),
               'snapshot': snapshot()}
    else:
        out = snapshot(args.thread_id, args.window_title)
    print(json.dumps(out, ensure_ascii=False, separators=(',', ':')))

if __name__ == '__main__':
    main()
