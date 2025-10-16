# Profiling the Running tsnsrv Instance

This guide shows how to enable and use Go pprof profiling on the running tsnsrv service to investigate CPU usage.

## Overview

The tsnsrv fork includes built-in pprof support that exposes profiling endpoints when `prometheusAddr` is configured. This allows you to:

- Collect CPU profiles showing where time is spent
- Analyze memory allocations and heap usage
- Inspect goroutine counts and blocking behavior
- Identify mutex contention issues

## Step 1: Enable pprof Endpoints

Edit the tsnsrv configuration to enable the Prometheus/pprof endpoint:

```nix
# hosts/storage/services/misc.nix
services.tsnsrv = {
  enable = true;
  defaults = {
    tags = ["tag:service"];
    authKeyPath = config.age.secrets.tailscale-key.path;
    ephemeral = true;
    prometheusAddr = "127.0.0.1:9099";  # ← Add this line
  };
};
```

**Security Note**: The address `127.0.0.1:9099` binds to localhost only, preventing external access. For remote profiling, you can:
- Use SSH port forwarding: `ssh -L 9099:localhost:9099 storage.bat-boa.ts.net`
- Or bind to Tailscale IP: `100.x.x.x:9099` (only accessible via Tailnet)

## Step 2: Deploy the Change

```bash
just deploy storage
```

After deployment, verify the endpoint is accessible:

```bash
# From storage host
curl http://localhost:9099/debug/pprof/

# Or via SSH port forwarding from your workstation
ssh -L 9099:localhost:9099 storage.bat-boa.ts.net
# Then in another terminal:
curl http://localhost:9099/debug/pprof/
```

You should see an HTML page listing available profiles.

## Step 3: Collect Profiles

### Option A: Using curl (Simple)

Collect a 30-second CPU profile:

```bash
# Via SSH on storage host
curl -s "http://localhost:9099/debug/pprof/profile?seconds=30" > /tmp/cpu.prof

# Download to your workstation
scp storage.bat-boa.ts.net:/tmp/cpu.prof ./tsnsrv-cpu.prof
```

Collect other profile types:

```bash
# Heap (memory allocations)
curl -s "http://localhost:9099/debug/pprof/heap" > /tmp/heap.prof

# Goroutines (running goroutines)
curl -s "http://localhost:9099/debug/pprof/goroutine" > /tmp/goroutine.prof

# Mutex (lock contention)
curl -s "http://localhost:9099/debug/pprof/mutex" > /tmp/mutex.prof

# Blocking (I/O and channel operations)
curl -s "http://localhost:9099/debug/pprof/block" > /tmp/block.prof

# All allocations
curl -s "http://localhost:9099/debug/pprof/allocs" > /tmp/allocs.prof
```

### Option B: Using SSH Port Forwarding (Recommended)

From your workstation:

```bash
# Terminal 1: Create SSH tunnel
ssh -L 9099:localhost:9099 storage.bat-boa.ts.net

# Terminal 2: Collect profiles
curl -s "http://localhost:9099/debug/pprof/profile?seconds=30" > cpu.prof
curl -s "http://localhost:9099/debug/pprof/heap" > heap.prof
curl -s "http://localhost:9099/debug/pprof/goroutine" > goroutine.prof
```

### Option C: Direct pprof Analysis (Interactive)

Using SSH tunnel from above:

```bash
# Interactive CPU profile (opens web browser)
go tool pprof -http=:8080 http://localhost:9099/debug/pprof/profile?seconds=30

# Terminal-based analysis
go tool pprof http://localhost:9099/debug/pprof/profile?seconds=30
```

## Step 4: Analyze Profiles

### Quick Analysis: Top Functions

```bash
# Show top CPU consumers
go tool pprof -top cpu.prof

# Show top memory allocators
go tool pprof -top heap.prof

# Show goroutine count and stacks
go tool pprof -top goroutine.prof
```

Example output:
```
Showing nodes accounting for 12.50s, 88.65% of 14.10s total
Dropped 157 nodes (cum <= 0.07s)
Showing top 10 nodes out of 89
      flat  flat%   sum%        cum   cum%
     3.20s 22.70% 22.70%      3.20s 22.70%  runtime.futex
     2.10s 14.89% 37.59%      2.10s 14.89%  syscall.Syscall
     1.80s 12.77% 50.35%      1.80s 12.77%  runtime.pthread_cond_wait
     1.50s 10.64% 60.99%      2.60s 18.44%  tailscale.com/tsnet.(*Server).Up
     ...
```

### Interactive Web UI Analysis

The web UI provides rich visualization:

```bash
# Open interactive web interface
go tool pprof -http=:8080 cpu.prof
```

This opens a browser with:
- **Graph view**: Call graph showing function relationships
- **Flame graph**: Hierarchical view of CPU usage
- **Top**: List of hot functions
- **Source**: Annotated source code showing CPU usage per line

### Compare Profiles Over Time

Collect a baseline and comparison profile:

```bash
# Baseline (right after restart)
systemctl restart tsnsrv-all
sleep 60  # Let it stabilize
curl -s "http://localhost:9099/debug/pprof/profile?seconds=30" > baseline.prof

# After running for a while
sleep 3600  # Wait 1 hour
curl -s "http://localhost:9099/debug/pprof/profile?seconds=30" > after-1h.prof

# Compare (shows what changed)
go tool pprof -base=baseline.prof after-1h.prof
```

## Common Profile Types and What They Show

### CPU Profile (`/debug/pprof/profile?seconds=30`)
**What**: Where CPU time is spent
**Look for**:
- Hot loops consuming excessive CPU
- Functions that scale poorly with service count
- Unexpected syscalls or locking

**Example finding**: If `tsnet.(*Server).Up` shows high CPU, it suggests authentication/connection overhead.

### Heap Profile (`/debug/pprof/heap`)
**What**: Current memory allocations
**Look for**:
- Memory leaks (allocations that never decrease)
- Large allocations per service
- Buffer sizes that could be optimized

### Goroutine Profile (`/debug/pprof/goroutine`)
**What**: Number and state of goroutines
**Look for**:
- Goroutine explosion (100s or 1000s of goroutines)
- Blocked goroutines waiting on locks
- Goroutines per service ratio

**Expected**: With 57 services, you might see 500-2000 goroutines. More than 5000 suggests a problem.

### Mutex Profile (`/debug/pprof/mutex`)
**What**: Lock contention
**Look for**:
- Mutexes with high contention time
- Locks that don't scale with service count

**Note**: Requires enabling mutex profiling:
```bash
# First, enable mutex profiling (one-time)
curl -X POST "http://localhost:9099/debug/pprof/mutex?rate=1"
# Then collect after some runtime
curl -s "http://localhost:9099/debug/pprof/mutex" > mutex.prof
```

### Block Profile (`/debug/pprof/block`)
**What**: Blocking operations (channels, I/O)
**Look for**:
- Channel operations that block frequently
- I/O bottlenecks

## Analyzing Specific Issues

### Issue: High CPU Usage

```bash
# Collect CPU profile during high usage
curl -s "http://localhost:9099/debug/pprof/profile?seconds=60" > high-cpu.prof

# Analyze top functions
go tool pprof -top high-cpu.prof

# Look at specific function
go tool pprof -list='tailscale.*Server' high-cpu.prof

# Generate flame graph
go tool pprof -svg high-cpu.prof > flame.svg
```

**What to look for**:
- Functions consuming >10% CPU individually
- Syscalls like `futex`, `epoll_wait` (indicates locking/waiting)
- GC overhead (`runtime.gcDrain`) >5%

### Issue: Memory Growth

```bash
# Collect heap profile
curl -s "http://localhost:9099/debug/pprof/heap" > heap.prof

# Show allocation sites
go tool pprof -alloc_space -top heap.prof

# Interactive analysis
go tool pprof -http=:8080 heap.prof
```

**What to look for**:
- Allocations that grow linearly with service count
- Large byte array allocations
- String allocations (often can be reduced)

### Issue: Goroutine Explosion

```bash
# Get goroutine dump
curl -s "http://localhost:9099/debug/pprof/goroutine?debug=1" > goroutines.txt

# Count goroutines
grep "^goroutine" goroutines.txt | wc -l

# Find most common goroutine stacks
grep -A 10 "^goroutine" goroutines.txt | \
  grep -v "^--$" | \
  sort | uniq -c | sort -rn | head -20
```

**Expected goroutine patterns** (for 57 services):
- ~2-5 goroutines per tsnet.Server (114-285 total)
- HTTP handlers (varies with traffic)
- Control plane communication (57 connection handlers)

**Problem indicators**:
- >10 goroutines per service (>570 total)
- Goroutines blocked in locks
- Runaway goroutine leaks

## Continuous Profiling (Optional)

For long-term monitoring, collect profiles periodically:

```bash
#!/bin/bash
# collect-continuous.sh
INTERVAL=3600  # 1 hour
OUTDIR="./profiles/$(date +%Y%m%d)"
mkdir -p "$OUTDIR"

while true; do
  TIMESTAMP=$(date +%H%M%S)
  curl -s "http://localhost:9099/debug/pprof/profile?seconds=30" \
    > "$OUTDIR/cpu-$TIMESTAMP.prof"
  curl -s "http://localhost:9099/debug/pprof/heap" \
    > "$OUTDIR/heap-$TIMESTAMP.prof"

  echo "Collected profiles at $TIMESTAMP"
  sleep "$INTERVAL"
done
```

Run this in a tmux/screen session to collect profiles over days/weeks.

## Quick Reference

### Collect All Profiles

```bash
#!/bin/bash
# Quick collection script
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="tsnsrv-$TIMESTAMP"

curl -s "http://localhost:9099/debug/pprof/profile?seconds=30" > "${PREFIX}-cpu.prof"
curl -s "http://localhost:9099/debug/pprof/heap" > "${PREFIX}-heap.prof"
curl -s "http://localhost:9099/debug/pprof/goroutine" > "${PREFIX}-goroutine.prof"
curl -s "http://localhost:9099/debug/pprof/allocs" > "${PREFIX}-allocs.prof"
curl -s "http://localhost:9099/debug/pprof/goroutine?debug=1" > "${PREFIX}-goroutines.txt"

echo "Profiles saved with prefix: $PREFIX"
```

### Common Analysis Commands

```bash
# Top 20 CPU consumers
go tool pprof -top -nodecount=20 cpu.prof

# Interactive web UI
go tool pprof -http=:8080 cpu.prof

# Generate SVG graph
go tool pprof -svg cpu.prof > cpu-graph.svg

# Show specific function details
go tool pprof -list='functionName' cpu.prof

# Compare two profiles
go tool pprof -base=before.prof after.prof

# Goroutine count
go tool pprof -raw goroutine.prof | grep "^goroutine" | wc -l
```

## Troubleshooting

### "Connection refused" when accessing pprof endpoint

Check if prometheusAddr is configured and service is running:
```bash
systemctl status tsnsrv-all
journalctl -u tsnsrv-all | grep "prometheus\|pprof\|9099"
```

### Profiles are empty or very small

- Ensure you're collecting for enough time (30-60 seconds for CPU)
- Verify tsnsrv is actually handling traffic
- Check if the service just started (need warmup time)

### "go tool pprof" not found

Install Go on your workstation:
```bash
# NixOS
nix-shell -p go

# Or add to your environment
```

### High overhead from profiling

CPU profiling adds ~5% overhead. If this is a concern:
- Collect shorter profiles (10-15 seconds instead of 30-60)
- Disable after collection (remove prometheusAddr and redeploy)
- Use sampling rate: `?seconds=30&debug=0` (default is already sampled)

## Next Steps

After collecting and analyzing profiles:

1. **Document findings** in `docs/tsnsrv-performance-investigation.md`
2. **Identify hotspots**: Which functions/operations dominate CPU?
3. **Determine root cause**: Locking? GC? Syscalls? Scaling issue?
4. **Propose solutions**: Code optimization? Architecture change?
5. **Validate improvements**: Re-profile after changes

## Related Documentation

- [tsnsrv profiling directory](../../tsnsrv/profiling/) - Automated profiling tools
- [Go pprof documentation](https://pkg.go.dev/net/http/pprof)
- [Profiling Go Programs](https://go.dev/blog/pprof)
- [tsnsrv performance investigation](./tsnsrv-performance-investigation.md)
