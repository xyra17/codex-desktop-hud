import importlib.util
import json
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tracker', ROOT / 'Sources' / 'tracker.py')
tracker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tracker)


def row(typ, payload, timestamp='2026-10-22T10:26:00Z'):
    return {'type': typ, 'payload': payload, 'timestamp': timestamp}


def make_log(path, origin='Codex Desktop', used=28, plan=None):
    events = [
        row('session_meta', {'originator': origin, 'id': 'test'}),
        row('event_msg', {'type': 'task_started'}),
        row('response_item', {'type': 'message', 'role': 'user'}),
        row('response_item', {'type': 'function_call', 'name': 'shell_command', 'call_id': '1'}),
        row('response_item', {'type': 'function_call_output', 'call_id': '1'}),
        row('response_item', {'type': 'custom_tool_call', 'call_id': '2'}),
        row('response_item', {'type': 'web_search_call'}),
        row('event_msg', {'type': 'token_count', 'info': {'model_context_window': 100000,
            'total_token_usage': {'input_tokens': 50000, 'cached_input_tokens': 40000},
            'last_token_usage': {'input_tokens': 25000, 'output_tokens': 3000, 'reasoning_output_tokens': 1000}},
            'rate_limits': {'primary': {'used_percent': used, 'window_minutes': 300},
                            'secondary': {'used_percent': 59, 'window_minutes': 10080}}}),
        row('event_msg', {'type': 'token_count', 'info': {'model_context_window': 100000,
            'total_token_usage': {'input_tokens': 100000, 'cached_input_tokens': 99000},
            'last_token_usage': {'input_tokens': 45000, 'output_tokens': 2000, 'reasoning_output_tokens': 1000}}}),
        row('event_msg', {'type': 'task_complete'}),
        row('event_msg', {'type': 'task_started'}),
        row('response_item', {'type': 'function_call', 'call_id': '3'}),
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(json.dumps(x) for x in events) + '\n', encoding='utf-8')


class TestParser(unittest.TestCase):
    def test_turns_and_steps_and_cache(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'a.jsonl'
            make_log(p)
            data = tracker.parse_session(p)
            self.assertEqual(data['turns'], 2)
            self.assertEqual(data['steps'], 4)
            self.assertEqual(data['cache_percent'], 99)
            self.assertEqual(data['context_percent'], 46)  # 45K input + 1K visible output
            self.assertEqual(data['local_limits']['five_hour'], 72)
            self.assertEqual(data['local_limits']['weekly'], 41)

    def test_context_not_cumulative_tokens(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'b.jsonl'
            make_log(p)
            data = tracker.parse_session(p)
            self.assertNotEqual(data['context_percent'], 100)
            self.assertEqual(data['last_context_tokens'], 46000)

    def test_duration_not_slot_order(self):
        rate = {'primary': {'usedPercent': 25, 'windowDurationMins': 10080},
                'secondary': {'usedPercent': 61, 'windowDurationMins': 300}}
        self.assertEqual(tracker.classify_limits(rate), {'five_hour': 39, 'weekly': 75})

    def test_no_five_hour(self):
        rate = {'rateLimits': {'primary': {'usedPercent': 11, 'windowDurationMins': 10080}}}
        self.assertEqual(tracker.classify_limits(rate), {'five_hour': None, 'weekly': 89})

    def test_multi_bucket_prefers_main_codex(self):
        r = {'rateLimitsByLimitId': {
            'codex_other': {'primary': {'usedPercent': 80, 'windowDurationMins': 300}},
            'codex': {'primary': {'usedPercent': 40, 'windowDurationMins': 300},
                      'secondary': {'usedPercent': 25, 'windowDurationMins': 10080}}}}
        self.assertEqual(tracker.classify_limits(r), {'five_hour': 60, 'weekly': 75})

    def test_five_hour_reset_uses_matching_bucket(self):
        reset = 1792734827
        rate = {'rateLimitsByLimitId': {
            'other': {'primary': {'usedPercent': 2, 'windowDurationMins': 300, 'resetsAt': reset + 99}},
            'codex': {'primary': {'usedPercent': 11, 'windowDurationMins': 10080, 'resetsAt': reset + 500},
                      'secondary': {'usedPercent': 73, 'windowDurationMins': 300, 'resetsAt': reset}}}}
        parsed = tracker.classify_limits(rate)
        self.assertEqual(parsed['five_hour_resets_at'], reset)
        self.assertEqual(parsed['five_hour'], 27)
        self.assertEqual(parsed['weekly'], 89)
        snake = {'primary': {'used_percent': 73, 'window_minutes': 300, 'resets_at': reset}}
        self.assertEqual(tracker.classify_limits(snake)['five_hour_resets_at'], reset)

    def test_invalid_and_missing_reset_are_not_invented(self):
        for value in [None, False, 'invalid', -1, 0, 1792734827000]:
            limits = {'primary': {'usedPercent': 73, 'windowDurationMins': 300, 'resetsAt': value}}
            self.assertNotIn('five_hour_resets_at', tracker.classify_limits(limits))

    def test_snapshot_preserves_reset_from_api_and_recent_log(self):
        reset = 1792734827
        with patch.object(tracker, 'selected_session', return_value=(None, 'none')), patch.object(
                tracker, 'read_cache', return_value={'ok': True, 'fetched_at': time.time(),
                                                   'five_hour': 27, 'five_hour_resets_at': reset}):
            self.assertEqual(tracker.snapshot()['five_hour_resets_at'], reset)
        with patch.object(tracker, 'selected_session', return_value=(Path('unused'), 'desktop')), patch.object(
                tracker, 'read_cache', return_value={}), patch.object(tracker, 'parse_session', return_value={
                    'local_limits_timestamp': time.time(), 'local_limits': {'five_hour': 27, 'five_hour_resets_at': reset}}):
            snapshot = tracker.snapshot()
            self.assertEqual(snapshot['five_hour_resets_at'], reset)
            self.assertEqual(snapshot['quota_source'], 'recent-session-log')

    def test_desktop_preferred_over_more_recent_cli(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            desktop = root / 'sessions' / '2026' / '10' / '21' / 'rollout-old.jsonl'
            cli = root / 'sessions' / '2026' / '10' / '22' / 'rollout-new.jsonl'
            make_log(desktop, 'Codex Desktop')
            time.sleep(.01)
            make_log(cli, 'codex_exec')
            self.assertEqual(tracker.find_session(root), (desktop, 'desktop'))

    def test_binding_and_ambiguous_titles(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            first = home / 'sessions' / 'rollout-first.jsonl'
            second = home / 'sessions' / 'rollout-second.jsonl'
            make_log(first)
            make_log(second)
            with sqlite3.connect(home / 'state_5.sqlite') as conn:
                conn.execute('CREATE TABLE threads (id TEXT, title TEXT, rollout_path TEXT, source TEXT, archived INTEGER, updated_at INTEGER)')
                conn.executemany('INSERT INTO threads VALUES (?, ?, ?, ?, 0, 1)', [
                    ('a', 'Unique chat', str(first), 'desktop'),
                    ('b', 'Other chat', str(second), 'desktop')])
            self.assertEqual(tracker.selected_session(home, 'a', None), (first, 'bound-session'))
            self.assertEqual(tracker.selected_session(home, None, 'Unique chat'), (first, 'window-title'))
            self.assertEqual(tracker.selected_session(home, 'missing', None), (None, 'binding-unavailable'))
            with sqlite3.connect(home / 'state_5.sqlite') as conn:
                conn.execute("UPDATE threads SET title='Unique chat'")
            self.assertEqual(tracker.selected_session(home, None, 'Unique chat')[1], 'desktop')
            first.unlink()
            self.assertEqual(tracker.selected_session(home, 'a', None), (None, 'binding-unavailable'))

    def test_skip_subagent(self):
        self.assertEqual(tracker.source_kind({'source': {'subagent': {'thread_spawn': {}}}}), 'subagent')

    def test_bad_log_no_crash(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'err.jsonl'
            p.write_bytes(b'garbage\n{"type": "event_msg", "payload": {"type": "task_started"}}\n')
            self.assertEqual(tracker.parse_session(p)['turns'], 1)
            self.assertIsNone(tracker.parse_session(p)['cache_percent'])

    def test_no_data_is_not_zero(self):
        self.assertIsNone(tracker.pct_left(None))
        self.assertIsNone(tracker.number('Not a number'))

    def test_complement_used_percentage(self):
        self.assertEqual(tracker.pct_left(11.4), 89)
        self.assertEqual(tracker.pct_left(109), 0)
        self.assertEqual(tracker.pct_left(-4), 100)


if __name__ == '__main__':
    unittest.main()

class TestLiveIntegration(unittest.TestCase):
    def test_incremental_cache_append_and_incomplete_line(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            old_dir, old_path = tracker.CACHE_DIR, tracker.METRICS_CACHE
            tracker.CACHE_DIR, tracker.METRICS_CACHE = root, root / 'metrics.json'
            try:
                p = root / 'rollout-test.jsonl'
                make_log(p)
                first = tracker.parse_session(p, use_cache=True)
                self.assertEqual(first['turns'], 2)
                self.assertEqual(tracker.parse_session(p, use_cache=True), first)
                with p.open('ab') as f:
                    f.write(b'{"type":"event_msg","payload":{"type":"task_started"}')
                still = tracker.parse_session(p, use_cache=True)
                self.assertEqual(still['turns'], 2)
                with p.open('ab') as f:
                    f.write(b'}\n')
                updated = tracker.parse_session(p, use_cache=True)
                self.assertEqual(updated['turns'], 3)
                self.assertEqual(updated['steps'], 4)
                self.assertEqual(updated['cache_percent'], 99)
            finally:
                tracker.CACHE_DIR, tracker.METRICS_CACHE = old_dir, old_path

    def test_appserver_handshake_integration(self):
        with tempfile.TemporaryDirectory() as d:
            binary = Path(d) / 'fake_codex'
            code = '''#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    item = json.loads(line)
    ident = item.get('id')
    if ident == 1:
        reply = {'id':1, 'result':{'userAgent':'fake'}}
    elif ident == 2:
        reply = {'id':2, 'result':{'account':{'type':'chatgpt','planType':'plus'}}}
    elif ident == 3:
        reply = {'id':3, 'result':{'rateLimits':{'primary':{'usedPercent':20,'windowDurationMins':300,'resetsAt':1792734827},'secondary':{'usedPercent':60,'windowDurationMins':10080}}}}
    else:
        continue
    print(json.dumps(reply), flush=True)
'''
            binary.write_text(code, encoding='utf-8')
            binary.chmod(0o755)
            result = tracker.appserver_quota(str(binary), timeout=4)
            self.assertTrue(result['ok'])
            self.assertEqual(result['plan'], 'plus')
            self.assertEqual(result['five_hour'], 80)
            self.assertEqual(result['weekly'], 40)
            self.assertEqual(result['five_hour_resets_at'], 1792734827)
