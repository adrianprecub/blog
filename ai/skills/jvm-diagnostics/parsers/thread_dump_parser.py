#!/usr/bin/env python3
"""
Java Thread Dump parser.

Parses text-format Java thread dumps (from jstack, kill -3, VisualVM, etc.)
and produces structured JSON analysis with:
- Thread state summary
- Deadlock detection
- Thread pool utilization analysis
- Lock contention analysis
- Stack trace grouping

Usage:
    python3 thread_dump_parser.py <file.txt>

Supports multiple thread dumps in the same file (time-series analysis).
"""

import json
import re
import sys
import os
from collections import Counter, defaultdict
from datetime import datetime


def parse_thread_entry(lines):
    """Parse a single thread entry from a thread dump.
    
    A thread entry starts with a line like:
    "thread-name" #123 daemon prio=5 os_prio=0 cpu=12.34ms elapsed=567.89s tid=0x00007f... nid=0x1234 state [0x00007f...]
    
    Followed by:
       java.lang.Thread.State: RUNNABLE
       at com.example.MyClass.method(MyClass.java:42)
       - locked <0x00007f...> (a java.lang.Object)
       ...
    """
    if not lines:
        return None
    
    header = lines[0]
    
    # Parse thread name
    name_match = re.match(r'"([^"]*)"', header)
    if not name_match:
        return None
    
    thread = {
        'name': name_match.group(1),
        'daemon': 'daemon' in header,
        'state': None,
        'java_state': None,
        'stack_trace': [],
        'locks_held': [],
        'locks_waiting': [],
        'raw_header': header.strip()
    }
    
    # Parse thread ID
    tid_match = re.search(r'tid=(0x[0-9a-f]+)', header)
    if tid_match:
        thread['tid'] = tid_match.group(1)
    
    # Parse native ID
    nid_match = re.search(r'nid=(0x[0-9a-f]+)', header)
    if nid_match:
        thread['nid'] = nid_match.group(1)
    
    # Parse priority
    prio_match = re.search(r'prio=(\d+)', header)
    if prio_match:
        thread['priority'] = int(prio_match.group(1))
    
    # Parse CPU time
    cpu_match = re.search(r'cpu=([0-9.]+)ms', header)
    if cpu_match:
        thread['cpu_ms'] = float(cpu_match.group(1))
    
    # Parse elapsed time
    elapsed_match = re.search(r'elapsed=([0-9.]+)s', header)
    if elapsed_match:
        thread['elapsed_s'] = float(elapsed_match.group(1))
    
    # Parse OS thread state from header
    state_bracket = re.search(r'\b(runnable|sleeping|waiting on condition|in Object\.wait\(\)|blocked on monitor entry|waiting for monitor entry)\b', header, re.IGNORECASE)
    if state_bracket:
        thread['os_state'] = state_bracket.group(1)
    
    # Parse remaining lines
    for line in lines[1:]:
        stripped = line.strip()
        
        # Java thread state
        state_match = re.match(r'java\.lang\.Thread\.State:\s*(\S+)', stripped)
        if state_match:
            thread['java_state'] = state_match.group(1)
            continue
        
        # Stack frame
        frame_match = re.match(r'at\s+(.*)', stripped)
        if frame_match:
            thread['stack_trace'].append(frame_match.group(1))
            continue
        
        # Lock held
        locked_match = re.match(r'-\s*locked\s+<(0x[0-9a-f]+)>\s*\(a\s+(.*?)\)', stripped)
        if locked_match:
            thread['locks_held'].append({
                'address': locked_match.group(1),
                'class': locked_match.group(2)
            })
            continue
        
        # Waiting to lock
        waiting_match = re.match(r'-\s*waiting to lock\s+<(0x[0-9a-f]+)>\s*\(a\s+(.*?)\)', stripped)
        if waiting_match:
            thread['locks_waiting'].append({
                'address': waiting_match.group(1),
                'class': waiting_match.group(2)
            })
            continue
        
        # Parking / waiting on
        parking_match = re.match(r'-\s*parking to wait for\s+<(0x[0-9a-f]+)>\s*\(a\s+(.*?)\)', stripped)
        if parking_match:
            thread['locks_waiting'].append({
                'address': parking_match.group(1),
                'class': parking_match.group(2),
                'type': 'parking'
            })
            continue
        
        # Waiting on (Object.wait)
        objwait_match = re.match(r'-\s*waiting on\s+<(0x[0-9a-f]+)>\s*\(a\s+(.*?)\)', stripped)
        if objwait_match:
            thread['locks_waiting'].append({
                'address': objwait_match.group(1),
                'class': objwait_match.group(2),
                'type': 'object_wait'
            })
            continue
    
    # Determine effective state
    thread['state'] = thread['java_state'] or thread.get('os_state', 'UNKNOWN')
    
    return thread


def parse_thread_dump(text):
    """Parse a complete thread dump text into structured data."""
    lines = text.split('\n')
    
    # Find dump timestamp
    timestamp = None
    for line in lines[:10]:
        ts_match = re.search(r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})', line)
        if ts_match:
            timestamp = ts_match.group(1)
            break
    
    # Find JVM info line
    jvm_info = None
    for line in lines[:10]:
        if 'Full thread dump' in line:
            jvm_info = line.strip()
            break
    
    # Split into thread entries
    threads = []
    current_entry = []
    
    for line in lines:
        if line.startswith('"') and current_entry:
            # Start of new thread entry
            thread = parse_thread_entry(current_entry)
            if thread:
                threads.append(thread)
            current_entry = [line]
        elif line.startswith('"'):
            current_entry = [line]
        elif current_entry:
            if line.strip() == '' and len(current_entry) > 1:
                # Empty line might end a thread entry
                thread = parse_thread_entry(current_entry)
                if thread:
                    threads.append(thread)
                current_entry = []
            else:
                current_entry.append(line)
    
    # Don't forget the last entry
    if current_entry:
        thread = parse_thread_entry(current_entry)
        if thread:
            threads.append(thread)
    
    # Check for deadlock section
    deadlocks = []
    deadlock_section = False
    deadlock_text = []
    for line in lines:
        if 'Found one Java-level deadlock' in line or 'Found' in line and 'deadlock' in line.lower():
            deadlock_section = True
            continue
        if deadlock_section:
            if line.strip() == '' and deadlock_text:
                deadlocks.append('\n'.join(deadlock_text))
                deadlock_text = []
                deadlock_section = False
            else:
                deadlock_text.append(line)
    if deadlock_text:
        deadlocks.append('\n'.join(deadlock_text))
    
    return {
        'timestamp': timestamp,
        'jvm_info': jvm_info,
        'threads': threads,
        'deadlocks': deadlocks
    }


def detect_deadlocks(threads):
    """Detect deadlocks by analyzing lock ownership and waiting relationships."""
    # Build lock ownership map: lock_address -> thread_name
    lock_owners = {}
    for thread in threads:
        for lock in thread['locks_held']:
            lock_owners[lock['address']] = thread['name']
    
    # Find circular waits
    deadlock_chains = []
    for thread in threads:
        for lock in thread['locks_waiting']:
            owner = lock_owners.get(lock['address'])
            if owner and owner != thread['name']:
                # Thread is waiting for a lock held by `owner`
                # Check if `owner` is also waiting for a lock held by this thread
                owner_thread = next((t for t in threads if t['name'] == owner), None)
                if owner_thread:
                    for owner_waiting_lock in owner_thread['locks_waiting']:
                        owner_of_that = lock_owners.get(owner_waiting_lock['address'])
                        if owner_of_that == thread['name']:
                            deadlock_chains.append({
                                'thread_a': thread['name'],
                                'thread_b': owner,
                                'lock_a': lock['address'],
                                'lock_b': owner_waiting_lock['address'],
                                'lock_a_class': lock['class'],
                                'lock_b_class': owner_waiting_lock['class']
                            })
    
    return deadlock_chains


def analyze_thread_pools(threads):
    """Analyze thread pool utilization by grouping threads by name pattern."""
    pool_patterns = defaultdict(lambda: {'total': 0, 'states': Counter(), 'threads': []})
    
    for thread in threads:
        name = thread['name']
        # Extract pool name by removing trailing number
        pool_match = re.match(r'(.+?)[-#]?\d+$', name)
        pool_name = pool_match.group(1) if pool_match else name
        
        pool = pool_patterns[pool_name]
        pool['total'] += 1
        pool['states'][thread['state']] += 1
        pool['threads'].append({
            'name': name,
            'state': thread['state'],
            'top_frame': thread['stack_trace'][0] if thread['stack_trace'] else None
        })
    
    # Convert to serializable format
    result = {}
    for pool_name, pool_data in pool_patterns.items():
        if pool_data['total'] > 1:  # Only show actual pools
            result[pool_name] = {
                'total': pool_data['total'],
                'states': dict(pool_data['states']),
                'active': pool_data['states'].get('RUNNABLE', 0),
                'waiting': pool_data['states'].get('WAITING', 0) + pool_data['states'].get('TIMED_WAITING', 0),
                'blocked': pool_data['states'].get('BLOCKED', 0)
            }
    
    return result


def group_by_stack(threads):
    """Group threads by their top stack frames to identify common patterns."""
    stack_groups = defaultdict(list)
    for thread in threads:
        if thread['stack_trace']:
            key = tuple(thread['stack_trace'][:3])  # Top 3 frames
            stack_groups[key].append(thread['name'])
    
    result = []
    for frames, thread_names in sorted(stack_groups.items(), key=lambda x: -len(x[1])):
        if len(thread_names) > 1:
            result.append({
                'count': len(thread_names),
                'top_frames': list(frames),
                'threads': thread_names[:10],  # First 10 thread names
                'truncated': len(thread_names) > 10
            })
    
    return result


def analyze_dump(filepath):
    """Main analysis function for a thread dump file."""
    with open(filepath, 'r', errors='replace') as f:
        text = f.read()
    
    # Check if file contains multiple dumps
    dump_markers = [m.start() for m in re.finditer(r'Full thread dump', text)]
    
    dumps = []
    if len(dump_markers) > 1:
        for i, start in enumerate(dump_markers):
            end = dump_markers[i+1] if i+1 < len(dump_markers) else len(text)
            dump = parse_thread_dump(text[start:end])
            dumps.append(dump)
    else:
        dumps.append(parse_thread_dump(text))
    
    result = {
        'file': os.path.basename(filepath),
        'file_size_bytes': os.path.getsize(filepath),
        'dump_count': len(dumps),
        'dumps': []
    }
    
    for i, dump in enumerate(dumps):
        threads = dump['threads']
        
        # State summary
        state_counts = Counter(t['state'] for t in threads)
        
        # Daemon vs non-daemon
        daemon_count = sum(1 for t in threads if t['daemon'])
        
        # Lock analysis
        threads_holding_locks = [t for t in threads if t['locks_held']]
        threads_waiting_locks = [t for t in threads if t['locks_waiting']]
        
        # Deadlock detection
        detected_deadlocks = detect_deadlocks(threads)
        
        # Thread pool analysis
        pools = analyze_thread_pools(threads)
        
        # Stack grouping
        stack_groups = group_by_stack(threads)
        
        dump_analysis = {
            'index': i,
            'timestamp': dump['timestamp'],
            'jvm_info': dump['jvm_info'],
            'thread_count': len(threads),
            'daemon_count': daemon_count,
            'non_daemon_count': len(threads) - daemon_count,
            'state_summary': dict(state_counts.most_common()),
            'deadlocks_from_dump': dump['deadlocks'],
            'detected_deadlocks': detected_deadlocks,
            'threads_holding_locks': len(threads_holding_locks),
            'threads_waiting_for_locks': len(threads_waiting_locks),
            'thread_pools': pools,
            'stack_groups': stack_groups[:20],
            'threads': [{
                'name': t['name'],
                'state': t['state'],
                'daemon': t['daemon'],
                'cpu_ms': t.get('cpu_ms'),
                'locks_held_count': len(t['locks_held']),
                'locks_waiting_count': len(t['locks_waiting']),
                'stack_depth': len(t['stack_trace']),
                'top_frame': t['stack_trace'][0] if t['stack_trace'] else None,
                'locks_held': t['locks_held'][:5],
                'locks_waiting': t['locks_waiting'][:5]
            } for t in threads]
        }
        
        result['dumps'].append(dump_analysis)
    
    # Issue detection
    issues = []
    
    for dump_analysis in result['dumps']:
        # Deadlock
        if dump_analysis['detected_deadlocks'] or dump_analysis['deadlocks_from_dump']:
            issues.append({
                'severity': 'CRITICAL',
                'category': 'deadlock',
                'message': f"Deadlock detected in dump #{dump_analysis['index']}!",
                'details': dump_analysis['detected_deadlocks'] or dump_analysis['deadlocks_from_dump']
            })
        
        # High blocked thread count
        blocked = dump_analysis['state_summary'].get('BLOCKED', 0)
        total = dump_analysis['thread_count']
        if blocked > 0 and total > 0 and blocked / total > 0.25:
            issues.append({
                'severity': 'WARNING',
                'category': 'contention',
                'message': f"{blocked}/{total} threads ({blocked/total*100:.0f}%) in BLOCKED state in dump #{dump_analysis['index']}"
            })
        
        # Thread pool saturation
        for pool_name, pool_info in dump_analysis['thread_pools'].items():
            if pool_info['total'] > 5 and pool_info['active'] == pool_info['total']:
                issues.append({
                    'severity': 'WARNING',
                    'category': 'thread_pool',
                    'message': f"Thread pool '{pool_name}' appears fully saturated: all {pool_info['total']} threads are RUNNABLE"
                })
    
    # Cross-dump analysis (if multiple dumps)
    if len(result['dumps']) > 1:
        thread_counts = [d['thread_count'] for d in result['dumps']]
        if thread_counts[-1] > thread_counts[0] * 1.5:
            issues.append({
                'severity': 'WARNING',
                'category': 'thread_leak',
                'message': f"Thread count growing: {thread_counts[0]} -> {thread_counts[-1]} across {len(result['dumps'])} dumps"
            })
    
    result['issues'] = issues
    
    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 thread_dump_parser.py <file.txt>", file=sys.stderr)
        sys.exit(1)
    
    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    
    result = analyze_dump(filepath)
    print(json.dumps(result, indent=2, default=str))


if __name__ == '__main__':
    main()
