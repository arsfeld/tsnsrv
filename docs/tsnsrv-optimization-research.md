# tsnsrv Optimization Research

**Date**: 2025-10-16
**Related Task**: task-9.1
**Purpose**: Research configuration options for optimizing CPU scaling in multi-service mode

## Executive Summary

Research identified **ONE VIABLE HIGH-IMPACT OPTIMIZATION**: Disabling Tailscale port listing via environment variable. Other optimizations (netmon, WireGuard workers, HTTP limits) lack exposed configuration APIs and would require upstream changes or significant architectural modifications.

### Key Findings

| Optimization Target | Status | Impact | Implementation |
|-------------------|---------|---------|----------------|
| **Port Listing** | ✅ VIABLE | ~50% CPU reduction | Environment variable |
| **Netmon** | ❌ NOT CONFIGURABLE | ~15% potential | Requires upstream patch |
| **WireGuard Workers** | ❌ NOT CONFIGURABLE | ~10% potential | Hardcoded in library |
| **HTTP Server Limits** | ⚠️ LIMITED | <5% potential | HTTP/2 settings (minimal gain) |
| **Tailscale Upgrade** | ❌ NO IMPROVEMENTS | 0% | v1.88.3 has no relevant fixes |

---

## 1. Port Listing Configuration ✅ HIGH PRIORITY

### Problem

Port listing consumes **48.85% of CPU** (35.56s/60s profile) by repeatedly scanning `/proc/net/tcp*` and `/proc/[pid]/` at 1-second intervals on Linux (5 seconds on other platforms).

### Solution: Environment Variable

**Environment Variable**: `TS_DEBUG_DISABLE_PORTLIST=true`

### Evidence

- **Tailscale Issue #10430**: "portlist: high CPU usage on otherwise idle system"
  - Users reported 1.3-1.6% constant CPU usage from portlist polling
  - Setting `TS_DEBUG_DISABLE_PORTLIST=true` reduced CPU to "almost nothing"
  - Issue remains open as of October 2025 (no official fix)
- **Root Cause**: 87.78% of CPU time in `tailscale.com/portlist.(*linuxImpl).AppendListeningPorts`
- **Polling Interval**: 1 second on Linux vs 5 seconds on other platforms

### Implementation

#### Option A: Disable Entirely (RECOMMENDED)

**Pros**:
- Eliminates ~50% of CPU usage
- Trivial implementation (set env var)
- Fully reversible
- Low risk (tsnsrv doesn't need port diagnostics)

**Cons**:
- Loses Tailscale port listing diagnostics (acceptable for tsnsrv use case)
- Uses undocumented debug env var (may change in future)

**Implementation**:
```go
// In cli.go, before srv.Up():
os.Setenv("TS_DEBUG_DISABLE_PORTLIST", "true")
```

Or via NixOS module:
```nix
systemd.services.tsnsrv.environment.TS_DEBUG_DISABLE_PORTLIST = "true";
```

#### Option B: Throttle Interval (NOT AVAILABLE)

No API exists to configure polling interval. Would require forking Tailscale or upstream contribution.

#### Option C: Shared Portlist Instance (HIGH COMPLEXITY)

Share single portlist across all 57 tsnet.Server instances. Requires significant architectural changes:
- Modify tsnet initialization to inject shared portlist
- May require patching tsnet library
- High risk, uncertain benefit
- **Verdict**: Defer unless Option A insufficient

### Code Locations

- **tsnsrv**: `cli.go:657` (tsnet.Server initialization)
- **Upstream**: `tailscale.com/portlist` (no configuration API exposed)

### Success Metrics

- CPU usage: 113% → ~56% (50% reduction)
- Port listing time in profile: 48.85% → <5%
- Expected impact: **CRITICAL (highest priority)**

### Recommendation

✅ **IMPLEMENT IMMEDIATELY** - Set `TS_DEBUG_DISABLE_PORTLIST=true` in tsnet.Server initialization

---

## 2. Network Monitor (netmon) Configuration ❌ NOT VIABLE

### Problem

Network interface enumeration consumes **35.27% of CPU** (25.67s/60s) via `net.(*Interface).Addrs` and netlink syscalls.

### Research Findings

**tsnet.Server Fields**: No netmon-specific configuration exposed
**Environment Variables**:
- Various `TS_DEBUG_*` vars exist but none for netmon throttling
- `TS_DEBUG_DISABLE_NETMON` does NOT exist (would crash if netmon is disabled)

**Recent Changes**:
- PR #17292 (Sept-Oct 2025): Refactored netmon callbacks to eventbus
- No configuration API added
- Netmon remains internal to tsnet

### Implementation Options

#### Option A: Caching (REQUIRES UPSTREAM PATCH)

Modify `tailscale.com/net/netmon` to cache interface addresses for 60+ seconds. Requires:
- Fork Tailscale repository
- Patch netmon package
- Maintain fork or upstream contribution
- **Effort**: Medium-High
- **Risk**: Medium (netmon changes affect routing logic)

#### Option B: Upstream Feature Request

File issue with Tailscale requesting netmon throttling configuration:
- Share profiling data from `docs/tsnsrv-pprof-analysis.md`
- Request `TS_DEBUG_NETMON_INTERVAL` env var or tsnet.Server field
- **Timeline**: Weeks to months (if accepted)
- **Benefit**: Community-wide improvement

### Recommendation

❌ **DEFER** - No viable short-term implementation. Consider upstream feature request if port listing fix insufficient.

---

## 3. WireGuard Worker Pool Configuration ❌ NOT VIABLE

### Problem

Goroutine explosion: **111.6 goroutines per service** (6,364 total for 57 services) vs expected 2-5 per service.

Breakdown:
- WireGuard workers: ~16 per service (encryption/decryption/handshake)
- TCP processors: ~16 per service
- HTTP handlers: ~2-3 per service
- Control/event handlers: ~70+ per service

### Research Findings

**wireguard-go**: Tailscale uses userspace wireguard-go (not kernel module)
- Worker pool size is **hardcoded** in `wireguard-go/device`
- No configuration API exposed
- Issue #3765 mentions memory pooling inefficiencies (unresolved)

**tsnet.Server**: No fields for goroutine/worker limits

### Implementation Options

#### Option A: Configure Worker Pool (NOT AVAILABLE)

No API exists. Would require:
- Fork wireguard-go
- Modify worker pool initialization
- Patch Tailscale's wireguard-go integration
- **Effort**: High
- **Risk**: High (affects WireGuard encryption performance)
- **Unknowns**: Optimal worker count per service (may hurt performance)

#### Option B: Kernel WireGuard (NOT COMPATIBLE)

Linux kernel WireGuard module is more efficient but:
- tsnet requires userspace implementation
- Not compatible with tsnet architecture
- **Verdict**: Not applicable

### Recommendation

❌ **NOT FEASIBLE** - No configuration available. Goroutine count is inherent to wireguard-go architecture.

---

## 4. HTTP Server Connection Limits ⚠️ PARTIALLY AVAILABLE

### Problem

HTTP handlers spawn goroutines per connection, contributing to total goroutine count.

### Research Findings

**HTTP/2 Server Settings** (from `golang.org/x/net/http2`):

```go
http2.Server{
    MaxConcurrentStreams: 100, // Default per HTTP/2 spec
    MaxHandlers:          0,   // 0 = unlimited, >0 limits global handler goroutines
}
```

**HTTP/1.1**: No equivalent simple limits (would need custom middleware)

**Current tsnsrv Code** (`cli.go:740`):
```go
tailnetServer := http.Server{
    Handler:           s.mux(transport, false),
    ReadHeaderTimeout: s.ReadHeaderTimeout,
    // No HTTP/2 or connection limits configured
}
```

### Implementation Options

#### Option A: Set HTTP/2 MaxHandlers

Limit total handler goroutines globally:

```go
// Configure HTTP/2 transport with limits
h2s := &http2.Server{
    MaxHandlers: 50, // Limit concurrent handlers per service
}

server := http.Server{
    Handler: s.mux(transport, false),
}

// Register HTTP/2 server
http2.ConfigureServer(&server, h2s)
```

**Pros**:
- Standard Go library feature
- Limits handler goroutine explosion

**Cons**:
- Blocks requests when limit reached (may affect legitimate traffic)
- Requires tuning per service (unknown optimal value)
- Minimal CPU impact (<5%) - handler goroutines are only ~3 per service

**Expected Impact**: LOW (handler goroutines not major contributor)

#### Option B: MaxConcurrentStreams

Default of 100 is already reasonable. Lowering may hurt legitimate concurrent connections.

### Recommendation

⚠️ **DEFER** - Minimal expected benefit. Only implement if:
1. Port listing fix insufficient
2. Profiling shows handler goroutines as new bottleneck
3. Load testing determines safe MaxHandlers value

---

## 5. Tailscale Version Upgrade ❌ NO IMPROVEMENTS

### Current Version

**tsnsrv**: `tailscale.com v1.86.5` (from `go.mod`)

### Latest Versions

- **v1.86.5** → **v1.88.3** (Sep 25, 2025)
- Intermediate releases: v1.86.2, v1.88.0, v1.88.1

### Changelog Review

**Performance-related changes**: NONE

Changes between v1.86.5 and v1.88.3 focused on:
- Bug fixes (macOS firewall, Taildrive, control plane timeouts)
- Feature additions (`autogroup:self`, Devices API updates)
- Platform-specific fixes (iOS UI, OpenBSD startup)
- DERP server IP updates

**Notable Absences**:
- No portlist optimizations
- No netmon improvements
- No CPU usage fixes
- No goroutine management changes

### Recommendation

❌ **NO BENEFIT** - Upgrading to v1.88.3 will not address CPU scaling issues. Continue with v1.86.5 unless other bugs require upgrade.

---

## Implementation Priority

Based on research, recommended implementation order:

### Phase 1: IMMEDIATE (1-2 days)

1. ✅ **Disable Port Listing** (task-9.2)
   - Set `TS_DEBUG_DISABLE_PORTLIST=true`
   - Test on cloud host (14 services)
   - Profile and validate ~50% CPU reduction
   - Deploy to storage if successful

**Expected Result**: 113% → ~56% CPU usage

### Phase 2: MONITOR (after Phase 1)

2. ⏸️ **Evaluate Remaining Bottlenecks**
   - Re-profile with port listing disabled
   - Check if netmon becomes new primary bottleneck
   - Assess if additional optimizations needed

### Phase 3: UPSTREAM (long-term)

3. 📮 **Feature Requests**
   - File Tailscale issue requesting netmon throttling API
   - Share profiling data and use case
   - Monitor for upstream improvements

### ❌ NOT RECOMMENDED

- WireGuard worker configuration (not feasible)
- HTTP/2 handler limits (minimal benefit)
- Tailscale version upgrade (no relevant improvements)

---

## Code Implementation Example

### Recommended: Disable Port Listing

**File**: `cli.go`
**Location**: Line 657 (tsnet.Server initialization)

**Before**:
```go
func (s *ValidTailnetSrv) Run(ctx context.Context) error {
    srv := &tsnet.Server{
        Hostname:   s.Name,
        Dir:        s.StateDir,
        Logf:       logger.Discard,
        Ephemeral:  s.Ephemeral,
        ControlURL: os.Getenv("TS_URL"),
    }
    // ...
```

**After**:
```go
func (s *ValidTailnetSrv) Run(ctx context.Context) error {
    // Disable port listing to reduce CPU usage by ~50%
    // See: https://github.com/tailscale/tailscale/issues/10430
    os.Setenv("TS_DEBUG_DISABLE_PORTLIST", "true")

    srv := &tsnet.Server{
        Hostname:   s.Name,
        Dir:        s.StateDir,
        Logf:       logger.Discard,
        Ephemeral:  s.Ephemeral,
        ControlURL: os.Getenv("TS_URL"),
    }
    // ...
```

**Testing**:
1. Apply change locally
2. Build: `go build ./cmd/tsnsrv`
3. Test on cloud host with 14 services
4. Collect CPU profile before/after
5. Verify functionality (all services accessible)
6. Deploy to storage host if successful

---

## Alternative: NixOS Module Configuration

If implementing at systemd level instead:

**File**: `nixos/default.nix`

```nix
systemd.services."tsnsrv-${name}" = {
  # ... existing config ...
  environment = {
    TS_DEBUG_DISABLE_PORTLIST = "true";
    # ... other env vars ...
  };
};
```

This approach sets the env var at the service level rather than in code.

---

## Risk Assessment

### TS_DEBUG_DISABLE_PORTLIST

**Risks**:
- **Stability**: LOW - Environment variable is simple on/off flag
- **Functionality**: LOW - Port listing only used for diagnostics (not core functionality)
- **Reversibility**: LOW - Simply unset env var to restore
- **Future Compatibility**: MEDIUM - Debug env vars may change, but issue #10430 suggests stable workaround

**Mitigation**:
- Monitor Tailscale issue #10430 for official fixes
- Test thoroughly before production deployment
- Document env var usage for future maintainers
- Consider upstreaming when official API available

### Netmon/WireGuard Changes

**Risks**: NOT APPLICABLE (no viable implementation)

---

## Success Criteria

### Minimum Viable Outcome (Phase 1)

- ✅ Port listing disabled via environment variable
- ✅ CPU usage reduced from 113% to <60% on storage (57 services)
- ✅ All services remain functional and accessible
- ✅ No increase in memory usage or latency
- ✅ Profiling shows port listing overhead <5% (down from 48.85%)

### Stretch Goal

- ✅ CPU approaches linear scaling (~39% for 57 services)
- ✅ Matches or beats separate-process performance (40% for 57 services)

### Documentation

- ✅ Updated `docs/tsnsrv-pprof-analysis.md` with optimization results
- ✅ Created `docs/tsnsrv-optimization-research.md` (this document)
- ✅ NixOS module documentation includes performance configuration
- ✅ README mentions recommended settings for multi-service deployments

---

## References

- **Tailscale Issue #10430**: portlist: high CPU usage on otherwise idle system
  - https://github.com/tailscale/tailscale/issues/10430
- **Tailscale tsnet Package**: https://pkg.go.dev/tailscale.com/tsnet
- **Tailscale Source (tsnet.go)**: https://github.com/tailscale/tailscale/blob/main/tsnet/tsnet.go
- **Go HTTP/2 Package**: https://pkg.go.dev/golang.org/x/net/http2
- **tsnsrv Profiling Analysis**: `docs/tsnsrv-pprof-analysis.md`
- **tsnsrv Performance Investigation**: `docs/tsnsrv-performance-investigation.md`

---

## Conclusion

Research identified **one high-impact, low-risk optimization**: disabling Tailscale port listing via `TS_DEBUG_DISABLE_PORTLIST=true`. This single change is expected to reduce CPU usage by ~50% (from 113% to ~56% for 57 services).

Other potential optimizations (netmon throttling, WireGuard worker limits, HTTP connection limits) lack exposed configuration APIs and would require:
- Forking and patching Tailscale/wireguard-go
- Upstream contributions with uncertain timelines
- Significant implementation effort with high risk

**Recommendation**: Proceed with port listing optimization (task-9.2) as highest priority. Re-evaluate remaining bottlenecks after profiling the optimized system. Consider upstream feature requests for netmon throttling if additional improvements needed.

---

**Next Steps**: See task-9.2 for implementation plan.
