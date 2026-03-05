#!/usr/bin/env python3
"""
JVM Garbage Collection log parser.

Parses GC log files from both unified logging (JDK 9+, -Xlog:gc*)
and legacy format (JDK 8, -verbose:gc -XX:+PrintGCDetails).

Outputs structured JSON with GC event analysis, pause time statistics,
throughput calculation, and memory leak detection.

Usage:
    python3 gc_log_parser.py <gc.log>

Supported formats:
- Unified logging (JDK 9+): [timestamp][level][tags] messages
- Legacy logging (JDK 8): timestamp: [GC ...] or [Full GC ...]
- G1GC, Parallel GC, CMS, ZGC, Shenandoah, Serial GC
"""

import json
import re
import sys
import os
from collections import Counter, defaultdict
from datetime import datetime


def parse_size(s):
    """Parse a JVM size string like '512M', '1024K', '1G' to bytes."""
    s = s.strip()
    match = re.match(r'([0-9.]+)\s*([KMGT]?)(B?)', s, re.IGNORECASE)
    if not match:
        return None
    value = float(match.group(1))
    unit = match.group(2).upper()
    multipliers = {'': 1, 'K': 1024, 'M': 1024*1024, 'G': 1024*1024*1024, 'T': 1024*1024*1024*1024}
    return int(value * multipliers.get(unit, 1))


def parse_duration(s):
    """Parse a duration string like '15.234ms', '0.123s' to milliseconds."""
    s = s.strip()
    match = re.match(r'([0-9.]+)\s*(ms|s|us|ns)', s, re.IGNORECASE)
    if not match:
        return None
    value = float(match.group(1))
    unit = match.group(2).lower()
    if unit == 's':
        return value * 1000
    elif unit == 'ms':
        return value
    elif unit == 'us':
        return value / 1000
    elif unit == 'ns':
        return value / 1_000_000
    return value


def parse_unified_gc_line(line):
    """Parse a unified logging GC line (JDK 9+).
    
    Examples:
    [2024-01-15T10:30:45.123+0000][12345][gc] GC(42) Pause Young (Normal) (G1 Evacuation Pause) 512M->128M(1024M) 15.234ms
    [2024-01-15T10:30:45.123+0000][12345][gc,heap] GC(42) Eden: 384M...
    """
    event = {}
    
    # Parse timestamp
    ts_match = re.search(r'\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+\-]\d{4})\]', line)
    if ts_match:
        event['timestamp'] = ts_match.group(1)
        try:
            dt = datetime.fromisoformat(ts_match.group(1))
            event['epoch_ms'] = int(dt.timestamp() * 1000)
        except (ValueError, AttributeError):
            pass
    
    # Parse uptime-based timestamp
    uptime_match = re.search(r'\[(\d+\.\d+)s\]', line)
    if uptime_match:
        event['uptime_s'] = float(uptime_match.group(1))
    
    # Parse GC event number
    gc_num_match = re.search(r'GC\((\d+)\)', line)
    if gc_num_match:
        event['gc_number'] = int(gc_num_match.group(1))
    
    # Parse GC type
    if 'Pause Young' in line:
        event['type'] = 'young'
    elif 'Pause Full' in line or 'Full GC' in line:
        event['type'] = 'full'
    elif 'Pause Remark' in line:
        event['type'] = 'remark'
    elif 'Pause Cleanup' in line:
        event['type'] = 'cleanup'
    elif 'Pause Initial Mark' in line:
        event['type'] = 'initial_mark'
    elif 'Concurrent' in line:
        event['type'] = 'concurrent'
    else:
        event['type'] = 'other'
    
    # Parse cause
    cause_match = re.search(r'\((Allocation Failure|System\.gc\(\)|Metadata GC Threshold|G1 Evacuation Pause|G1 Humongous Allocation|G1 Compaction Pause|Ergonomics|GCLocker Initiated GC|Heap Inspection|Heap Dump|CMS Final Remark|CMS Initial Mark)\)', line)
    if cause_match:
        event['cause'] = cause_match.group(1)
    
    # Parse heap sizes: before->after(total)
    heap_match = re.search(r'(\d+[KMGT]?B?)\s*->\s*(\d+[KMGT]?B?)\s*\((\d+[KMGT]?B?)\)', line)
    if heap_match:
        before = parse_size(heap_match.group(1))
        after = parse_size(heap_match.group(2))
        total = parse_size(heap_match.group(3))
        if before is not None and after is not None:
            event['heap_before_bytes'] = before
            event['heap_after_bytes'] = after
            event['heap_total_bytes'] = total
            event['heap_before_mb'] = round(before / (1024*1024), 1)
            event['heap_after_mb'] = round(after / (1024*1024), 1)
            event['heap_total_mb'] = round(total / (1024*1024), 1)
            event['freed_bytes'] = before - after
            event['freed_mb'] = round((before - after) / (1024*1024), 1)
    
    # Parse pause time
    pause_match = re.search(r'(\d+\.\d+)ms\s*$', line)
    if pause_match:
        event['pause_ms'] = float(pause_match.group(1))
    else:
        pause_match2 = re.search(r'(\d+\.\d+)s\s*$', line)
        if pause_match2:
            event['pause_ms'] = float(pause_match2.group(1)) * 1000
    
    # Parse collector name from tags
    if '[gc,start]' in line or '[gc]' in line:
        event['is_gc_event'] = True
    
    # Detect collector
    if 'G1' in line:
        event['collector'] = 'G1'
    elif 'ParNew' in line or 'ParOldGen' in line or 'PSYoungGen' in line:
        event['collector'] = 'Parallel'
    elif 'CMS' in line:
        event['collector'] = 'CMS'
    elif 'ZGC' in line or 'Z Garbage Collector' in line:
        event['collector'] = 'ZGC'
    elif 'Shenandoah' in line:
        event['collector'] = 'Shenandoah'
    elif 'DefNew' in line or 'SerialOld' in line or 'Tenured' in line:
        event['collector'] = 'Serial'
    
    return event if event.get('gc_number') is not None or event.get('is_gc_event') else None


def parse_legacy_gc_line(line):
    """Parse a legacy GC log line (JDK 8).
    
    Examples:
    2024-01-15T10:30:45.123+0000: 1234.567: [GC (Allocation Failure) [PSYoungGen: 524288K->65536K(589824K)] 786432K->327680K(1048576K), 0.0152340 secs]
    """
    event = {}
    
    # Parse timestamp
    ts_match = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+\-]\d{4})', line)
    if ts_match:
        event['timestamp'] = ts_match.group(1)
    
    # Parse uptime
    uptime_match = re.search(r':\s*(\d+\.\d+):\s*\[', line)
    if uptime_match:
        event['uptime_s'] = float(uptime_match.group(1))
    
    # GC type
    if '[Full GC' in line:
        event['type'] = 'full'
    elif '[GC' in line:
        event['type'] = 'young'
    else:
        return None
    
    # Cause
    cause_match = re.search(r'\((Allocation Failure|System\.gc\(\)|Metadata GC Threshold|Ergonomics|GCLocker Initiated GC)\)', line)
    if cause_match:
        event['cause'] = cause_match.group(1)
    
    # Collector
    if 'PSYoungGen' in line or 'ParOldGen' in line:
        event['collector'] = 'Parallel'
    elif 'ParNew' in line:
        event['collector'] = 'ParNew'
    elif 'DefNew' in line:
        event['collector'] = 'Serial'
    elif 'CMS' in line:
        event['collector'] = 'CMS'
    
    # Heap sizes (total): before->after(total)
    # Match the last occurrence which is the total heap
    heap_matches = re.findall(r'(\d+)K\s*->\s*(\d+)K\s*\((\d+)K\)', line)
    if heap_matches:
        last = heap_matches[-1]
        before_kb = int(last[0])
        after_kb = int(last[1])
        total_kb = int(last[2])
        event['heap_before_bytes'] = before_kb * 1024
        event['heap_after_bytes'] = after_kb * 1024
        event['heap_total_bytes'] = total_kb * 1024
        event['heap_before_mb'] = round(before_kb / 1024, 1)
        event['heap_after_mb'] = round(after_kb / 1024, 1)
        event['heap_total_mb'] = round(total_kb / 1024, 1)
        event['freed_mb'] = round((before_kb - after_kb) / 1024, 1)
    
    # Pause time
    pause_match = re.search(r'(\d+\.\d+)\s*secs?\]', line)
    if pause_match:
        event['pause_ms'] = float(pause_match.group(1)) * 1000
    
    return event if event.get('type') else None


def parse_gc_log(filepath):
    """Parse a GC log file and produce structured analysis."""
    with open(filepath, 'r', errors='replace') as f:
        lines = f.readlines()
    
    result = {
        'file': os.path.basename(filepath),
        'file_size_bytes': os.path.getsize(filepath),
        'total_lines': len(lines),
    }
    
    # Detect format
    is_unified = False
    is_legacy = False
    for line in lines[:50]:
        if re.match(r'\[\d{4}-\d{2}-\d{2}T', line) or re.match(r'\[\d+\.\d+s\]', line):
            is_unified = True
            break
        if re.search(r'\d{4}-\d{2}-\d{2}T.*:\s*\d+\.\d+:\s*\[', line):
            is_legacy = True
            break
    
    result['format'] = 'unified' if is_unified else ('legacy' if is_legacy else 'unknown')
    
    # Parse events
    gc_events = []
    collector = None
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        event = None
        if is_unified:
            event = parse_unified_gc_line(line)
        elif is_legacy:
            event = parse_legacy_gc_line(line)
        
        if event:
            gc_events.append(event)
            if event.get('collector') and not collector:
                collector = event['collector']
    
    result['collector'] = collector
    result['total_gc_events'] = len(gc_events)
    
    if not gc_events:
        result['analysis'] = {'note': 'No GC events found in log'}
        return result
    
    # Categorize events
    young_gcs = [e for e in gc_events if e.get('type') == 'young']
    full_gcs = [e for e in gc_events if e.get('type') == 'full']
    
    result['young_gc_count'] = len(young_gcs)
    result['full_gc_count'] = len(full_gcs)
    
    # Pause time analysis
    all_pauses = [e['pause_ms'] for e in gc_events if 'pause_ms' in e]
    young_pauses = [e['pause_ms'] for e in young_gcs if 'pause_ms' in e]
    full_pauses = [e['pause_ms'] for e in full_gcs if 'pause_ms' in e]
    
    if all_pauses:
        sorted_pauses = sorted(all_pauses)
        result['pause_time'] = {
            'total_ms': round(sum(all_pauses), 2),
            'total_s': round(sum(all_pauses) / 1000, 2),
            'min_ms': round(min(all_pauses), 2),
            'max_ms': round(max(all_pauses), 2),
            'avg_ms': round(sum(all_pauses) / len(all_pauses), 2),
            'median_ms': round(sorted_pauses[len(sorted_pauses)//2], 2),
            'p90_ms': round(sorted_pauses[int(len(sorted_pauses)*0.9)], 2),
            'p99_ms': round(sorted_pauses[int(len(sorted_pauses)*0.99)], 2) if len(sorted_pauses) >= 100 else round(sorted_pauses[-1], 2),
        }
        
        if young_pauses:
            result['pause_time']['young_avg_ms'] = round(sum(young_pauses) / len(young_pauses), 2)
            result['pause_time']['young_max_ms'] = round(max(young_pauses), 2)
        
        if full_pauses:
            result['pause_time']['full_avg_ms'] = round(sum(full_pauses) / len(full_pauses), 2)
            result['pause_time']['full_max_ms'] = round(max(full_pauses), 2)
    
    # Throughput calculation
    total_duration = None
    if gc_events[0].get('uptime_s') is not None and gc_events[-1].get('uptime_s') is not None:
        total_duration = (gc_events[-1]['uptime_s'] - gc_events[0]['uptime_s'])
    elif gc_events[0].get('epoch_ms') is not None and gc_events[-1].get('epoch_ms') is not None:
        total_duration = (gc_events[-1]['epoch_ms'] - gc_events[0]['epoch_ms']) / 1000
    
    if total_duration and total_duration > 0 and all_pauses:
        total_pause_s = sum(all_pauses) / 1000
        throughput = ((total_duration - total_pause_s) / total_duration) * 100
        result['throughput'] = {
            'percent': round(throughput, 3),
            'gc_overhead_percent': round(100 - throughput, 3),
            'total_duration_s': round(total_duration, 1),
            'total_pause_s': round(total_pause_s, 2)
        }
        
        # GC frequency
        result['frequency'] = {
            'gc_per_minute': round(len(gc_events) / (total_duration / 60), 1),
            'young_per_minute': round(len(young_gcs) / (total_duration / 60), 1) if young_gcs else 0,
            'full_per_minute': round(len(full_gcs) / (total_duration / 60), 1) if full_gcs else 0,
        }
    
    # Heap analysis
    heap_events = [e for e in gc_events if 'heap_before_mb' in e]
    if heap_events:
        before_values = [e['heap_before_mb'] for e in heap_events]
        after_values = [e['heap_after_mb'] for e in heap_events]
        freed_values = [e['freed_mb'] for e in heap_events]
        
        result['heap'] = {
            'before_min_mb': round(min(before_values), 1),
            'before_max_mb': round(max(before_values), 1),
            'after_min_mb': round(min(after_values), 1),
            'after_max_mb': round(max(after_values), 1),
            'freed_avg_mb': round(sum(freed_values) / len(freed_values), 1),
            'freed_total_mb': round(sum(freed_values), 1),
        }
        
        if heap_events[0].get('heap_total_mb'):
            result['heap']['total_mb'] = heap_events[0]['heap_total_mb']
        
        # Memory leak detection: post-GC baseline trend
        if len(after_values) >= 10:
            first_5 = after_values[:5]
            last_5 = after_values[-5:]
            first_avg = sum(first_5) / 5
            last_avg = sum(last_5) / 5
            growth = last_avg - first_avg
            result['heap']['post_gc_baseline_first5_mb'] = round(first_avg, 1)
            result['heap']['post_gc_baseline_last5_mb'] = round(last_avg, 1)
            result['heap']['post_gc_baseline_growth_mb'] = round(growth, 1)
            result['heap']['potential_memory_leak'] = growth > first_avg * 0.1
    
    # GC cause distribution
    causes = Counter(e.get('cause', 'unknown') for e in gc_events)
    result['cause_distribution'] = dict(causes.most_common())
    
    # Sample events (first 10, last 10)
    result['sample_events'] = {
        'first_10': gc_events[:10],
        'last_10': gc_events[-10:] if len(gc_events) > 10 else gc_events
    }
    
    # Issue detection
    issues = []
    
    # High GC overhead
    if result.get('throughput', {}).get('gc_overhead_percent', 0) > 5:
        overhead = result['throughput']['gc_overhead_percent']
        severity = 'CRITICAL' if overhead > 10 else 'WARNING'
        issues.append({
            'severity': severity,
            'category': 'gc_overhead',
            'message': f"GC overhead is {overhead}% (threshold: 5% WARNING, 10% CRITICAL)"
        })
    
    # Long GC pauses
    if result.get('pause_time', {}).get('max_ms', 0) > 500:
        max_pause = result['pause_time']['max_ms']
        issues.append({
            'severity': 'WARNING',
            'category': 'gc_pause',
            'message': f"Maximum GC pause time is {max_pause:.0f}ms (threshold: 500ms)"
        })
    
    # Frequent Full GCs
    if result.get('frequency', {}).get('full_per_minute', 0) > 1:
        freq = result['frequency']['full_per_minute']
        issues.append({
            'severity': 'WARNING',
            'category': 'full_gc',
            'message': f"Frequent Full GCs: {freq:.1f}/minute (threshold: 1/minute)"
        })
    
    # Memory leak
    if result.get('heap', {}).get('potential_memory_leak'):
        growth = result['heap']['post_gc_baseline_growth_mb']
        issues.append({
            'severity': 'WARNING',
            'category': 'memory_leak',
            'message': f"Potential memory leak: post-GC heap baseline grew by {growth:.1f}MB over the log period"
        })
    
    # Promotion failure indicator: post-full-GC still high
    if full_gcs:
        post_full = [e['heap_after_mb'] for e in full_gcs if 'heap_after_mb' in e and 'heap_total_mb' in e]
        totals = [e['heap_total_mb'] for e in full_gcs if 'heap_total_mb' in e]
        if post_full and totals:
            fill_ratio = post_full[-1] / totals[-1] if totals[-1] > 0 else 0
            if fill_ratio > 0.8:
                issues.append({
                    'severity': 'CRITICAL',
                    'category': 'heap_exhaustion',
                    'message': f"Heap nearly full after Full GC: {post_full[-1]:.0f}MB / {totals[-1]:.0f}MB ({fill_ratio*100:.0f}% full)"
                })
    
    result['issues'] = issues
    
    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 gc_log_parser.py <gc.log>", file=sys.stderr)
        sys.exit(1)
    
    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    
    result = parse_gc_log(filepath)
    print(json.dumps(result, indent=2, default=str))


if __name__ == '__main__':
    main()
