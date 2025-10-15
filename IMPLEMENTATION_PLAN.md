# Implementation Plan: Multi-Service Support

## Current Architecture Summary

- Each tsnsrv instance runs one service with one `tsnet.Server`
- CLI parsing creates one `ValidTailnetSrv` from args
- `Run()` method creates tsnet.Server, sets up listeners, serves requests
- Metrics are global (not labeled by service)
- Each service requires separate process invocation

## Design Approach

To support multiple services in one process, we'll:
1. Create a configuration file format (YAML/TOML) for defining multiple services
2. Keep CLI mode for single-service use (backward compatibility)
3. Add a multi-service orchestrator that manages multiple ValidTailnetSrv instances
4. Label all metrics with service name for proper separation
5. Each service gets its own tsnet.Server (required for different hostnames)

## Stage 1: Configuration Format and Parsing
**Goal**: Define and implement config file parsing for multiple services
**Success Criteria**:
- Config file format defined (YAML) ✓
- Parser reads config and creates multiple ValidTailnetSrv instances ✓
- Validation errors are clear and actionable ✓
- Backward compatibility: CLI mode still works for single service ✓
**Tests**:
- Unit tests for config parsing ✓
- Validation tests for invalid configs ✓
- Test that CLI mode still works ✓
**Status**: Complete

**Completed Work**:
- Created config.go with Config and ServiceConfig structs
- Implemented YAML parsing with validation
- Added TailnetSrvsFromArgs function supporting both CLI and config modes
- -config flag enables multi-service mode
- All tests pass, backward compatibility maintained

## Stage 2: Multi-Service Orchestrator
**Goal**: Create orchestrator to run multiple services concurrently
**Success Criteria**:
- Orchestrator starts multiple tsnet.Server instances ✓
- Each service runs independently with its own configuration ✓
- Error in one service doesn't crash others ✓
- Graceful shutdown of all services ✓
- All services can serve simultaneously ✓
**Tests**:
- Unit tests for orchestrator logic ✓
- Test error handling and isolation ✓
- Test context cancellation ✓
**Status**: Complete

**Completed Work**:
- Created orchestrator.go with Orchestrator struct
- Implements concurrent service execution with error handling
- Context cancellation propagates to all services
- ServiceError type for service-specific errors
- Updated main.go to use orchestrator
- Added example config file (config.example.yaml)
- All tests pass, backward compatibility maintained

## Stage 3: Metrics Labeling
**Goal**: Add service_name label to all Prometheus metrics
**Success Criteria**:
- All existing metrics include service_name label ✓
- Metrics are properly separated per service ✓
- No metric collisions between services ✓
- Backward compatible: single service mode works ✓
**Tests**:
- All existing tests pass ✓
- Build succeeds ✓
**Status**: Complete

**Completed Work**:
- Updated all metrics to use VectorCollectors with service_name label:
  - requestDurations: SummaryVec with service_name
  - responseStatusClasses: CounterVec with service_name + status_code_class
  - proxyErrors: CounterVec with service_name
  - authRequests: CounterVec with service_name + status
  - authDurations: SummaryVec with service_name
- Added serviceName field to proxyContext
- Updated all metric recording sites to include service_name
- Enhanced logging with service field for better debugging
- All tests pass, backward compatibility maintained

## Stage 4: NixOS Module Integration
**Goal**: Update NixOS module to support multi-service mode
**Success Criteria**:
- Module can generate config file from multiple service definitions
- Existing single-service configs still work
- Multi-service mode uses single systemd unit
- Documentation updated with examples
**Tests**:
- NixOS test for multi-service configuration
- Test backward compatibility with existing configs
- Verify resource usage improvements
**Status**: Not Started

## Stage 5: Documentation and Performance Validation
**Goal**: Complete documentation and measure improvements
**Success Criteria**:
- README updated with multi-service examples
- Config file format documented
- Performance comparison shows resource reduction
- Migration guide for existing deployments
**Tests**:
- Manual testing of examples
- Benchmark memory usage: N separate processes vs 1 multi-service
**Status**: Not Started

## Implementation Notes

### Config File Format (Draft)
```yaml
services:
  - name: service1
    upstream: http://localhost:8080
    funnel: true
    authURL: http://authelia:9091
    authCopyHeaders:
      Remote-User: ""
    prefixes:
      - /app1
  - name: service2
    upstream: http://localhost:8081
    funnel: true
    prefixes:
      - /app2
```

### Key Files to Modify
- `cli.go`: Add config file parsing
- `proxy.go`: Update metrics to include labels
- New file `orchestrator.go`: Multi-service runner
- `nixos/default.nix`: Update module for multi-service support

### Backward Compatibility Strategy
- CLI mode (current behavior) remains default
- New `-config` flag to enable multi-service mode
- Single-service config file is also supported
