# CPU Scaling Performance Investigation

This directory contains tools for investigating the super-linear CPU scaling issue in multi-service mode.

## Problem Statement

Current observations show severe performance degradation:
- 14 services: 9.5% CPU (0.68% per service)
- 57 services: 113% CPU (2.0% per service) - **2.9x worse per-service overhead**

This investigation aims to identify the root causes using Go profiling tools.

## Setup

The application has been modified to expose pprof endpoints at `http://localhost:9099/debug/pprof/` alongside the existing Prometheus metrics.

### Available Profiles

- **CPU Profile** (`/debug/pprof/profile`): Shows where CPU time is being spent
- **Heap Profile** (`/debug/pprof/heap`): Memory allocation profile
- **Goroutine Profile** (`/debug/pprof/goroutine`): Number and state of goroutines
- **Mutex Profile** (`/debug/pprof/mutex`): Lock contention profile
- **Block Profile** (`/debug/pprof/block`): Blocking operations profile
- **Allocs Profile** (`/debug/pprof/allocs`): All memory allocations (past and present)

## Usage

### 1. Generate Test Configurations

```bash
./generate_configs.sh
```

This creates YAML configs for 10, 20, 30, 40, and 50 services in `configs/`.

### 2. Collect Profiles

```bash
# Set your Tailscale auth key
export TS_AUTHKEY="tskey-auth-..."

# Run profiling
./collect_profiles.sh
```

This will:
1. Build tsnsrv
2. For each service count (10, 20, 30, 40, 50):
   - Start tsnsrv with the config
   - Wait 30s for warmup
   - Collect all profile types
   - Record process statistics
   - Stop the service

Results are saved to `results/<count>_services/`.

### 3. Analyze Profiles

#### Quick Analysis

```bash
# View top CPU consumers
go tool pprof -top tsnsrv results/50_services/cpu.prof

# View top memory allocators
go tool pprof -top tsnsrv results/50_services/heap.prof

# View goroutine counts
go tool pprof -top tsnsrv results/50_services/goroutine.prof

# View mutex contention
go tool pprof -top tsnsrv results/50_services/mutex.prof
```

#### Interactive Analysis

```bash
# Start interactive pprof
go tool pprof tsnsrv results/50_services/cpu.prof

# Common commands in pprof:
# - top         : Show top CPU consumers
# - list <func> : Show source code for function
# - web         : Generate SVG call graph (requires graphviz)
# - peek <func> : Show callers and callees
```

#### Compare Across Service Counts

```bash
# Compare CPU usage between 10 and 50 services
go tool pprof -base=results/10_services/cpu.prof results/50_services/cpu.prof

# This shows the delta, highlighting functions that scale poorly
```

#### Generate Visualizations

```bash
# Generate SVG call graph
go tool pprof -svg tsnsrv results/50_services/cpu.prof > cpu_graph.svg

# Generate flame graph (requires go-torch or pprof web UI)
go tool pprof -http=:8080 tsnsrv results/50_services/cpu.prof
```

## Investigation Checklist

Based on task-5 acceptance criteria:

- [ ] CPU profiling data collected for 10, 20, 30, 40, 50 service configurations
- [ ] Goroutine count scaling behavior analyzed and documented
- [ ] Memory allocation and GC profile analyzed for scaling patterns
- [ ] Mutex contention profile analyzed for shared resource bottlenecks
- [ ] Root cause(s) of super-linear scaling identified with evidence
- [ ] Specific code locations causing performance degradation pinpointed
- [ ] At least 3 viable optimization strategies documented with estimated impact
- [ ] Performance improvement plan created with implementation priorities

## Key Areas to Investigate

Based on the architecture and expected bottlenecks:

### 1. Goroutine Scheduling Overhead

Each `tsnet.Server` spawns multiple goroutines. With 50 services, this could be hundreds of goroutines competing for CPU.

**Analysis approach:**
- Check goroutine count scaling: `cat results/*/goroutine_count.txt`
- Look for scheduling overhead in CPU profile
- Identify goroutines that are constantly active vs idle

### 2. Shared Resource Contention

Multiple services may contend for shared resources like:
- Mutex locks in tsnet library
- Channel operations
- Network I/O multiplexing

**Analysis approach:**
- Check mutex profile for lock contention
- Look for blocking operations in block profile
- Compare mutex contention across service counts

### 3. GC Pressure

More services = more allocations = more GC overhead.

**Analysis approach:**
- Compare heap profiles across service counts
- Check allocation rates in allocs profile
- Look for GC-related functions in CPU profile
- Calculate per-service allocation overhead

### 4. Network Event Multiplexing

The tsnet library may have O(n²) behavior in network event handling.

**Analysis approach:**
- Profile CPU usage in network-related functions
- Look for polling or event dispatching code
- Check if CPU usage increases when idle (no actual traffic)

## Expected Findings

Based on the empirical data (2.9x worse per-service overhead at 57 services), we expect to find:

1. **Primary cause**: One or more functions showing super-linear growth in CPU time
2. **Scaling pattern**: CPU usage per function should be plotted against service count
3. **Hotspots**: Specific code paths (likely in tsnet or goroutine management) consuming disproportionate CPU

## Optimization Strategy Development

Once root causes are identified, evaluate:

1. **Code-level fixes**: Can we optimize the hot paths?
2. **Resource pooling**: Can we share resources better?
3. **Lazy initialization**: Can we defer work until needed?
4. **Worker pools**: Can we limit goroutine count?
5. **Upstream changes**: Do we need tsnet library modifications?

## Notes

- Profiles are collected after 30s warmup to capture steady-state behavior
- Services don't handle actual traffic during profiling (no upstream services running)
- This isolates the overhead of maintaining multiple tsnet.Server instances
- Real-world performance may differ with actual traffic

## References

- Go pprof documentation: https://pkg.go.dev/net/http/pprof
- Profiling Go Programs: https://go.dev/blog/pprof
- Initial performance analysis: `docs/multi-service-performance.md`
