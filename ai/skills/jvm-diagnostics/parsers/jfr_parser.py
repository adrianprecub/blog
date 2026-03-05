#!/usr/bin/env python3
"""
JFR (Java Flight Recorder) binary parser.

Parses .jfr files without requiring the JDK `jfr` command-line tool.
Outputs structured JSON to stdout with event summaries, thread analysis,
GC analysis, and other JVM diagnostics data.

Usage:
    python3 jfr_parser.py <file.jfr>

JFR Binary Format (JDK 9+):
- File consists of one or more "chunks"
- Each chunk has a 68-byte header, followed by events, constant pool, and metadata
- Integers are encoded as LEB128 (variable-length)
- The metadata section defines event types and their fields
- The constant pool stores shared values (strings, threads, stack traces, etc.)
"""

import json
import struct
import sys
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone


# --- LEB128 decoding ---

def read_leb128(data, offset):
    """Read a LEB128-encoded unsigned integer from data at offset.
    Returns (value, new_offset)."""
    result = 0
    shift = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
        if shift > 63:
            break
    return result, offset


def read_signed_leb128(data, offset):
    """Read a LEB128-encoded signed integer."""
    result = 0
    shift = 0
    size = 64
    byte = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if (byte & 0x80) == 0:
            break
        if shift > 63:
            break
    if shift < size and (byte & 0x40):
        result |= -(1 << shift)
    return result, offset


# --- Chunk header parsing ---

JFR_MAGIC = b'FLR\x00'

def parse_chunk_header(data, offset=0):
    """Parse a JFR chunk header (68 bytes).
    Returns dict with header fields and new offset."""
    if len(data) < offset + 68:
        return None, offset
    magic = data[offset:offset+4]
    if magic != JFR_MAGIC:
        return None, offset
    header = {}
    header['magic'] = magic
    header['major_version'] = struct.unpack('>H', data[offset+4:offset+6])[0]
    header['minor_version'] = struct.unpack('>H', data[offset+6:offset+8])[0]
    header['chunk_size'] = struct.unpack('>Q', data[offset+8:offset+16])[0]
    header['constant_pool_offset'] = struct.unpack('>Q', data[offset+16:offset+24])[0]
    header['metadata_offset'] = struct.unpack('>Q', data[offset+24:offset+32])[0]
    header['start_time_nanos'] = struct.unpack('>Q', data[offset+32:offset+40])[0]
    header['duration_nanos'] = struct.unpack('>Q', data[offset+40:offset+48])[0]
    header['start_ticks'] = struct.unpack('>Q', data[offset+48:offset+56])[0]
    header['ticks_per_second'] = struct.unpack('>Q', data[offset+56:offset+64])[0]
    header['features'] = struct.unpack('>I', data[offset+64:offset+68])[0]
    header['chunk_start_offset'] = offset
    return header, offset + 68


# --- Metadata parsing ---

def parse_metadata_element(data, offset):
    """Parse a metadata element (recursive structure).
    Returns (element, new_offset)."""
    name_index, offset = read_leb128(data, offset)
    attr_count, offset = read_leb128(data, offset)
    attributes = {}
    for _ in range(attr_count):
        key_index, offset = read_leb128(data, offset)
        value_index, offset = read_leb128(data, offset)
        attributes[key_index] = value_index
    child_count, offset = read_leb128(data, offset)
    children = []
    for _ in range(child_count):
        child, offset = parse_metadata_element(data, offset)
        children.append(child)
    return {
        'name_index': name_index,
        'attributes': attributes,
        'children': children
    }, offset


def parse_metadata_section(data, chunk_header):
    """Parse the metadata section to extract event type definitions."""
    meta_offset = chunk_header['chunk_start_offset'] + chunk_header['metadata_offset']
    if meta_offset >= len(data):
        return {}, []
    
    # Metadata event header
    event_size, pos = read_leb128(data, meta_offset)
    event_type, pos = read_leb128(data, pos)
    start_ticks, pos = read_leb128(data, pos)
    duration, pos = read_leb128(data, pos)
    metadata_id, pos = read_leb128(data, pos)
    
    # String table
    string_count, pos = read_leb128(data, pos)
    strings = []
    for _ in range(string_count):
        str_encoding = data[pos]
        pos += 1
        if str_encoding == 0:  # null
            strings.append(None)
        elif str_encoding == 1:  # empty
            strings.append("")
        elif str_encoding == 3:  # UTF-8 with length prefix
            str_len, pos = read_leb128(data, pos)
            s = data[pos:pos+str_len].decode('utf-8', errors='replace')
            pos += str_len
            strings.append(s)
        elif str_encoding == 4:  # char array
            str_len, pos = read_leb128(data, pos)
            chars = []
            for _ in range(str_len):
                c, pos = read_leb128(data, pos)
                chars.append(chr(c))
            strings.append(''.join(chars))
        elif str_encoding == 5:  # latin1
            str_len, pos = read_leb128(data, pos)
            s = data[pos:pos+str_len].decode('latin-1', errors='replace')
            pos += str_len
            strings.append(s)
        else:
            strings.append(f"<encoding_{str_encoding}>")
    
    # Root element
    root_element, pos = parse_metadata_element(data, pos)
    
    return strings, root_element


def resolve_metadata_strings(element, strings):
    """Resolve string indices in metadata elements to actual strings."""
    name = strings[element['name_index']] if element['name_index'] < len(strings) else f"idx_{element['name_index']}"
    attrs = {}
    for k, v in element['attributes'].items():
        key = strings[k] if k < len(strings) else f"idx_{k}"
        val = strings[v] if v < len(strings) else f"idx_{v}"
        attrs[key] = val
    children = [resolve_metadata_strings(c, strings) for c in element['children']]
    return {
        'name': name,
        'attributes': attrs,
        'children': children
    }


def extract_event_types(resolved_metadata):
    """Extract event type definitions from resolved metadata.
    Returns dict mapping type_id -> {name, fields}."""
    event_types = {}
    
    def walk(node):
        if node['name'] == 'class' and 'id' in node['attributes']:
            type_id = int(node['attributes']['id'])
            type_name = node['attributes'].get('name', f'type_{type_id}')
            fields = []
            for child in node['children']:
                if child['name'] == 'field':
                    fields.append({
                        'name': child['attributes'].get('name', ''),
                        'type': child['attributes'].get('class', ''),
                        'constantPool': child['attributes'].get('constantPool', 'false') == 'true'
                    })
            event_types[type_id] = {
                'name': type_name,
                'fields': fields
            }
        for child in node['children']:
            walk(child)
    
    walk(resolved_metadata)
    return event_types


# --- Constant pool parsing ---

def parse_constant_pool(data, chunk_header, event_types):
    """Parse the constant pool to extract shared values (strings, threads, etc.)."""
    cp_offset = chunk_header['chunk_start_offset'] + chunk_header['constant_pool_offset']
    if cp_offset >= len(data) or cp_offset == chunk_header['chunk_start_offset']:
        return {}
    
    constants = {}
    pos = cp_offset
    
    try:
        event_size, pos = read_leb128(data, pos)
        event_type, pos = read_leb128(data, pos)
        start_ticks, pos = read_leb128(data, pos)
        duration, pos = read_leb128(data, pos)
        delta, pos = read_leb128(data, pos)
        flush, pos = read_leb128(data, pos)
        pool_count, pos = read_leb128(data, pos)
        
        for _ in range(pool_count):
            if pos >= len(data):
                break
            type_id, pos = read_leb128(data, pos)
            entry_count, pos = read_leb128(data, pos)
            
            type_info = event_types.get(type_id, {})
            type_name = type_info.get('name', f'type_{type_id}')
            fields = type_info.get('fields', [])
            
            if type_id not in constants:
                constants[type_id] = {}
            
            for _ in range(entry_count):
                if pos >= len(data):
                    break
                key, pos = read_leb128(data, pos)
                
                # Read field values
                field_values = {}
                for field in fields:
                    val, pos = read_leb128(data, pos)
                    field_values[field['name']] = val
                
                constants[type_id][key] = field_values
    except Exception:
        pass
    
    return constants


# --- Event parsing ---

def parse_events(data, chunk_header, event_types):
    """Parse events from a chunk. Returns list of (type_id, raw_values) tuples."""
    events = []
    event_start = chunk_header['chunk_start_offset'] + 68  # after header
    
    # Events go up to the constant pool or metadata (whichever comes first)
    cp_off = chunk_header['constant_pool_offset']
    meta_off = chunk_header['metadata_offset']
    if cp_off == 0:
        cp_off = meta_off
    if meta_off == 0:
        meta_off = cp_off
    event_end = chunk_header['chunk_start_offset'] + min(cp_off, meta_off)
    
    pos = event_start
    max_events = 500000  # safety limit
    count = 0
    
    while pos < event_end and count < max_events:
        if pos >= len(data):
            break
        
        event_size, size_end = read_leb128(data, pos)
        if event_size == 0:
            pos += 1
            continue
        
        event_data_start = size_end
        next_event = pos + event_size
        
        if next_event > event_end or next_event > len(data):
            break
        
        try:
            type_id, field_pos = read_leb128(data, event_data_start)
            
            type_info = event_types.get(type_id)
            if type_info:
                # Read field values
                field_values = {}
                for field in type_info.get('fields', []):
                    if field_pos >= next_event:
                        break
                    val, field_pos = read_leb128(data, field_pos)
                    field_values[field['name']] = val
                
                events.append((type_id, type_info['name'], field_values))
        except Exception:
            pass
        
        pos = next_event
        count += 1
    
    return events


# --- Analysis functions ---

def analyze_thread_events(events, ticks_per_second, start_ticks, start_time_nanos):
    """Analyze thread start/end events for thread churn detection."""
    thread_starts = []
    thread_ends = []
    thread_names = Counter()
    parent_threads = Counter()
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.ThreadStart':
            thread_starts.append(fields)
            thread_name = fields.get('thread', 0)
            parent = fields.get('parentThread', 0)
            thread_names[thread_name] += 1
            parent_threads[parent] += 1
        elif type_name == 'jdk.ThreadEnd':
            thread_ends.append(fields)
    
    return {
        'total_starts': len(thread_starts),
        'total_ends': len(thread_ends),
        'unique_thread_ids': len(thread_names),
        'top_parent_threads': parent_threads.most_common(20),
        'thread_churn': len(thread_starts) > 100 and len(thread_ends) > len(thread_starts) * 0.9
    }


def analyze_gc_events(events):
    """Analyze GC events for pause times, frequency, and heap usage."""
    gc_events = []
    heap_summaries = []
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.GarbageCollection':
            gc_events.append(fields)
        elif type_name in ('jdk.GCHeapSummary', 'jdk.G1HeapSummary', 'jdk.PSHeapSummary'):
            heap_summaries.append(fields)
    
    return {
        'gc_event_count': len(gc_events),
        'heap_summary_count': len(heap_summaries),
        'gc_events': gc_events[:50]  # first 50 for analysis
    }


def analyze_allocations(events):
    """Analyze object allocation samples."""
    alloc_samples = []
    alloc_by_class = Counter()
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.ObjectAllocationSample':
            alloc_samples.append(fields)
            obj_class = fields.get('objectClass', 0)
            weight = fields.get('weight', 1)
            alloc_by_class[obj_class] += weight
    
    return {
        'total_samples': len(alloc_samples),
        'top_allocating_classes': alloc_by_class.most_common(20)
    }


def analyze_cpu(events):
    """Analyze CPU execution samples."""
    exec_samples = []
    hot_threads = Counter()
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.ExecutionSample':
            exec_samples.append(fields)
            thread = fields.get('sampledThread', 0)
            hot_threads[thread] += 1
    
    return {
        'total_samples': len(exec_samples),
        'hot_threads': hot_threads.most_common(20)
    }


def analyze_io(events):
    """Analyze I/O events."""
    socket_reads = []
    socket_writes = []
    file_reads = []
    file_writes = []
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.SocketRead':
            socket_reads.append(fields)
        elif type_name == 'jdk.SocketWrite':
            socket_writes.append(fields)
        elif type_name == 'jdk.FileRead':
            file_reads.append(fields)
        elif type_name == 'jdk.FileWrite':
            file_writes.append(fields)
    
    return {
        'socket_reads': len(socket_reads),
        'socket_writes': len(socket_writes),
        'file_reads': len(file_reads),
        'file_writes': len(file_writes)
    }


def analyze_locks(events):
    """Analyze lock contention events."""
    monitor_enters = []
    monitor_waits = []
    thread_parks = []
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.JavaMonitorEnter':
            monitor_enters.append(fields)
        elif type_name == 'jdk.JavaMonitorWait':
            monitor_waits.append(fields)
        elif type_name == 'jdk.ThreadPark':
            thread_parks.append(fields)
    
    return {
        'monitor_enters': len(monitor_enters),
        'monitor_waits': len(monitor_waits),
        'thread_parks': len(thread_parks)
    }


def analyze_classloading(events):
    """Analyze class loading events."""
    loads = 0
    unloads = 0
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.ClassLoad':
            loads += 1
        elif type_name == 'jdk.ClassUnload':
            unloads += 1
    
    return {
        'classes_loaded': loads,
        'classes_unloaded': unloads
    }


def extract_jvm_info(events):
    """Extract JVM configuration and environment info."""
    info = {}
    
    for type_id, type_name, fields in events:
        if type_name == 'jdk.JVMInformation':
            info['jvm'] = fields
        elif type_name == 'jdk.GCConfiguration':
            info['gc_config'] = fields
        elif type_name == 'jdk.CPUInformation':
            info['cpu'] = fields
        elif type_name == 'jdk.OSInformation':
            info['os'] = fields
        elif type_name == 'jdk.ContainerConfiguration':
            info['container'] = fields
        elif type_name == 'jdk.InitialEnvironmentVariable':
            if 'env_vars' not in info:
                info['env_vars'] = []
            info['env_vars'].append(fields)
    
    return info


# --- Main ---

def parse_jfr(filepath):
    """Parse a JFR file and return structured analysis."""
    with open(filepath, 'rb') as f:
        data = f.read()
    
    file_size = len(data)
    result = {
        'file': os.path.basename(filepath),
        'file_size_bytes': file_size,
        'file_size_mb': round(file_size / (1024 * 1024), 2),
        'chunks': [],
        'event_type_counts': {},
        'analysis': {}
    }
    
    # Parse all chunks
    offset = 0
    all_events = []
    chunk_count = 0
    
    while offset < len(data):
        chunk_header, new_offset = parse_chunk_header(data, offset)
        if chunk_header is None:
            break
        
        chunk_info = {
            'index': chunk_count,
            'offset': offset,
            'size': chunk_header['chunk_size'],
            'version': f"{chunk_header['major_version']}.{chunk_header['minor_version']}",
            'start_time_nanos': chunk_header['start_time_nanos'],
            'duration_nanos': chunk_header['duration_nanos'],
            'ticks_per_second': chunk_header['ticks_per_second'],
            'compressed_integers': bool(chunk_header['features'] & 1)
        }
        
        # Convert start time to human-readable
        start_time_ms = chunk_header['start_time_nanos'] // 1_000_000
        try:
            dt = datetime.fromtimestamp(start_time_ms / 1000, tz=timezone.utc)
            chunk_info['start_time'] = dt.isoformat()
        except (OSError, ValueError, OverflowError):
            chunk_info['start_time'] = f"nanos:{chunk_header['start_time_nanos']}"
        
        duration_ms = chunk_header['duration_nanos'] // 1_000_000
        chunk_info['duration_ms'] = duration_ms
        chunk_info['duration_seconds'] = round(duration_ms / 1000, 2)
        
        # Parse metadata
        try:
            strings, root_element = parse_metadata_section(data, chunk_header)
            if strings and root_element:
                resolved = resolve_metadata_strings(root_element, strings)
                event_types = extract_event_types(resolved)
                chunk_info['event_type_count'] = len(event_types)
                
                # Parse events
                events = parse_events(data, chunk_header, event_types)
                all_events.extend(events)
                chunk_info['event_count'] = len(events)
                
                # Count events by type
                for type_id, type_name, fields in events:
                    if type_name not in result['event_type_counts']:
                        result['event_type_counts'][type_name] = 0
                    result['event_type_counts'][type_name] += 1
            else:
                chunk_info['event_type_count'] = 0
                chunk_info['event_count'] = 0
                chunk_info['parse_error'] = 'Could not parse metadata'
        except Exception as e:
            chunk_info['parse_error'] = str(e)
            chunk_info['event_count'] = 0
        
        result['chunks'].append(chunk_info)
        
        # Move to next chunk
        next_offset = offset + chunk_header['chunk_size']
        if next_offset <= offset:
            break
        offset = next_offset
        chunk_count += 1
    
    result['total_chunks'] = chunk_count
    result['total_events'] = len(all_events)
    
    # Sort event type counts
    result['event_type_counts'] = dict(
        sorted(result['event_type_counts'].items(), key=lambda x: -x[1])
    )
    
    # Run analyses if we have events
    if all_events:
        tps = result['chunks'][0].get('ticks_per_second', 1_000_000_000) if result['chunks'] else 1_000_000_000
        start_ticks = result['chunks'][0].get('start_ticks', 0) if result['chunks'] else 0
        start_nanos = result['chunks'][0].get('start_time_nanos', 0) if result['chunks'] else 0
        
        result['analysis']['threads'] = analyze_thread_events(all_events, tps, start_ticks, start_nanos)
        result['analysis']['gc'] = analyze_gc_events(all_events)
        result['analysis']['allocations'] = analyze_allocations(all_events)
        result['analysis']['cpu'] = analyze_cpu(all_events)
        result['analysis']['io'] = analyze_io(all_events)
        result['analysis']['locks'] = analyze_locks(all_events)
        result['analysis']['classloading'] = analyze_classloading(all_events)
        result['analysis']['jvm_info'] = extract_jvm_info(all_events)
        
        # Issue detection
        issues = []
        threads = result['analysis']['threads']
        if threads['thread_churn']:
            issues.append({
                'severity': 'CRITICAL',
                'category': 'threads',
                'message': f"Thread churn detected: {threads['total_starts']} threads created, {threads['total_ends']} terminated. Most threads are extremely short-lived.",
            })
        
        gc = result['analysis']['gc']
        if gc['gc_event_count'] > 0:
            # Check for high GC frequency (approximate)
            total_duration_s = sum(c.get('duration_seconds', 0) for c in result['chunks'])
            if total_duration_s > 0:
                gc_per_minute = (gc['gc_event_count'] / total_duration_s) * 60
                if gc_per_minute > 60:
                    issues.append({
                        'severity': 'WARNING',
                        'category': 'gc',
                        'message': f"High GC frequency: {gc_per_minute:.1f} GC events/minute ({gc['gc_event_count']} events in {total_duration_s:.0f}s)"
                    })
        
        locks = result['analysis']['locks']
        if locks['monitor_enters'] > 1000:
            issues.append({
                'severity': 'WARNING',
                'category': 'locks',
                'message': f"High lock contention: {locks['monitor_enters']} monitor enter events recorded"
            })
        
        result['issues'] = issues
    
    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 jfr_parser.py <file.jfr>", file=sys.stderr)
        sys.exit(1)
    
    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    
    result = parse_jfr(filepath)
    print(json.dumps(result, indent=2, default=str))


if __name__ == '__main__':
    main()
