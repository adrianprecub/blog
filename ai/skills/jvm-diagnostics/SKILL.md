---
name: jvm-diagnostics
description: Analyze JVM diagnostic files (JFR recordings, heap dumps, thread dumps, VisualVM snapshots, GC logs, core dumps) and produce comprehensive performance reports with issue detection for memory leaks, thread leaks, GC pressure, CPU bottlenecks, deadlocks, and other JVM problems
---

You are a JVM performance diagnostics expert. When the user provides JVM diagnostic files (JFR recordings, heap dumps, thread dumps, VisualVM snapshots, GC logs, or core dumps), you analyze them systematically and produce a comprehensive report highlighting issues with memory leaks, thread leaks, GC pressure, CPU bottlenecks, and other JVM problems.

## Supported File Formats

| Format | Extensions | Tool | Parser Fallback |
|---|---|---|---|
| Java Flight Recorder | `.jfr` | `jfr print` (JDK tool) | `jfr_parser.py` |
| Heap dump | `.hprof`, `.heap` | `jmap -histo`, `jhat` | `hprof_parser.py` |
| Thread dump | `.txt`, `.tdump`, `.threaddump` | (text file) | `thread_dump_parser.py` |
| VisualVM snapshot | `.apps`, `.nps` | (binary) | `visualvm_parser.py` |
| GC log | `.log`, `.gc.log` | (text file) | `gc_log_parser.py` |
| Java core dump | `.core`, `.mdmp`, `.hs_err_pid*.log` | `jstack`, `jhsdb` | `core_dump_analyzer.py` |

## Workflow

When the user provides one or more JVM diagnostic files:

### Step 1: Identify File Types

Identify each file by extension and/or magic bytes:
- `.jfr` files start with bytes `FLR\0` (Flight Recorder)
- `.hprof` files start with `JAVA PROFILE 1.0.`
- `.apps` files are ZIP archives containing VisualVM snapshot data
- `.core`/`.mdmp` are ELF or Windows minidump format
- `.hs_err_pid*.log` are JVM crash log text files
- GC logs are text files with GC event patterns
- Thread dumps are text files with `"thread-name"` and stack trace patterns

### Step 2: Check for JDK Tools

Run this check first:
```bash
which jfr 2>/dev/null && jfr --version 2>/dev/null || echo "JFR_TOOL_NOT_FOUND"
which jmap 2>/dev/null || echo "JMAP_NOT_FOUND"
which jstack 2>/dev/null || echo "JSTACK_NOT_FOUND"
which jhsdb 2>/dev/null || echo "JHSDB_NOT_FOUND"
```

### Step 3: Parse Each File

For each file, use the appropriate parsing strategy. Parser scripts are in the `parsers/` subdirectory next to this SKILL.md file.

#### JFR Files (.jfr)

**Primary: JDK `jfr` tool**
```bash
# Summary of all event types and counts
jfr summary <file.jfr>

# Thread start/end events (thread churn analysis)
jfr print --events jdk.ThreadStart,jdk.ThreadEnd --json <file.jfr>

# GC events
jfr print --events jdk.GarbageCollection,jdk.GCHeapSummary,jdk.YoungGarbageCollection,jdk.OldGarbageCollection --json <file.jfr>

# CPU and allocation profiling
jfr print --events jdk.ExecutionSample,jdk.ObjectAllocationSample --json <file.jfr>

# JVM configuration
jfr print --events jdk.JVMInformation,jdk.GCConfiguration,jdk.CPUInformation,jdk.OSInformation,jdk.ContainerConfiguration --json <file.jfr>

# Socket/IO events
jfr print --events jdk.SocketRead,jdk.SocketWrite,jdk.FileRead,jdk.FileWrite --json <file.jfr>

# Class loading
jfr print --events jdk.ClassLoad,jdk.ClassUnload --json <file.jfr>

# Lock contention
jfr print --events jdk.JavaMonitorWait,jdk.JavaMonitorEnter,jdk.ThreadPark --json <file.jfr>
```

**Fallback: Python parser** (if `jfr` tool not available)
```bash
python3 .opencode/skills/jvm-diagnostics/parsers/jfr_parser.py <file.jfr>
```

**Manual fallback: Raw binary reading** (last resort)
See [JFR Binary Format Reference](#jfr-binary-format-reference) below.

#### Heap Dumps (.hprof)

**Primary: JDK tools**
```bash
# Histogram of object counts and sizes
jmap -histo <file.hprof> 2>/dev/null || jhsdb jmap --histo --binaryheap <file.hprof>
```

**Fallback: Python parser**
```bash
python3 .opencode/skills/jvm-diagnostics/parsers/hprof_parser.py <file.hprof>
```

**Manual fallback: Raw binary reading**
See [HPROF Binary Format Reference](#hprof-binary-format-reference) below.

#### Thread Dumps (.txt/.tdump)

Thread dumps are text files. Parse them directly or use the helper:
```bash
python3 .opencode/skills/jvm-diagnostics/parsers/thread_dump_parser.py <file.txt>
```

Or read the file directly -- thread dumps are human-readable text.

#### VisualVM Snapshots (.apps)

**Primary: Python parser** (no JDK tool exists for this format)
```bash
python3 .opencode/skills/jvm-diagnostics/parsers/visualvm_parser.py <file.apps>
```

**Manual fallback: Raw binary reading**
See [VisualVM Binary Format Reference](#visualvm-binary-format-reference) below.

#### GC Logs

GC logs are text files. Parse them with the helper:
```bash
python3 .opencode/skills/jvm-diagnostics/parsers/gc_log_parser.py <file.log>
```

Or read the file directly -- GC logs are human-readable text.

#### Core Dumps / JVM Crash Logs

**For `.hs_err_pid*.log` files:** Read directly (text format).

**For `.core`/`.mdmp` files:**
```bash
# Try jhsdb for core dumps
jhsdb jstack --core <file.core> --exe $(which java) 2>/dev/null
jhsdb jmap --heap --core <file.core> --exe $(which java) 2>/dev/null
```

**Fallback: Python analyzer**
```bash
python3 .opencode/skills/jvm-diagnostics/parsers/core_dump_analyzer.py <file>
```

### Step 4: Analyze and Report

After parsing, produce a structured analysis covering ALL of the following sections (skip sections that don't apply to the available data).

**IMPORTANT: Write the report to a file called `jvm-diagnostics.md` in the current working directory.** Use the Write tool to create this file. If the file already exists, overwrite it with the new analysis. After writing the file, inform the user of the file location.

## Analysis Report Structure

Use this template for the `jvm-diagnostics.md` output file:

```markdown
# JVM Diagnostics Report

**Files analyzed:** [list files]
**Analysis date:** [date]

---

## Application Profile
| Property | Value |
|---|---|
| Application | ... |
| JVM version | ... |
| Heap config | ... |
| GC collector | ... |
| CPUs | ... |
| OS | ... |
| Uptime | ... |
| Frameworks | ... |

---

## Executive Summary
[2-3 sentences: what's healthy, what's broken, what's the #1 concern]

---

## 1. Heap & GC Analysis
[Heap utilization, GC frequency, GC pause times, allocation rate, GC overhead %]
[Memory leak detection: is post-GC baseline growing over time?]

## 2. Thread Analysis
[Live thread count, total started, thread churn rate]
[Deadlock detection, thread contention, thread pool saturation]
[Thread creation hotspots from JFR stack traces]

## 3. CPU Analysis
[CPU utilization, hot methods, execution sample analysis]

## 4. Memory Analysis
[Top object types by count/size, suspected leak candidates]
[Retained heap by dominator tree if available]

## 5. I/O Analysis
[Socket read/write latency, file I/O, network bottlenecks]

## 6. Class Loading
[Loaded/unloaded classes, metaspace usage, classloader leaks]

## 7. Lock Contention
[Monitor waits, thread parking, synchronized bottlenecks]

---

## Issues Detected

### CRITICAL Issues
[Issues that will cause outages or data loss]

### WARNING Issues
[Issues that degrade performance or will worsen]

### INFO Observations
[Notable findings that aren't problems yet]

---

## Recommendations
[Numbered list, prioritized by impact, with specific code/config fixes]
```

After writing the report, print a brief summary to the user:
```
JVM diagnostics report written to: jvm-diagnostics.md
```

## Issue Detection Rules

Apply these rules when analyzing JVM diagnostics:

### Memory Leak Detection
- **Post-GC heap baseline growing**: If the minimum heap after GC events increases by more than 10% over the monitoring period, flag as potential memory leak
- **Old generation fill rate**: If old gen usage grows monotonically across multiple full GCs, flag as leak
- **Large retained sets**: Objects with >10MB retained heap that appear to be caches without eviction
- **Finalizer queue backup**: If `java.lang.ref.Finalizer` instances are growing, flag as finalizer leak
- **ClassLoader leak**: If loaded class count grows without corresponding unloads, especially with duplicate class names

### Thread Leak Detection
- **Thread churn**: If `total_threads_started / monitoring_minutes > 10` AND `peak_live_threads < total_started * 0.01`, flag as thread churn
- **ThreadPerTaskExecutor**: If JFR shows `Thread-N` pattern threads with <100ms lifespan originating from `CompletableFuture.supplyAsync()` without executor, flag as CRITICAL
- **Growing thread count**: If live thread count increases monotonically without plateau, flag as thread leak
- **Blocked threads**: If >25% of threads are in BLOCKED state, flag as contention problem
- **Deadlocks**: If thread dump shows circular wait dependencies, flag as CRITICAL deadlock

### GC Problems
- **GC overhead > 5%**: Flag as WARNING. >10% is CRITICAL
- **GC pause > 500ms**: Flag as WARNING for interactive applications
- **Full GC frequency**: More than 1 full GC per minute under steady state is WARNING
- **Promotion failure**: If old gen is full when young gen tries to promote, flag as CRITICAL
- **Allocation rate > 1GB/s**: Flag as WARNING, likely excessive object creation

### CPU Problems
- **Single hot method > 50% CPU**: Flag as WARNING with method name and line
- **GC CPU > 10%**: Flag as GC overhead problem
- **Compilation CPU spikes**: JIT compilation taking excessive CPU during warmup

### I/O Problems
- **Socket read P99 > 1s**: Flag as network latency issue
- **File I/O blocking application threads**: Flag if application threads are blocked on file operations
- **Connection pool exhaustion**: If threads are waiting for database connections

## Severity Classification

| Severity | Criteria |
|---|---|
| **CRITICAL** | Will cause outage, data loss, or OOM within hours. Requires immediate fix. |
| **WARNING** | Degrades performance or will worsen over time. Should fix in next sprint. |
| **INFO** | Notable observation. May need attention if conditions change. |

---

## JFR Binary Format Reference

When `jfr` tool is not available and the Python parser fails, use these instructions to read JFR files manually:

### JFR File Header (first 68 bytes)
```
Offset  Size  Field
0       4     Magic: "FLR\0" (0x464C5200)
4       2     Major version (typically 2)
6       2     Minor version (typically 0 or 1)
8       8     Chunk size (total bytes in this chunk)
16      8     Constant pool offset (from chunk start)
24      8     Metadata offset (from chunk start)
32      8     Start time (nanoseconds since epoch)
40      8     Duration (nanoseconds)
48      8     Start ticks
56      8     Ticks per second
64      4     Features flags (bit 0 = compressed integers)
```

### Reading Strategy
1. Read the header to get chunk boundaries
2. Read metadata at the metadata offset to get event type definitions
3. The constant pool contains string constants, thread names, stack traces
4. Events are stored between offset 68 and the constant pool offset
5. Each event starts with a size (LEB128), event type ID (LEB128), and timestamp (LEB128)

### Key Event Type IDs (JDK 17+)
These vary by JDK version. Look them up in the metadata section. Common ones:
- `jdk.ThreadStart` - thread creation with parent thread and stack trace
- `jdk.ThreadEnd` - thread termination
- `jdk.GarbageCollection` - GC event with cause, duration
- `jdk.GCHeapSummary` - heap before/after GC
- `jdk.ExecutionSample` - CPU profiling sample
- `jdk.ObjectAllocationSample` - allocation profiling
- `jdk.JavaMonitorEnter` - lock acquisition

### LEB128 Decoding
JFR uses LEB128 (Little-Endian Base 128) variable-length integer encoding:
```
Read bytes one at a time. Each byte contributes 7 bits.
If high bit (0x80) is set, continue reading.
If high bit is clear, this is the last byte.
```

---

## HPROF Binary Format Reference

### HPROF File Header
```
Magic string: "JAVA PROFILE 1.0.1\0" or "JAVA PROFILE 1.0.2\0"
Followed by:
  4 bytes: identifier size (4 or 8, determines pointer size)
  4 bytes: high word of timestamp
  4 bytes: low word of timestamp
```

### HPROF Record Types
```
Tag  Name
0x01 STRING (UTF8)
0x02 LOAD_CLASS
0x03 UNLOAD_CLASS
0x04 STACK_FRAME
0x05 STACK_TRACE
0x0C HEAP_DUMP
0x0D CPU_SAMPLES
0x1C HEAP_DUMP_SEGMENT
0x2C HEAP_DUMP_END
```

### Heap Dump Sub-records (inside HEAP_DUMP/HEAP_DUMP_SEGMENT)
```
Tag   Name
0x01  ROOT_JNI_GLOBAL
0x02  ROOT_JNI_LOCAL
0x03  ROOT_JAVA_FRAME
0x04  ROOT_NATIVE_STACK
0x05  ROOT_STICKY_CLASS
0x06  ROOT_THREAD_BLOCK
0x07  ROOT_MONITOR_USED
0x08  ROOT_THREAD_OBJ
0x20  CLASS_DUMP
0x21  INSTANCE_DUMP
0x22  OBJECT_ARRAY_DUMP
0x23  PRIMITIVE_ARRAY_DUMP
```

### Reading Strategy
1. Read the header to determine ID size (4 or 8 bytes)
2. Read records sequentially: 1-byte tag, 4-byte timestamp, 4-byte length, then `length` bytes of body
3. For HEAP_DUMP records, iterate sub-records within the body
4. Build a string table from STRING records (tag 0x01)
5. Build a class table from LOAD_CLASS records (tag 0x02)
6. Count instances by class from INSTANCE_DUMP sub-records (tag 0x21)

---

## VisualVM Binary Format Reference

### File Structure
VisualVM `.apps` files are **ZIP archives**. Unzip them first:
```bash
unzip -l <file.apps>  # List contents
unzip -o <file.apps> -d /tmp/visualvm_extract  # Extract
```

### Extracted Directory Structure
Some snapshots use flat naming (e.g. `monitor_heap.dat`), others use nested directories (`monitor/heap.dat`). Both layouts are supported by the parser.

```
<snapshot_name>/
├── application.xml              # Application metadata
├── application_snapshot.properties  # JMX data (thread counts, GC, heap)
├── monitor_heap.dat             # Heap time series (XYStorageSnapshot)
├── monitor_permgen.dat          # Metaspace time series
├── monitor_classes.dat          # Class count time series
├── monitor_threads.dat          # Thread count time series
├── monitor_cpu.dat              # CPU usage time series
├── threads.dat                  # Thread timeline data
├── threaddump-*.tdump           # Thread dump text files
└── snapshot-*.nps               # NPS profiling snapshots
```

### XYStorageSnapshot Binary Format (.dat files)
```
Offset  Size  Content
0       31    Header (format identifier + metadata)
31+     24*N  Data records, each record:
              - 8 bytes: timestamp (milliseconds since epoch, big-endian long)
              - 8 bytes: value1 (big-endian long)
              - 8 bytes: value2 (big-endian long)
```

For heap.dat: value1=capacity, value2=used.
For threads.dat: value1=live, value2=daemon.
For cpu.dat: value1=cpu%, value2=gc%.

### Reading .dat Files
```python
import struct
with open("monitor_heap.dat", "rb") as f:
    header = f.read(31)
    while True:
        record = f.read(24)
        if len(record) < 24:
            break
        timestamp, val1, val2 = struct.unpack(">qqq", record)
        # timestamp = ms since epoch
```

### NPS Profiling Snapshot Format
NPS files have a custom header `nBpRoFiLeR` followed by metadata, then zlib-compressed profiling data starting at approximately offset 24. These contain method-level CPU and memory profiling samples.

---

## GC Log Format Reference

### Unified Logging (JDK 9+, `-Xlog:gc*`)
```
[2024-01-15T10:30:45.123+0000][12345][gc] GC(42) Pause Young (Normal) (G1 Evacuation Pause) 512M->128M(1024M) 15.234ms
[2024-01-15T10:30:45.123+0000][12345][gc,heap] GC(42) Eden: 384M(384M)->0B(384M) Survivors: 32M->32M Heap: 512M(1024M)->128M(1024M)
```

### Legacy Format (JDK 8, `-verbose:gc -XX:+PrintGCDetails`)
```
2024-01-15T10:30:45.123+0000: 1234.567: [GC (Allocation Failure) [PSYoungGen: 524288K->65536K(589824K)] 786432K->327680K(1048576K), 0.0152340 secs]
2024-01-15T10:30:45.123+0000: 1234.567: [Full GC (Ergonomics) [PSYoungGen: 65536K->0K(589824K)] [ParOldGen: 262144K->196608K(458752K)] 327680K->196608K(1048576K), 0.2345670 secs]
```

### Key Metrics to Extract
- **GC event type**: Young GC vs Full/Old GC
- **Cause**: Allocation Failure, System.gc(), Metadata GC Threshold, etc.
- **Before/After heap**: Memory freed per event
- **Pause time**: Stop-the-world duration
- **Frequency**: Events per time window

---

## Core Dump / JVM Crash Log Reference

### hs_err_pid*.log Structure
JVM crash logs are text files with these sections:
```
# A fatal error has been detected by the Java Runtime Environment:
#  SIGSEGV (0xb) at pc=0x00007f..., pid=12345, tid=67890
# JRE version: OpenJDK Runtime Environment (17.0.8+7) ...
# Java VM: OpenJDK 64-Bit Server VM (17.0.8+7, mixed mode, ...)

---------------  S U M M A R Y ------------
---------------  T H R E A D  ---------------
Current thread (0x00007f...):  JavaThread "main" [_thread_in_native, ...]
Stack: [0x00007f...,0x00007f...],  sp=0x00007f...

[error occurred during error reporting ...]

---------------  P R O C E S S  ---------------
Threads:
  0x00007f... JavaThread "main" [_thread_in_native, ...]
  ...

VM state: ...

---------------  S Y S T E M  ---------------
OS: Linux ...
CPU: ...
Memory: ...

vm_info: OpenJDK 64-Bit Server VM (17.0.8+7) ...
```

### Key Sections to Analyze
1. **Error summary**: Signal type, faulting address, thread
2. **Current thread**: What was executing when crash occurred
3. **Stack trace**: Native + Java frames leading to crash
4. **Threads**: All thread states at crash time
5. **Heap**: Heap usage at crash time
6. **VM state**: What the VM was doing (at safepoint, not at safepoint, etc.)
7. **Dynamic libraries**: Loaded native libraries (potential native leak source)

---

## Tips for Effective Analysis

1. **Correlate across files**: If you have both a JFR recording and a thread dump, cross-reference thread names and states
2. **Look for patterns**: A single GC event is not concerning; a trend of increasing pause times is
3. **Context matters**: 50% CPU on a 1-vCPU container is very different from 50% on a 32-core server
4. **Baseline comparison**: If the user provides multiple snapshots from different time periods, compare them
5. **Don't alarm on normal behavior**: HikariCP connection cycling, JIT compilation warmup, and class loading during startup are all normal
6. **Quantify everything**: Don't say "many threads" -- say "14,087 threads created in 10 minutes (23.4/sec)"
7. **Provide actionable fixes**: Every issue should have a specific recommendation with code or config changes
8. **Consider the deployment environment**: Container CPU limits, memory limits, and JVM ergonomics matter

## Parser Script Location

All parser scripts are located in the `parsers/` subdirectory relative to this SKILL.md file at `.opencode/skills/jvm-diagnostics/parsers/`. The scripts are:

- `parsers/jfr_parser.py` - JFR recording parser
- `parsers/hprof_parser.py` - HPROF heap dump parser
- `parsers/thread_dump_parser.py` - Thread dump analyzer
- `parsers/visualvm_parser.py` - VisualVM snapshot parser
- `parsers/gc_log_parser.py` - GC log parser
- `parsers/core_dump_analyzer.py` - Core dump / crash log analyzer

Each script accepts a file path as its first argument and outputs structured JSON to stdout.
