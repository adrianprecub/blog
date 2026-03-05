#!/usr/bin/env python3
"""
VisualVM Application Snapshot (.apps) parser.

VisualVM .apps files are ZIP archives containing monitoring data, profiling
snapshots, thread dumps, and JVM properties. This parser extracts and
structures all available data.

Usage:
    python3 visualvm_parser.py <file.apps>

File Structure:
    <snapshot>/
    ├── application.xml          # Application metadata
    ├── monitor.xml              # Monitor configuration
    ├── monitor/
    │   ├── heap.dat             # Heap time series (XYStorageSnapshot)
    │   ├── permgen.dat          # PermGen/Metaspace time series
    │   ├── classes.dat          # Class count time series
    │   ├── threads.dat          # Thread count time series
    │   └── cpu.dat              # CPU usage time series
    ├── nps/                     # Profiling snapshots
    ├── threaddump/              # Thread dump text files
    └── overview/
        └── jvm_properties.xml   # JVM system properties
"""

import json
import struct
import sys
import os
import zipfile
import tempfile
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone


def parse_xy_storage_dat(data, field_names=('value1', 'value2')):
    """Parse an XYStorageSnapshot .dat file.
    
    Format:
    - 31-byte header
    - Records of 24 bytes each:
      - 8 bytes: timestamp (ms since epoch, big-endian long)
      - 8 bytes: value1 (big-endian long)
      - 8 bytes: value2 (big-endian long)
    """
    records = []
    header_size = 31
    record_size = 24
    
    if len(data) < header_size:
        return records
    
    pos = header_size
    while pos + record_size <= len(data):
        try:
            timestamp, val1, val2 = struct.unpack('>qqq', data[pos:pos+record_size])
            
            # Validate timestamp (should be after year 2000 and before 2100)
            if 946684800000 < timestamp < 4102444800000:
                dt = datetime.fromtimestamp(timestamp / 1000, tz=timezone.utc)
                record = {
                    'timestamp': timestamp,
                    'time': dt.strftime('%H:%M:%S'),
                    'datetime': dt.isoformat(),
                    field_names[0]: val1,
                    field_names[1]: val2
                }
                records.append(record)
        except (struct.error, OSError, ValueError, OverflowError):
            pass
        
        pos += record_size
    
    return records


def parse_application_xml(xml_text):
    """Parse application.xml for application metadata."""
    try:
        root = ET.fromstring(xml_text)
        props = {}
        for entry in root.iter():
            if entry.text and entry.text.strip():
                tag = entry.tag.split('}')[-1] if '}' in entry.tag else entry.tag
                props[tag] = entry.text.strip()
            for attr_key, attr_val in entry.attrib.items():
                tag = entry.tag.split('}')[-1] if '}' in entry.tag else entry.tag
                props[f'{tag}@{attr_key}'] = attr_val
        return props
    except ET.ParseError:
        return {'raw': xml_text[:2000]}


def parse_jvm_properties_xml(xml_text):
    """Parse jvm_properties.xml for JVM system properties."""
    try:
        root = ET.fromstring(xml_text)
        props = {}
        for entry in root.iter():
            if entry.tag == 'entry' or entry.tag.endswith('}entry'):
                key = entry.get('key', '')
                value = entry.text or ''
                if key:
                    props[key] = value
            elif entry.tag == 'property' or entry.tag.endswith('}property'):
                name = entry.get('name', '')
                value = entry.get('value', entry.text or '')
                if name:
                    props[name] = value
        
        # Also try properties format
        if not props:
            for child in root:
                tag = child.tag.split('}')[-1] if '}' in child.tag else child.tag
                if child.text:
                    props[tag] = child.text.strip()
        
        return props
    except ET.ParseError:
        return {'raw': xml_text[:2000]}


def analyze_heap_data(records):
    """Analyze heap usage time series for patterns."""
    if not records:
        return {}
    
    used_values = [r['used'] for r in records if 'used' in r]
    capacity_values = [r['capacity'] for r in records if 'capacity' in r]
    
    if not used_values:
        return {'record_count': len(records)}
    
    analysis = {
        'record_count': len(records),
        'duration_seconds': (records[-1]['timestamp'] - records[0]['timestamp']) / 1000 if len(records) > 1 else 0,
        'used_min_mb': round(min(used_values) / (1024 * 1024), 1),
        'used_max_mb': round(max(used_values) / (1024 * 1024), 1),
        'used_avg_mb': round(sum(used_values) / len(used_values) / (1024 * 1024), 1),
    }
    
    if capacity_values:
        analysis['capacity_min_mb'] = round(min(capacity_values) / (1024 * 1024), 1)
        analysis['capacity_max_mb'] = round(max(capacity_values) / (1024 * 1024), 1)
    
    # Detect GC events (drops > 10MB)
    gc_events = []
    threshold = 10 * 1024 * 1024  # 10 MB
    for i in range(1, len(used_values)):
        drop = used_values[i-1] - used_values[i]
        if drop > threshold:
            gc_events.append({
                'time': records[i]['time'],
                'before_mb': round(used_values[i-1] / (1024 * 1024), 1),
                'after_mb': round(used_values[i] / (1024 * 1024), 1),
                'freed_mb': round(drop / (1024 * 1024), 1)
            })
    
    analysis['gc_events_detected'] = len(gc_events)
    if gc_events:
        freed_values = [e['freed_mb'] for e in gc_events]
        analysis['avg_freed_per_gc_mb'] = round(sum(freed_values) / len(freed_values), 1)
        analysis['gc_events_sample'] = gc_events[:10]  # First 10
        
        # Post-GC baseline trend (memory leak detection)
        post_gc = [e['after_mb'] for e in gc_events]
        if len(post_gc) >= 5:
            first_5_avg = sum(post_gc[:5]) / 5
            last_5_avg = sum(post_gc[-5:]) / 5
            growth = last_5_avg - first_5_avg
            analysis['post_gc_baseline_first5_mb'] = round(first_5_avg, 1)
            analysis['post_gc_baseline_last5_mb'] = round(last_5_avg, 1)
            analysis['post_gc_baseline_growth_mb'] = round(growth, 1)
            if growth > first_5_avg * 0.1:
                analysis['potential_memory_leak'] = True
            else:
                analysis['potential_memory_leak'] = False
    
    # Allocation rate
    if len(records) > 10:
        alloc_rates = []
        for i in range(1, len(used_values)):
            delta_bytes = used_values[i] - used_values[i-1]
            delta_ms = records[i]['timestamp'] - records[i-1]['timestamp']
            if delta_bytes > 0 and delta_ms > 0:
                rate_mb_s = (delta_bytes / (1024 * 1024)) / (delta_ms / 1000)
                alloc_rates.append(rate_mb_s)
        
        if alloc_rates:
            analysis['alloc_rate_avg_mb_s'] = round(sum(alloc_rates) / len(alloc_rates), 1)
            analysis['alloc_rate_max_mb_s'] = round(max(alloc_rates), 1)
    
    return analysis


def analyze_thread_data(records):
    """Analyze thread count time series."""
    if not records:
        return {}
    
    live_values = [r['live'] for r in records if 'live' in r]
    daemon_values = [r['daemon'] for r in records if 'daemon' in r]
    
    if not live_values:
        return {'record_count': len(records)}
    
    analysis = {
        'record_count': len(records),
        'live_min': min(live_values),
        'live_max': max(live_values),
        'live_avg': round(sum(live_values) / len(live_values), 1),
    }
    
    if daemon_values:
        analysis['daemon_min'] = min(daemon_values)
        analysis['daemon_max'] = max(daemon_values)
    
    # Thread count trend
    if len(live_values) >= 10:
        first_10_avg = sum(live_values[:10]) / 10
        last_10_avg = sum(live_values[-10:]) / 10
        if last_10_avg > first_10_avg * 1.5:
            analysis['thread_count_growing'] = True
        else:
            analysis['thread_count_growing'] = False
    
    return analysis


def analyze_cpu_data(records):
    """Analyze CPU usage time series."""
    if not records:
        return {}
    
    cpu_values = [r['cpu_percent'] for r in records if 'cpu_percent' in r]
    gc_values = [r['gc_percent'] for r in records if 'gc_percent' in r]
    
    if not cpu_values:
        return {'record_count': len(records)}
    
    analysis = {
        'record_count': len(records),
        'cpu_avg_percent': round(sum(cpu_values) / len(cpu_values), 1),
        'cpu_max_percent': round(max(cpu_values), 1),
    }
    
    if gc_values:
        analysis['gc_cpu_max_percent'] = round(max(gc_values), 1)
        analysis['gc_cpu_avg_percent'] = round(sum(gc_values) / len(gc_values), 2)
    
    # CPU distribution
    brackets = {'0-1%': 0, '1-5%': 0, '5-10%': 0, '10-20%': 0, '20-50%': 0, '50-100%': 0}
    for v in cpu_values:
        if v <= 1:
            brackets['0-1%'] += 1
        elif v <= 5:
            brackets['1-5%'] += 1
        elif v <= 10:
            brackets['5-10%'] += 1
        elif v <= 20:
            brackets['10-20%'] += 1
        elif v <= 50:
            brackets['20-50%'] += 1
        else:
            brackets['50-100%'] += 1
    analysis['distribution'] = brackets
    
    return analysis


def parse_visualvm(filepath):
    """Parse a VisualVM .apps snapshot file."""
    result = {
        'file': os.path.basename(filepath),
        'file_size_bytes': os.path.getsize(filepath),
        'file_size_mb': round(os.path.getsize(filepath) / (1024 * 1024), 2),
    }
    
    if not zipfile.is_zipfile(filepath):
        result['error'] = 'Not a valid ZIP file'
        return result
    
    with zipfile.ZipFile(filepath, 'r') as zf:
        namelist = zf.namelist()
        result['archive_entries'] = len(namelist)
        result['entry_list'] = namelist
        
        # Extract and parse each component
        for name in namelist:
            try:
                data = zf.read(name)
            except Exception as e:
                continue
            
            basename = os.path.basename(name)
            dirname = os.path.dirname(name)
            
            # Normalize basename: handle both flat (monitor_heap.dat) and
            # nested (monitor/heap.dat) layouts
            basename_lower = basename.lower()
            name_lower = name.lower()
            
            # Application XML
            if basename_lower == 'application.xml':
                result['application'] = parse_application_xml(data.decode('utf-8', errors='replace'))
            
            # JVM properties XML
            elif basename_lower in ('jvm_properties.xml', 'properties.xml'):
                result['jvm_properties'] = parse_jvm_properties_xml(data.decode('utf-8', errors='replace'))
            
            # Application snapshot properties (contains JMX data like thread counts, GC info)
            elif basename_lower.endswith('.properties') and 'application_snapshot' in basename_lower:
                result['snapshot_properties'] = parse_jvm_properties_xml(data.decode('utf-8', errors='replace'))
            
            # Monitor XML
            elif basename_lower == 'monitor.xml':
                result['monitor_config'] = parse_application_xml(data.decode('utf-8', errors='replace'))
            
            # Heap data: heap.dat, monitor_heap.dat, monitor/heap.dat
            # Note: In the XYStorageSnapshot format, value1=capacity, value2=used
            elif basename_lower in ('heap.dat', 'monitor_heap.dat') or name_lower.endswith('monitor/heap.dat'):
                records = parse_xy_storage_dat(data, ('capacity', 'used'))
                if records and 'heap_data' not in result:
                    result['heap_data'] = analyze_heap_data(records)
                    result['heap_data']['first_10_records'] = records[:10]
                    result['heap_data']['last_10_records'] = records[-10:] if len(records) > 10 else records
            
            # Metaspace/PermGen data
            elif basename_lower in ('permgen.dat', 'metaspace.dat', 'monitor_permgen.dat', 'monitor_metaspace.dat') or \
                 name_lower.endswith('monitor/permgen.dat') or name_lower.endswith('monitor/metaspace.dat'):
                records = parse_xy_storage_dat(data, ('used', 'capacity'))
                if records and 'metaspace_data' not in result:
                    used_vals = [r['used'] for r in records]
                    cap_vals = [r['capacity'] for r in records]
                    result['metaspace_data'] = {
                        'record_count': len(records),
                        'used_min_mb': round(min(used_vals) / (1024 * 1024), 1) if used_vals else 0,
                        'used_max_mb': round(max(used_vals) / (1024 * 1024), 1) if used_vals else 0,
                        'capacity_max_mb': round(max(cap_vals) / (1024 * 1024), 1) if cap_vals else 0,
                    }
            
            # Class data
            elif basename_lower in ('classes.dat', 'monitor_classes.dat') or name_lower.endswith('monitor/classes.dat'):
                records = parse_xy_storage_dat(data, ('loaded', 'shared_loaded'))
                if records and 'class_data' not in result:
                    loaded_vals = [r['loaded'] for r in records]
                    result['class_data'] = {
                        'record_count': len(records),
                        'loaded_min': min(loaded_vals) if loaded_vals else 0,
                        'loaded_max': max(loaded_vals) if loaded_vals else 0,
                    }
            
            # Thread monitor data: monitor_threads.dat or monitor/threads.dat
            # (NOT threads.dat at root which may be a different format)
            elif basename_lower == 'monitor_threads.dat' or name_lower.endswith('monitor/threads.dat'):
                records = parse_xy_storage_dat(data, ('live', 'daemon'))
                if records and 'thread_data' not in result:
                    result['thread_data'] = analyze_thread_data(records)
            
            # CPU data
            elif basename_lower in ('cpu.dat', 'monitor_cpu.dat') or name_lower.endswith('monitor/cpu.dat'):
                records = parse_xy_storage_dat(data, ('cpu_percent', 'gc_percent'))
                # CPU values might be in different units - check and normalize
                if records and 'cpu_data' not in result:
                    max_val = max(r['cpu_percent'] for r in records)
                    if max_val > 10000:
                        # Values are in 0.01% units (basis points)
                        for r in records:
                            r['cpu_percent'] = r['cpu_percent'] / 100
                            r['gc_percent'] = r['gc_percent'] / 100
                    elif max_val > 100:
                        # Values are in 0.1% units
                        for r in records:
                            r['cpu_percent'] = r['cpu_percent'] / 10
                            r['gc_percent'] = r['gc_percent'] / 10
                
                    result['cpu_data'] = analyze_cpu_data(records)
            
            # Thread dumps (.tdump or .txt files with threaddump in name/path)
            elif basename_lower.endswith('.tdump') or \
                 ('threaddump' in name_lower and basename_lower.endswith('.txt')):
                if 'thread_dumps' not in result:
                    result['thread_dumps'] = []
                text = data.decode('utf-8', errors='replace')
                result['thread_dumps'].append({
                    'name': name,
                    'size': len(data),
                    'preview': text[:2000]
                })
            
            # NPS profiling snapshots
            elif basename_lower.endswith('.nps') or basename_lower.endswith('.npss'):
                if 'profiling_snapshots' not in result:
                    result['profiling_snapshots'] = []
                result['profiling_snapshots'].append({
                    'name': name,
                    'size': len(data),
                    'format': 'NPS (NetBeans Profiler Snapshot)'
                })
    
    # Issue detection
    issues = []
    
    # Memory leak check
    heap = result.get('heap_data', {})
    if heap.get('potential_memory_leak'):
        issues.append({
            'severity': 'WARNING',
            'category': 'memory',
            'message': f"Potential memory leak: post-GC baseline grew from {heap.get('post_gc_baseline_first5_mb', '?')} MB to {heap.get('post_gc_baseline_last5_mb', '?')} MB"
        })
    
    # Thread leak check
    threads = result.get('thread_data', {})
    if threads.get('thread_count_growing'):
        issues.append({
            'severity': 'WARNING',
            'category': 'threads',
            'message': f"Thread count appears to be growing over time (min: {threads.get('live_min')}, max: {threads.get('live_max')})"
        })
    
    # High CPU check
    cpu = result.get('cpu_data', {})
    if cpu.get('cpu_avg_percent', 0) > 80:
        issues.append({
            'severity': 'WARNING',
            'category': 'cpu',
            'message': f"High average CPU usage: {cpu['cpu_avg_percent']}%"
        })
    
    # GC overhead check
    if cpu.get('gc_cpu_avg_percent', 0) > 5:
        issues.append({
            'severity': 'WARNING',
            'category': 'gc',
            'message': f"High GC CPU overhead: {cpu['gc_cpu_avg_percent']}% average"
        })
    
    result['issues'] = issues
    
    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 visualvm_parser.py <file.apps>", file=sys.stderr)
        sys.exit(1)
    
    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    
    result = parse_visualvm(filepath)
    print(json.dumps(result, indent=2, default=str))


if __name__ == '__main__':
    main()
