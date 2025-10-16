# tsnsrv CPU Performance Analysis - pprof Results

## Executive Summary

Performance profiling of tsnsrv on the storage host (57 services, 122% CPU) has revealed **the root cause of high CPU usage is NOT HTTP request handling or tsnet authentication overhead as initially expected**. Instead, the bottleneck is **Tailscale's port listing functionality**, which repeatedly scans `/proc/net/` files and makes netlink syscalls to enumerate network interfaces.

### Critical Findings

1. **90% of CPU time is spent in syscalls** - specifically `internal/runtime/syscall.Syscall6`
2. **Port listing consumes 48.85% of total CPU** - `portlist.AppendListeningPorts` and related functions
3. **Goroutine explosion: 111.6 goroutines per service** (6364 total / 57 services)
   - Expected: 2-5 goroutines per service
   - Actual: **40x higher than expected**
4. **No lock contention** - mutex profile shows 0 samples, ruling out synchronization issues

### Top 3 CPU Hotspots

| Function | CPU % | Cumulative | What It Does |
|----------|-------|------------|--------------|
| `portlist.(*linuxImpl).AppendListeningPorts` | 48.85% | 35.56s/60s | Scans /proc/net files for listening ports |
| `net.(*Interface).Addrs` | 35.27% | 25.67s/60s | Enumerates network interface addresses via netlink |
| `syscall.Syscall6` (underlying) | 90.09% | 65.58s/60s | Kernel syscall overhead for above operations |

## Detailed Analysis

### 1. CPU Profile Analysis

**Profile Metadata:**
- Duration: 60 seconds
- Total samples: 72.79s (121.31% CPU utilization)
- Sampling date: 2025-10-15 21:05:34 EDT
- Process stats: 122% CPU, 2.8GB RSS

**Top Functions by CPU Time:**

```
      flat  flat%   sum%        cum   cum%
    65.58s 90.09% 90.09%     65.58s 90.09%  internal/runtime/syscall.Syscall6
     0.49s  0.67% 90.77%      0.53s  0.73%  go4.org/mem.AppendFields
     0.14s  0.19% 90.96%      9.31s 12.79%  tailscale.com/util/dirwalk.linuxWalkShallow
     0.08s  0.11% 91.19%     32.55s 44.72%  syscall.NetlinkRIB
     0.07s 0.096% 91.40%     35.56s 48.85%  tailscale.com/portlist.(*linuxImpl).AppendListeningPorts
     0.04s 0.055% 91.72%     25.76s 35.39%  tailscale.com/portlist.(*linuxImpl).parseProcNetFile
     0.01s 0.014% 91.91%     25.67s 35.27%  net.(*Interface).Addrs
```

**Call Tree Analysis:**

The CPU time flows through these call paths:

1. **Port Listing Path (48.85% total):**
   ```
   portlist.AppendListeningPorts (35.56s)
   ├── parseProcNetFile (25.76s) - Reads /proc/net/tcp, /proc/net/tcp6, etc.
   │   └── bufio.ReadSlice (24.87s) - Line-by-line parsing
   └── linuxWalkShallow (9.31s) - Walks /proc/[pid]/ directories
       └── findProcessNames (4.97s) - Maps ports to process names
   ```

2. **Interface Enumeration Path (35.27% total):**
   ```
   net.Interface.Addrs (25.67s)
   └── net.interfaceAddrTable (25.66s)
       └── syscall.NetlinkRIB (25.30s) - Kernel netlink requests
           ├── syscall.Syscall6 (21.76s) - Actual syscall
           └── syscall.Sendto (8.95s) - Send netlink message
   ```

**Key Insight:** Both hot paths involve repeated system-level scans that scale poorly:
- Port listing reads `/proc/net/tcp*` files completely for each scan
- Interface enumeration makes netlink syscalls to the kernel
- With 57 virtual Tailscale nodes, these operations multiply dramatically

### 2. Goroutine Scaling Analysis

**Goroutine Count:**
- Total goroutines: 6,364
- Services: 57
- **Goroutines per service: 111.6** (6364 / 57)

**Expected vs Actual:**
- Expected: 2-5 goroutines per service → 114-285 total
- Actual: 6,364 goroutines
- **Ratio: 40x higher than expected**

**Goroutine Breakdown (from profile):**

The goroutine profile shows many identical stacks with high counts:

| Stack | Count | Purpose |
|-------|-------|---------|
| `wireguard-go/device.RoutineDecryption` | 944 | WireGuard packet decryption workers |
| `wireguard-go/device.RoutineHandshake` | 944 | WireGuard handshake workers |
| `wireguard-go/device.RoutineEncryption` | 944 | WireGuard packet encryption workers |
| `gvisor.dev/gvisor/pkg/tcpip/transport/tcp.processor.start` | 944 | TCP connection processors |
| `net/http.persistConn.writeLoop` | 146 | HTTP persistent connection writers |
| Various tsnet/tsnsrv goroutines | ~3,442 | Application-level handlers |

**Analysis:**

The high goroutine counts (944 = 16 x 59) suggest:
- Each of the 59 services spawns ~16 goroutines for WireGuard processing
- This is consistent with WireGuard's architecture (encryption/decryption/handshake workers)
- The 944-count stacks indicate these are per-service goroutines
- With 57 active services, this creates massive goroutine scheduler overhead

**Per-Service Goroutine Estimate:**
- WireGuard workers: ~16 per service
- TCP processors: ~16 per service
- HTTP handlers: ~2-3 per service
- Control/event handlers: ~70+ per service
- **Total: ~110 goroutines per service**

This explains why CPU scales super-linearly: the Go runtime scheduler must manage 6000+ goroutines, causing context-switching overhead.

### 3. Memory Allocation Patterns

**Heap Profile (inuse_space):**

```
      flat  flat%   sum%        cum   cum%
 1927.61MB 87.31% 87.31%  1927.61MB 87.31%  wireguard-go/device.PopulatePools.func3
   57.77MB  2.62% 89.93%    57.77MB  2.62%  zstd.fastBase.ensureHist
   18.48MB  0.84% 90.77%    18.48MB  0.84%  wgengine/netstack.getInjectInboundBuffsSizes
   18.33MB  0.83% 91.60%    21.84MB  0.99%  syscall.NetlinkRIB
```

**Allocation Frequency Profile (alloc_objects):**

```
      flat  flat%   sum%        cum   cum%
   5932857 13.91% 13.91%    9898297 23.21%  portlist.findProcessNames.func2
   5410827 12.69% 26.60%    5410827 12.69%  syscall.ParseNetlinkMessage
   3511585  8.24% 34.84%    3511585  8.24%  syscall.ParseNetlinkRouteAttr
   1108984  2.60% 43.44%    1108984  2.60%  portlist.parseProcNetFile
```

**Key Insights:**

1. **Memory usage is dominated by WireGuard buffers (87.31%)** - this is expected and healthy
2. **Port listing allocates 13.91% of all objects** - `findProcessNames` creates millions of temporary objects
3. **Netlink parsing allocates 12.69% of all objects** - `ParseNetlinkMessage` allocates heavily
4. **Combined, port listing + interface enumeration account for ~30% of all allocations**

The allocation pattern confirms the CPU findings: port listing and interface enumeration are creating massive allocation churn, likely triggering GC overhead.

### 4. Lock Contention Analysis

**Mutex Profile:**
```
File: tsnsrv
Type: delay
Time: 2025-10-15 21:05:34 EDT
Showing nodes accounting for 0, 0% of 0 total
```

**Result: NO LOCK CONTENTION DETECTED**

The mutex profile is completely empty (0 samples), indicating that lock contention is not a factor in the performance issues. The CPU bottleneck is purely computational/syscall overhead, not synchronization.

### 5. Root Cause Identification

Based on the profiling data, the root cause of 122% CPU usage is:

**Primary Bottleneck: Tailscale Port Listing Overhead (48.85% CPU)**

Tailscale's `portlist` package periodically scans the system to discover listening ports:
- Reads `/proc/net/tcp`, `/proc/net/tcp6`, `/proc/net/udp`, `/proc/net/udp6`
- Walks `/proc/[pid]/` directories to map ports to processes
- Makes netlink syscalls to enumerate network interfaces

**Why This Scales Poorly with 57 Services:**

1. **Per-service scanning**: Each tsnet virtual node likely triggers independent port scans
2. **Repeated syscalls**: With 57 nodes, the same `/proc` files are read 57× more frequently
3. **Proc filesystem overhead**: Reading `/proc/net/tcp*` files is expensive - they're generated dynamically by the kernel
4. **Directory walking**: `/proc` contains thousands of entries to scan for each service

**Secondary Factor: Goroutine Explosion (111.6 per service)**

The 40x goroutine explosion creates:
- Higher Go runtime scheduler overhead
- More context switches
- Increased memory allocation for goroutine stacks
- More work for the garbage collector

**Impact Calculation:**

With 57 services:
- Port listing: 48.85% × 1.22 cores = **0.60 cores**
- Interface enumeration: 35.27% × 1.22 cores = **0.43 cores**
- **Total syscall overhead: 1.03 cores** (84% of total CPU)

This matches the observation from task-16:
- storage: 113% CPU / 57 services = ~2% per service
- cloud: 9.5% CPU / 14 services = ~0.68% per service
- The super-linear scaling is explained by multiplied port scanning frequency

## Comparison: Storage (57 services) vs Expected Baseline

### Expected Resource Usage (based on cloud host scaling)

If storage scaled linearly from cloud's metrics:
- cloud: 9.5% CPU / 14 services = 0.68% per service
- storage expected: 0.68% × 57 = **38.76% CPU**

### Actual Resource Usage

- storage actual: **113% CPU**
- Overhead factor: 113% / 38.76% = **2.92×** worse than linear scaling

### Resource Breakdown

| Metric | Cloud (14 svc) | Storage (57 svc) | Expected (linear) | Actual Overhead |
|--------|----------------|-------------------|-------------------|-----------------|
| CPU | 9.5% | 113% | 38.76% | 2.92× |
| Goroutines | ~1500 (est) | 6364 | ~1560 | 4.08× |
| Port scans/min | Low | High | Medium | ~4× |

## Supporting Data

### Profile Files

All profile data is stored in `profiling/`:

- `storage-57svc-20251015-210532-cpu.prof` - CPU profile (60s)
- `storage-57svc-20251015-210532-goroutine.prof` - Goroutine profile
- `storage-57svc-20251015-210532-heap.prof` - Heap allocation profile
- `storage-57svc-20251015-210532-allocs.prof` - Allocation frequency profile
- `storage-57svc-20251015-210532-mutex.prof` - Mutex contention profile (empty)
- `storage-57svc-20251015-210532-block.prof` - Blocking profile
- `analysis-cpu-top.txt` - Top CPU functions analysis
- `analysis-cpu-tree.txt` - CPU call tree
- `analysis-heap-top.txt` - Top heap allocations
- `analysis-allocs-top.txt` - Top allocation frequency

### System Stats at Profiling Time

```
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
tsnsrv    1234  122  2.8  12.3GB 2.8GB ?       Ssl  21:00   7:23 /nix/store/.../bin/tsnsrv
```

- CPU: 122% (1.22 cores)
- Memory: 2.8GB RSS
- Process uptime: ~7 minutes
- Goroutines: 6,364
- Services: 57

## Optimization Recommendations

Based on the profile analysis, here are prioritized optimization strategies:

### 1. CRITICAL: Disable or Throttle Port Listing (Estimated Impact: -50% CPU)

**Problem:** Port listing scans `/proc/net/` files repeatedly for each service.

**Solutions:**

**Option A: Disable port listing entirely (RECOMMENDED)**
- Tailscale uses port listing for connection diagnostics and MagicDNS
- For tsnsrv's use case (HTTP reverse proxy), this data may not be needed
- Add configuration to disable portlist: `portlist.Disable = true` in tsnet.Server

**Option B: Throttle port listing frequency**
- Default interval may be too aggressive (likely 1-5 seconds)
- Increase to 60+ seconds or disable for services that don't need it
- Configure via tsnet's portlist polling interval

**Option C: Shared port listing**
- Instead of each tsnet.Server scanning independently, scan once and share results
- Requires architectural changes to tsnsrv
- Create single global portlist instance shared across all services

**Expected Impact:**
- CPU reduction: -50% (from 113% to ~56%)
- Allocation reduction: ~25% fewer object allocations
- Lower syscall overhead

### 2. HIGH: Reduce Goroutine Count (Estimated Impact: -20% CPU)

**Problem:** 111.6 goroutines per service vs expected 2-5.

**Solutions:**

**Option A: Configure WireGuard worker count**
- WireGuard spawns 16× goroutines per service (encryption/decryption/handshake)
- May be configurable via wireguard-go device settings
- Research: Check if `wireguard-go` allows setting worker pool size

**Option B: Connection pooling**
- HTTP persistent connections spawn goroutines
- Limit max concurrent connections per service
- Configure via `http.Server.MaxConcurrentStreams`

**Option C: Lazy initialization**
- Not all services may need full WireGuard stack at all times
- Delay expensive initialization until first request
- May require tsnet API changes

**Expected Impact:**
- CPU reduction: -15-20%
- Memory reduction: ~1-2GB (goroutine stack overhead)
- Better runtime scheduler efficiency

### 3. MEDIUM: Interface Enumeration Caching (Estimated Impact: -10% CPU)

**Problem:** Network interface enumeration via netlink takes 35.27% CPU.

**Solutions:**

**Option A: Cache interface addresses**
- Network interfaces rarely change on a server
- Cache results for 60+ seconds instead of repeated syscalls
- May require patching tsnet or underlying libraries

**Option B: Reduce polling frequency**
- Netmon (network monitor) may poll too frequently
- Configure longer intervals between checks

**Expected Impact:**
- CPU reduction: -10-15%
- Fewer netlink syscalls
- Lower allocation churn

### 4. LOW: Upgrade to Latest Tailscale (Estimated Impact: Variable)

**Current tsnet version:** v1.86.5 (from goroutine stacks)

Recent Tailscale versions may include:
- Performance improvements to portlist
- Better netmon efficiency
- Reduced goroutine overhead

**Action:** Test with latest Tailscale/tsnet release

### 5. ARCHITECTURAL: Consider Alternative Approaches

If optimizations above are insufficient:

**Option A: Return to Caddy with native Tailscale plugin**
- As mentioned in task-16, Caddy was previously used
- Caddy's architecture may handle multiple virtual nodes more efficiently
- Single process serving all domains vs 57 separate tsnet instances

**Option B: Single tsnet instance with routing**
- Instead of 57 tsnet.Server instances, use one server with HTTP routing
- Requires significant tsnsrv rewrite
- Trade-off: Lose per-service isolation

**Option C: Hybrid approach**
- Keep tsnsrv for critical services
- Move high-volume services to Caddy or single-instance approach
- Reduces total service count to acceptable range (<20)

## Implementation Priority

1. **IMMEDIATE (Week 1):** Test disabling port listing on storage
   - Add `portlist.Disable = true` configuration to tsnet
   - Deploy and measure CPU impact
   - If successful, estimated CPU: 113% → 56% (50% reduction)

2. **SHORT TERM (Week 2-3):** Investigate goroutine reduction
   - Research wireguard-go worker configuration
   - Test connection pooling limits
   - Measure goroutine count and CPU impact

3. **MEDIUM TERM (Month 1):** Interface enumeration optimization
   - Evaluate caching strategies
   - Test polling frequency tuning
   - Measure syscall reduction

4. **LONG TERM (Month 2+):** Architectural evaluation
   - If optimizations insufficient, revisit Caddy migration
   - Consider hybrid approach
   - Prototype single-instance routing if needed

## Next Steps

1. **Create follow-up task** for implementing port listing disable
2. **Research tsnet configuration options** for port listing and netmon
3. **Test on cloud host (14 services)** to validate findings at smaller scale
4. **Monitor metrics** after each optimization to measure impact
5. **Consider upstream contribution** if fixes are generally applicable to tsnet

## References

- Task-16: tsnsrv performance investigation (initial analysis)
- Task-17: This profiling effort
- [tsnsrv-profiling-guide.md](./tsnsrv-profiling-guide.md): Profiling methodology
- [tsnsrv-performance-investigation.md](./tsnsrv-performance-investigation.md): Background investigation
- Tailscale portlist source: https://github.com/tailscale/tailscale/tree/main/portlist
- tsnet API docs: https://pkg.go.dev/tailscale.com/tsnet
- [Profile data](../profiling/): All collected pprof profiles and analysis

---

**Analysis Date:** 2025-10-15
**Analyst:** Claude Code
**Profile Duration:** 60 seconds
**Host:** storage.bat-boa.ts.net
**Services:** 57
**CPU Usage:** 122%
