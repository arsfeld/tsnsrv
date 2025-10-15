# Quick Start Guide - Performance Profiling

## What's Been Set Up

The tsnsrv codebase now includes pprof profiling support and automated tools for investigating the CPU scaling issue:

1. **Code Changes**: Added pprof HTTP endpoints to the prometheus server (cli.go)
2. **Test Configurations**: Generated configs for 10, 20, 30, 40, 50 services
3. **Collection Script**: `collect_profiles.sh` - automates profile collection
4. **Analysis Script**: `analyze_profiles.sh` - analyzes collected profiles
5. **Documentation**: Complete guide in `README.md`

## Prerequisites

To collect profiles, you need:

1. **Tailscale Auth Key**: An auth key with permission to create ephemeral nodes
   - Generate at: https://login.tailscale.com/admin/settings/keys
   - Or use an OAuth client secret if you have one
   - Required permissions: Create ephemeral devices
   - Recommended: Create a tagged key specifically for profiling

2. **System Resources**:
   - At least 4GB RAM (for running 50 services)
   - CPU with multiple cores for realistic testing

## Quick Start (3 Steps)

### Step 1: Set Auth Key

```bash
# Option A: Environment variable (recommended)
export TS_AUTHKEY="tskey-auth-..."

# Option B: Write to file and update configs
echo "tskey-auth-..." > /tmp/tsnsrv-authkey.txt
# Then edit configs to add: authkeyPath: "/tmp/tsnsrv-authkey.txt"
```

### Step 2: Collect Profiles

```bash
cd profiling
./collect_profiles.sh
```

This will:
- Build tsnsrv
- Run each configuration (10, 20, 30, 40, 50 services)
- Collect all profile types (CPU, heap, goroutine, mutex, etc.)
- Save results to `results/<count>_services/`

**Estimated time**: ~30 minutes (5 configurations × 5-6 minutes each)

### Step 3: Analyze Results

```bash
./analyze_profiles.sh
```

This generates:
- Console output with key findings
- Detailed reports in `analysis/`
- Goroutine scaling metrics
- CPU hotspot comparisons

## What to Look For

The analysis will help identify:

1. **Goroutine Explosion**: Does goroutine count scale linearly or super-linearly?
2. **CPU Hotspots**: Which functions consume most CPU? Do they scale poorly?
3. **Lock Contention**: Are services competing for shared resources?
4. **Memory Pressure**: Is GC overhead increasing disproportionately?

## Expected Timeline

- **Setup**: 5 minutes (already done!)
- **Data Collection**: 30 minutes (requires auth key)
- **Analysis**: 10 minutes (automated)
- **Investigation**: 1-2 hours (manual analysis of findings)
- **Solution Design**: 2-4 hours (depends on root cause)

## Troubleshooting

### "TS_AUTHKEY not set"

Set the environment variable or add `authkeyPath` to config files.

### "could not connect to tailnet"

- Check auth key has correct permissions
- Verify you're not hitting device limits on your Tailscale account
- Check network connectivity

### "profiles are empty"

- Ensure services had time to warm up (30s default)
- Check if tsnsrv process is actually running
- Look at `results/<count>_services/tsnsrv.log` for errors

### "OOM or CPU saturation"

- Reduce service counts being tested
- Increase system resources
- Test on a more powerful machine

## Next Steps After Analysis

Once you've identified the root cause:

1. **Document findings** in a new file: `profiling/FINDINGS.md`
2. **Propose solutions** with estimated impact
3. **Implement fixes** following the CLAUDE.md guidelines
4. **Re-run profiling** to validate improvements
5. **Update documentation** with performance characteristics

## Manual Analysis Commands

If you want to dig deeper into specific profiles:

```bash
# Interactive CPU analysis
go tool pprof -http=:8080 ../tsnsrv results/50_services/cpu.prof

# Compare 10 vs 50 services
go tool pprof -base=results/10_services/cpu.prof results/50_services/cpu.prof

# Generate flame graph
go tool pprof -svg ../tsnsrv results/50_services/cpu.prof > cpu_flame.svg

# List source code for specific function
go tool pprof -list=functionName ../tsnsrv results/50_services/cpu.prof
```

## Getting Help

- See full documentation: `README.md`
- Check task details: `../backlog/tasks/task-5*.md`
- Review existing findings: `../docs/multi-service-performance.md`
