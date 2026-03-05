#!/usr/bin/env python3
"""
HPROF (Java Heap Dump) binary parser.

Parses .hprof files without requiring JDK tools (jmap, jhat, MAT).
Outputs structured JSON to stdout with object histograms, GC root analysis,
and memory leak indicators.

Usage:
    python3 hprof_parser.py <file.hprof>

HPROF Binary Format:
- Header: magic string + id_size + timestamp
- Records: tag(1) + timestamp(4) + length(4) + body(length)
- Heap dump records contain sub-records for instances, classes, arrays, GC roots
"""

import json
import struct
import sys
import os
from collections import Counter, defaultdict


# HPROF record tags
TAG_STRING = 0x01
TAG_LOAD_CLASS = 0x02
TAG_UNLOAD_CLASS = 0x03
TAG_STACK_FRAME = 0x04
TAG_STACK_TRACE = 0x05
TAG_ALLOC_SITES = 0x06
TAG_HEAP_SUMMARY = 0x07
TAG_START_THREAD = 0x0A
TAG_END_THREAD = 0x0B
TAG_HEAP_DUMP = 0x0C
TAG_CPU_SAMPLES = 0x0D
TAG_CONTROL_SETTINGS = 0x0E
TAG_HEAP_DUMP_SEGMENT = 0x1C
TAG_HEAP_DUMP_END = 0x2C

# Heap dump sub-record tags
HEAP_ROOT_JNI_GLOBAL = 0x01
HEAP_ROOT_JNI_LOCAL = 0x02
HEAP_ROOT_JAVA_FRAME = 0x03
HEAP_ROOT_NATIVE_STACK = 0x04
HEAP_ROOT_STICKY_CLASS = 0x05
HEAP_ROOT_THREAD_BLOCK = 0x06
HEAP_ROOT_MONITOR_USED = 0x07
HEAP_ROOT_THREAD_OBJ = 0x08
HEAP_CLASS_DUMP = 0x20
HEAP_INSTANCE_DUMP = 0x21
HEAP_OBJECT_ARRAY_DUMP = 0x22
HEAP_PRIMITIVE_ARRAY_DUMP = 0x23

# Java type sizes for primitive arrays
JAVA_TYPE_SIZES = {
    4: 1,   # boolean
    5: 2,   # char
    6: 4,   # float
    7: 8,   # double
    8: 1,   # byte
    9: 2,   # short
    10: 4,  # int
    11: 8,  # long
}

JAVA_TYPE_NAMES = {
    4: 'boolean',
    5: 'char',
    6: 'float',
    7: 'double',
    8: 'byte',
    9: 'short',
    10: 'int',
    11: 'long',
}


def read_id(data, offset, id_size):
    """Read an ID (object reference) of the given size."""
    if id_size == 4:
        return struct.unpack('>I', data[offset:offset+4])[0], offset + 4
    elif id_size == 8:
        return struct.unpack('>Q', data[offset:offset+8])[0], offset + 8
    else:
        raise ValueError(f"Unsupported id_size: {id_size}")


def parse_header(data):
    """Parse HPROF file header. Returns (id_size, timestamp, header_end_offset)."""
    # Find null terminator of magic string
    null_pos = data.index(b'\x00')
    magic = data[:null_pos].decode('ascii')
    pos = null_pos + 1
    
    id_size = struct.unpack('>I', data[pos:pos+4])[0]
    pos += 4
    
    timestamp_high = struct.unpack('>I', data[pos:pos+4])[0]
    pos += 4
    timestamp_low = struct.unpack('>I', data[pos:pos+4])[0]
    pos += 4
    
    timestamp = (timestamp_high << 32) | timestamp_low
    
    return {
        'magic': magic,
        'id_size': id_size,
        'timestamp': timestamp
    }, pos


def parse_heap_dump_segment(data, offset, end_offset, id_size, strings, classes, class_names):
    """Parse heap dump sub-records within a HEAP_DUMP or HEAP_DUMP_SEGMENT.
    Returns instance counts, sizes, GC root info."""
    instance_counts = Counter()  # class_id -> count
    instance_sizes = Counter()   # class_id -> total size
    array_counts = Counter()     # type_name -> count
    array_sizes = Counter()      # type_name -> total size
    gc_roots = Counter()         # root_type -> count
    
    pos = offset
    record_count = 0
    max_records = 10_000_000  # safety limit
    
    while pos < end_offset and record_count < max_records:
        if pos >= len(data):
            break
        
        sub_tag = data[pos]
        pos += 1
        record_count += 1
        
        try:
            if sub_tag == HEAP_ROOT_JNI_GLOBAL:
                pos += id_size * 2
                gc_roots['JNI_GLOBAL'] += 1
            elif sub_tag == HEAP_ROOT_JNI_LOCAL:
                pos += id_size + 4 + 4
                gc_roots['JNI_LOCAL'] += 1
            elif sub_tag == HEAP_ROOT_JAVA_FRAME:
                pos += id_size + 4 + 4
                gc_roots['JAVA_FRAME'] += 1
            elif sub_tag == HEAP_ROOT_NATIVE_STACK:
                pos += id_size + 4
                gc_roots['NATIVE_STACK'] += 1
            elif sub_tag == HEAP_ROOT_STICKY_CLASS:
                pos += id_size
                gc_roots['STICKY_CLASS'] += 1
            elif sub_tag == HEAP_ROOT_THREAD_BLOCK:
                pos += id_size + 4
                gc_roots['THREAD_BLOCK'] += 1
            elif sub_tag == HEAP_ROOT_MONITOR_USED:
                pos += id_size
                gc_roots['MONITOR_USED'] += 1
            elif sub_tag == HEAP_ROOT_THREAD_OBJ:
                pos += id_size + 4 + 4
                gc_roots['THREAD_OBJ'] += 1
            elif sub_tag == HEAP_CLASS_DUMP:
                class_obj_id, pos = read_id(data, pos, id_size)
                pos += 4  # stack trace serial
                super_class_id, pos = read_id(data, pos, id_size)
                loader_id, pos = read_id(data, pos, id_size)
                signers_id, pos = read_id(data, pos, id_size)
                prot_domain_id, pos = read_id(data, pos, id_size)
                reserved1, pos = read_id(data, pos, id_size)
                reserved2, pos = read_id(data, pos, id_size)
                instance_size = struct.unpack('>I', data[pos:pos+4])[0]
                pos += 4
                
                # Constant pool
                cp_count = struct.unpack('>H', data[pos:pos+2])[0]
                pos += 2
                for _ in range(cp_count):
                    pos += 2  # index
                    type_tag = data[pos]
                    pos += 1
                    if type_tag == 2:  # object
                        pos += id_size
                    elif type_tag in JAVA_TYPE_SIZES:
                        pos += JAVA_TYPE_SIZES[type_tag]
                    else:
                        pos += id_size
                
                # Static fields
                static_count = struct.unpack('>H', data[pos:pos+2])[0]
                pos += 2
                for _ in range(static_count):
                    pos += id_size  # name
                    type_tag = data[pos]
                    pos += 1
                    if type_tag == 2:  # object
                        pos += id_size
                    elif type_tag in JAVA_TYPE_SIZES:
                        pos += JAVA_TYPE_SIZES[type_tag]
                    else:
                        pos += id_size
                
                # Instance fields
                inst_field_count = struct.unpack('>H', data[pos:pos+2])[0]
                pos += 2
                for _ in range(inst_field_count):
                    pos += id_size  # name
                    pos += 1  # type
                
                # Store class info
                classes[class_obj_id] = {
                    'instance_size': instance_size,
                    'super_class': super_class_id,
                    'instance_field_count': inst_field_count
                }
                
            elif sub_tag == HEAP_INSTANCE_DUMP:
                obj_id, pos = read_id(data, pos, id_size)
                pos += 4  # stack trace serial
                class_id, pos = read_id(data, pos, id_size)
                num_bytes = struct.unpack('>I', data[pos:pos+4])[0]
                pos += 4 + num_bytes
                
                instance_counts[class_id] += 1
                instance_sizes[class_id] += num_bytes + id_size + 4 + 4  # overhead
                
            elif sub_tag == HEAP_OBJECT_ARRAY_DUMP:
                obj_id, pos = read_id(data, pos, id_size)
                pos += 4  # stack trace serial
                num_elements = struct.unpack('>I', data[pos:pos+4])[0]
                pos += 4
                elem_class_id, pos = read_id(data, pos, id_size)
                pos += id_size * num_elements
                
                class_name = class_names.get(elem_class_id, f'Object[{elem_class_id}]')
                array_name = f'{class_name}[]'
                array_counts[array_name] += 1
                total_size = id_size * num_elements + 16  # array overhead
                array_sizes[array_name] += total_size
                
            elif sub_tag == HEAP_PRIMITIVE_ARRAY_DUMP:
                obj_id, pos = read_id(data, pos, id_size)
                pos += 4  # stack trace serial
                num_elements = struct.unpack('>I', data[pos:pos+4])[0]
                pos += 4
                elem_type = data[pos]
                pos += 1
                elem_size = JAVA_TYPE_SIZES.get(elem_type, 1)
                pos += elem_size * num_elements
                
                type_name = JAVA_TYPE_NAMES.get(elem_type, f'prim_{elem_type}')
                array_name = f'{type_name}[]'
                array_counts[array_name] += 1
                total_size = elem_size * num_elements + 16
                array_sizes[array_name] += total_size
                
            else:
                # Unknown sub-tag -- try to skip but we might be lost
                # This is a heuristic: if the next byte looks like a valid sub-tag, continue
                # Otherwise, we're done
                break
        except (struct.error, IndexError):
            break
    
    return {
        'instance_counts': instance_counts,
        'instance_sizes': instance_sizes,
        'array_counts': array_counts,
        'array_sizes': array_sizes,
        'gc_roots': gc_roots,
        'records_parsed': record_count
    }


def parse_hprof(filepath):
    """Parse an HPROF file and return structured analysis."""
    with open(filepath, 'rb') as f:
        data = f.read()
    
    file_size = len(data)
    
    # Parse header
    header, pos = parse_header(data)
    id_size = header['id_size']
    
    result = {
        'file': os.path.basename(filepath),
        'file_size_bytes': file_size,
        'file_size_mb': round(file_size / (1024 * 1024), 2),
        'header': header,
        'id_size': id_size,
    }
    
    # Parse records
    strings = {}       # id -> string
    class_serial = {}  # serial -> {class_obj_id, name_id}
    class_names = {}   # class_obj_id -> class_name
    classes = {}       # class_obj_id -> class_info
    stack_frames = {}  # id -> frame info
    stack_traces = {}  # serial -> trace info
    
    total_instance_counts = Counter()
    total_instance_sizes = Counter()
    total_array_counts = Counter()
    total_array_sizes = Counter()
    total_gc_roots = Counter()
    heap_dump_count = 0
    heap_summary = None
    cpu_samples = []
    record_count = 0
    
    while pos < len(data):
        if pos + 9 > len(data):
            break
        
        tag = data[pos]
        pos += 1
        timestamp = struct.unpack('>I', data[pos:pos+4])[0]
        pos += 4
        length = struct.unpack('>I', data[pos:pos+4])[0]
        pos += 4
        
        body_start = pos
        body_end = pos + length
        
        if body_end > len(data):
            break
        
        record_count += 1
        
        if tag == TAG_STRING:
            str_id, str_pos = read_id(data, pos, id_size)
            str_val = data[str_pos:body_end].decode('utf-8', errors='replace')
            strings[str_id] = str_val
            
        elif tag == TAG_LOAD_CLASS:
            serial = struct.unpack('>I', data[pos:pos+4])[0]
            class_obj_id, cpos = read_id(data, pos+4, id_size)
            pos2 = cpos + 4  # skip stack trace serial
            name_id, _ = read_id(data, pos2, id_size)
            class_name = strings.get(name_id, f'class_{class_obj_id}')
            # Convert JVM internal format to Java format
            class_name = class_name.replace('/', '.')
            class_serial[serial] = {'class_obj_id': class_obj_id, 'name': class_name}
            class_names[class_obj_id] = class_name
            
        elif tag == TAG_STACK_FRAME:
            frame_id, fpos = read_id(data, pos, id_size)
            method_name_id, fpos = read_id(data, fpos, id_size)
            method_sig_id, fpos = read_id(data, fpos, id_size)
            source_file_id, fpos = read_id(data, fpos, id_size)
            class_serial_num = struct.unpack('>I', data[fpos:fpos+4])[0]
            line_num = struct.unpack('>i', data[fpos+4:fpos+8])[0]
            stack_frames[frame_id] = {
                'method': strings.get(method_name_id, '?'),
                'signature': strings.get(method_sig_id, '?'),
                'source': strings.get(source_file_id, '?'),
                'class_serial': class_serial_num,
                'line': line_num
            }
            
        elif tag == TAG_STACK_TRACE:
            serial = struct.unpack('>I', data[pos:pos+4])[0]
            thread_serial = struct.unpack('>I', data[pos+4:pos+8])[0]
            num_frames = struct.unpack('>I', data[pos+8:pos+12])[0]
            frames = []
            fpos = pos + 12
            for _ in range(num_frames):
                frame_id, fpos = read_id(data, fpos, id_size)
                if frame_id in stack_frames:
                    frames.append(stack_frames[frame_id])
            stack_traces[serial] = {
                'thread_serial': thread_serial,
                'frames': frames
            }
            
        elif tag == TAG_HEAP_SUMMARY:
            if length >= 24:
                total_live = struct.unpack('>I', data[pos:pos+4])[0]
                total_live_bytes = struct.unpack('>Q', data[pos+4:pos+12])[0]
                total_alloc = struct.unpack('>I', data[pos+12:pos+16])[0]
                total_alloc_bytes = struct.unpack('>Q', data[pos+16:pos+24])[0]
                heap_summary = {
                    'total_live_instances': total_live,
                    'total_live_bytes': total_live_bytes,
                    'total_live_mb': round(total_live_bytes / (1024 * 1024), 2),
                    'total_allocated_instances': total_alloc,
                    'total_allocated_bytes': total_alloc_bytes,
                    'total_allocated_mb': round(total_alloc_bytes / (1024 * 1024), 2)
                }
            
        elif tag == TAG_CPU_SAMPLES:
            if length >= 8:
                total = struct.unpack('>I', data[pos:pos+4])[0]
                num_traces = struct.unpack('>I', data[pos+4:pos+8])[0]
                cpos = pos + 8
                for _ in range(num_traces):
                    if cpos + 8 > body_end:
                        break
                    count = struct.unpack('>I', data[cpos:cpos+4])[0]
                    trace_serial = struct.unpack('>I', data[cpos+4:cpos+8])[0]
                    cpos += 8
                    cpu_samples.append({
                        'count': count,
                        'trace_serial': trace_serial,
                        'trace': stack_traces.get(trace_serial, {}).get('frames', [])[:5]
                    })
            
        elif tag in (TAG_HEAP_DUMP, TAG_HEAP_DUMP_SEGMENT):
            heap_dump_count += 1
            seg_result = parse_heap_dump_segment(data, pos, body_end, id_size, strings, classes, class_names)
            total_instance_counts += seg_result['instance_counts']
            total_instance_sizes += seg_result['instance_sizes']
            total_array_counts += seg_result['array_counts']
            total_array_sizes += seg_result['array_sizes']
            total_gc_roots += seg_result['gc_roots']
        
        pos = body_end
    
    # Build histogram
    histogram = []
    for class_id, count in total_instance_counts.most_common(100):
        name = class_names.get(class_id, f'unknown_{class_id}')
        size = total_instance_sizes[class_id]
        histogram.append({
            'class': name,
            'instances': count,
            'total_bytes': size,
            'total_mb': round(size / (1024 * 1024), 4)
        })
    
    # Array histogram
    array_histogram = []
    for array_name, count in total_array_counts.most_common(50):
        size = total_array_sizes[array_name]
        array_histogram.append({
            'type': array_name,
            'count': count,
            'total_bytes': size,
            'total_mb': round(size / (1024 * 1024), 4)
        })
    
    result['record_count'] = record_count
    result['heap_dump_segments'] = heap_dump_count
    result['string_table_size'] = len(strings)
    result['loaded_classes'] = len(class_names)
    result['heap_summary'] = heap_summary
    result['instance_histogram'] = histogram
    result['array_histogram'] = array_histogram
    result['gc_roots'] = dict(total_gc_roots.most_common())
    result['total_gc_root_count'] = sum(total_gc_roots.values())
    
    if cpu_samples:
        result['cpu_samples'] = sorted(cpu_samples, key=lambda x: -x['count'])[:20]
    
    # Issue detection
    issues = []
    
    # Check for finalizer leak
    for item in histogram:
        if 'Finalizer' in item['class'] and item['instances'] > 1000:
            issues.append({
                'severity': 'WARNING',
                'category': 'memory',
                'message': f"High Finalizer count: {item['instances']} instances of {item['class']}. Possible finalizer leak."
            })
    
    # Check for large string accumulation
    for item in histogram:
        if item['class'] == 'java.lang.String' and item['total_mb'] > 100:
            issues.append({
                'severity': 'WARNING',
                'category': 'memory',
                'message': f"Large String accumulation: {item['instances']} String objects totaling {item['total_mb']:.1f} MB"
            })
    
    # Check for byte[] dominating heap
    for item in array_histogram:
        if item['type'] == 'byte[]' and heap_summary and item['total_bytes'] > heap_summary.get('total_live_bytes', float('inf')) * 0.5:
            issues.append({
                'severity': 'INFO',
                'category': 'memory',
                'message': f"byte[] arrays dominate heap: {item['total_mb']:.1f} MB ({item['count']} arrays)"
            })
    
    result['issues'] = issues
    
    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 hprof_parser.py <file.hprof>", file=sys.stderr)
        sys.exit(1)
    
    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    
    result = parse_hprof(filepath)
    print(json.dumps(result, indent=2, default=str))


if __name__ == '__main__':
    main()
