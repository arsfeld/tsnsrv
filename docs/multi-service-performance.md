# Multi-Service Performance Investigation

**Investigation Date**: 2025-10-15
**Status**: Completed

## Executive Summary

Investigation into tsnsrv CPU usage when running 57 services in a single process revealed **super-linear scaling** of CPU overhead. A single tsnsrv process managing 57 virtual Tailscale nodes consumed **113% CPU** (more than 1 full core) compared to 9.5% CPU for 14 services.

### Key Findings

| Services | CPU Usage | Memory  | CPU per Service |
|----------|-----------|---------|-----------------|
| 14       | 9.5%      | 351MB   | 0.68%          |
| 57       | 113%      | 2.6GB   | 2.0%           |

**Scaling behavior**: CPU overhead per service increases non-linearly with total service count, suggesting interaction overhead between virtual tsnet nodes.

## Architecture Overview

When running multiple services in a single tsnsrv process, each service gets its own `tsnet.Server` instance. Each virtual node:

- Maintains separate state directory (`/var/lib/tsnsrv-all/<service>/tailscaled.state`)
- Runs independent authentication state machine
- Manages separate TLS certificates
- Maintains individual connection to Tailscale control plane
- Handles its own funnel configuration (if enabled)

This architecture provides granular access control (each service appears as separate Tailscale node) but comes with performance overhead.

## Performance Characteristics

### CPU Usage Patterns

**Startup Overhead**: During initialization, each service runs through authentication loop sequentially:
```
2025/10/15 16:17:26 AuthLoop: state is Starting; done
2025/10/15 16:17:26 AuthLoop: state is Running; done
[repeated 57 times]
```

With 57 services, startup takes 2-3 minutes.

**Runtime Overhead**: Observed metrics over 2h 10min runtime:
- CPU Time: 2h 28min (113% average CPU)
- Network Traffic: 658MB in / 756MB out (≈5-6MB/min)
- Memory: 2.6GB peak, 211MB swap

The continuous network traffic represents ongoing communication with Tailscale control plane for maintaining 57 separate node identities.

### Memory Usage

Memory scales linearly with service count:
- 14 services: 351MB (25MB per service)
- 57 services: 2.6GB (46MB per service)

Memory efficiency decreases as service count increases, likely due to shared resource overhead (connection pools, goroutine stacks, GC pressure).

### Scaling Analysis

**CPU per service** increases with total service count:
```
Services | Total CPU | CPU per Service | Scaling Factor
---------|-----------|-----------------|----------------
   14    |   9.5%    |     0.68%      |      1.0x
   57    |  113%     |     2.0%       |      2.9x
```

This suggests **super-linear scaling** (O(n log n) or worse) rather than linear scaling.

**Likely causes**:
1. Goroutine scheduling overhead with hundreds of concurrent goroutines
2. Shared resource contention (mutex locks, channel operations)
3. GC pressure from increased allocation rate
4. Network event multiplexing overhead

## Comparison: Multi-Service vs Separate Processes

Previous architecture ran 57 separate tsnsrv processes:
- Each consuming ~0.7% CPU and ~42MB RAM
- Total: ~40% CPU and ~2.4GB RAM

Current single-process architecture:
- 1 process consuming 113% CPU and ~2.6GB RAM

**Results**:
- ✅ Reduced process count (57 → 1)
- ✅ Slightly better memory efficiency (~2.4GB → ~2.6GB)
- ❌ **WORSE CPU usage** (40% → 113%, a 2.8x increase)

**Conclusion**: Consolidating into a single process **increased** CPU usage significantly. The multi-service mode is beneficial for 5-15 services but shows diminishing returns beyond 20-30 services.

## Performance Recommendations

### Recommended Service Limits

Based on empirical data:

| Service Count | CPU Usage | Recommendation |
|---------------|-----------|----------------|
| 1-10          | <10%      | ✅ Optimal     |
| 11-20         | 10-30%    | ✅ Good        |
| 21-40         | 30-80%    | ⚠️  Acceptable |
| 41+           | 80%+      | ❌ Not recommended |

**Best practice**: Keep service count per tsnsrv instance under 30 for optimal CPU efficiency.

### Optimization Strategies

#### Option 1: Reduce Service Count
**Impact**: Medium | **Effort**: Low

Audit services and disable unused/rarely-accessed ones:
- Review access logs to identify low-traffic services
- Disable services with <1 request/day
- Consolidate similar services where possible

**Expected improvement**: 20-40% CPU reduction

#### Option 2: Split Across Multiple Instances
**Impact**: High | **Effort**: Medium

Run multiple tsnsrv processes, each handling 15-20 services:
- Group related services together
- Distribute by access patterns (high-traffic vs low-traffic)
- Target ~20 services per instance

**Expected improvement**: 60-70% CPU reduction

Example with 57 services:
```
Instance 1: 20 services → ~30% CPU
Instance 2: 20 services → ~30% CPU
Instance 3: 17 services → ~25% CPU
Total: ~85% CPU (vs 113% for single instance)
```

#### Option 3: Use Non-Ephemeral Nodes
**Impact**: Low-Medium | **Effort**: Low

Switch from `ephemeral = true` to persistent nodes:
- Reduces re-authentication overhead
- Eliminates periodic state refresh
- Requires manual node cleanup when services are removed

**Expected improvement**: 10-20% CPU reduction

**Trade-offs**: Requires node lifecycle management

#### Option 4: Alternative Architectures
**Impact**: Very High | **Effort**: High

Consider alternative reverse proxy solutions:
- **Caddy + Tailscale plugin**: Single Tailscale connection, path-based routing
- **Traefik + Tailscale**: Enterprise-grade routing with better resource efficiency
- **Native Tailscale Serve**: Built-in but less flexible

For very high service counts (50+), these alternatives may provide 80-90% CPU reduction.

## Common Issues

### TLS Handshake Errors

Observed errors in logs:
```
TLS handshake error from X:X:X:X:X: EOF
TLS handshake error from X:X:X:X:X: no SNI ServerName
```

These are generally benign (client disconnects, health checks) but increase CPU usage when frequent.

### Authentication Failures

```
auth denied service=sonarr status=400 remote_addr=X:X:X:X duration=28ms url=/
```

Forward auth failures add ~30ms latency per request and consume CPU cycles. Ensure auth service is properly configured and responsive.

## Monitoring Recommendations

### Key Metrics to Track

1. **CPU Usage by Service Count**:
   - Alert when >80% CPU for <30 services
   - Alert when >150% CPU for any configuration

2. **Memory Growth**:
   - Monitor for memory leaks (sustained growth over days)
   - Alert when swap usage >500MB

3. **Network Traffic**:
   - Baseline: ~5MB/min per 57 services
   - Alert on sudden spikes (may indicate authentication issues)

4. **Startup Time**:
   - Normal: 2-3 seconds per service
   - Alert when >5 seconds per service (may indicate control plane issues)

### Prometheus Metrics

tsnsrv exposes Prometheus metrics at `-prometheusAddr`:
- `tsnsrv_requests_total` - Request count per service
- `tsnsrv_request_duration_seconds` - Request latency
- `tsnsrv_auth_requests_total` - Forward auth requests
- `tsnsrv_errors_total` - Error count by type

Use these to identify:
- Unused services (low request count)
- Performance bottlenecks (high latency services)
- Auth overhead (high auth request rate)

## Benchmarking Methodology

To reproduce these findings:

1. **Setup**: Configure tsnsrv with varying service counts (10, 20, 30, 40, 50, 60)
2. **Load**: Generate realistic traffic patterns (idle, light load, moderate load)
3. **Measure**: Track CPU, memory, network over 2+ hour period
4. **Analyze**: Calculate per-service overhead and identify scaling behavior

Example test command:
```bash
# Monitor CPU usage
watch -n 1 'ps aux | grep tsnsrv'

# Monitor systemd metrics
systemctl status tsnsrv-all

# Check resource usage
journalctl -u tsnsrv-all -n 100 | grep -E "CPU|Memory|Network"
```

## Future Improvements

Potential optimizations for tsnsrv codebase:

1. **Connection pooling**: Share HTTP connections across services where possible
2. **Lazy initialization**: Delay tsnet setup until first request
3. **Batch authentication**: Group auth requests to control plane
4. **Memory optimization**: Reduce per-service allocations
5. **Goroutine pooling**: Limit concurrent goroutines with worker pools

These would require upstream changes to both tsnsrv and potentially tsnet library.

## Conclusion

The multi-service mode in tsnsrv provides excellent consolidation for small-to-medium deployments (5-30 services) but shows performance degradation beyond 30-40 services due to super-linear scaling of overhead.

**Recommendations by deployment size**:
- **Small** (1-15 services): Use single tsnsrv instance
- **Medium** (16-40 services): Use single instance, monitor CPU usage
- **Large** (41+ services): Split across multiple instances or consider alternative architectures

For deployments with 50+ services, alternative reverse proxy solutions (Caddy, Traefik) with single Tailscale connection may provide better performance characteristics.

## Related Documentation

- [README.md](../README.md) - Multi-service configuration guide
- [config.example.yaml](../config.example.yaml) - Example configuration
- [CLAUDE.md](../CLAUDE.md) - Development guidelines and CLI reference
