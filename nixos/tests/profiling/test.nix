{
  pkgs,
  nixos-lib,
  nixosModule,
  # Number of services to run (parameterized for different profiling runs)
  serviceCount ? 10,
}: let
  stunPort = 3478;
  pprofPort = 9099;

  # Generate service configurations
  # We create dummy services that proxy to non-existent upstreams
  # since we're only profiling the tsnsrv overhead, not actual traffic
  generateServices = count: let
    serviceNumbers = pkgs.lib.range 1 count;
  in
    pkgs.lib.listToAttrs (map (n: {
      name = "service-${toString n}";
      value = {
        urlParts = {
          host = "127.0.0.1";
          port = 8000 + n; # Dummy ports, no actual services running
        };
        plaintext = true;
        # Tag some services to test different configurations
        tags = pkgs.lib.optional (n <= 10) "tag:profiling";
      };
    })
    serviceNumbers);
in
  nixos-lib.runTest {
    name = "profiling-${toString serviceCount}-services";
    hostPkgs = pkgs;

    defaults.services.tsnsrv.enable = true;

    nodes.machine = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [
        nixosModule
      ];

      environment.systemPackages = [
        pkgs.headscale
        pkgs.tailscale
        pkgs.curl
        pkgs.jq
        (pkgs.writeShellApplication {
          name = "tailscale-up-for-tests";
          text = ''
            tailscale up \
              --login-server=${config.services.headscale.settings.server_url} \
              --auth-key="$(cat /run/ts-authkey)"
          '';
        })
      ];

      virtualisation.cores = 4;
      virtualisation.memorySize = 4096; # More memory for profiling

      # Headscale setup for Tailscale networking
      services.headscale = {
        enable = true;
        settings = {
          ip_prefixes = ["100.64.0.0/10"];
          dns.magic_dns = false;
          dns.override_local_dns = false;
          derp.server = {
            enabled = true;
            region_id = 999;
            stun_listen_addr = "0.0.0.0:${toString stunPort}";
          };
        };
      };

      services.tailscale.enable = true;
      systemd.services.tailscaled.serviceConfig.Environment = ["TS_NO_LOGS_NO_SUPPORT=true"];

      networking.firewall = {
        allowedTCPPorts = [80 443 pprofPort];
        allowedUDPPorts = [stunPort];
      };

      # tsnsrv configuration with generated services
      services.tsnsrv = {
        prometheusAddr = ":${toString pprofPort}"; # Top-level pprof endpoint

        defaults = {
          loginServerUrl = config.services.headscale.settings.server_url;
          authKeyPath = "/run/ts-authkey";
          urlParts.host = "127.0.0.1";
          timeout = "10s";
          listenAddr = ":80";
          tsnetVerbose = false; # Reduce log noise
        };

        services = generateServices serviceCount;
      };

      systemd.services.tsnsrv-all = {
        enableStrictShellChecks = true;
        unitConfig.ConditionPathExists = config.services.tsnsrv.defaults.authKeyPath;
      };
    };

    testScript = ''
      import time
      import json

      SERVICE_COUNT = ${toString serviceCount}
      WARMUP_SECONDS = 60
      CPU_PROFILE_SECONDS = 30
      PPROF_ADDR = "localhost:${toString pprofPort}"

      machine.start()

      print(f"=== Profiling Test: {SERVICE_COUNT} Services ===\n")

      # Wait for services to be ready
      machine.wait_for_unit("tailscaled.service", timeout=30)
      machine.wait_for_unit("headscale.service", timeout=30)

      # Setup Tailscale
      machine.wait_until_succeeds("headscale users list", timeout=90)
      machine.succeed("headscale users create machine")
      machine.succeed("headscale preauthkeys create --reusable -e 24h -u 1 > /run/ts-authkey")
      machine.succeed("tailscale-up-for-tests", timeout=30)

      # Start the multi-service instance
      machine.systemctl("start tsnsrv-all")
      machine.wait_for_unit("tsnsrv-all", timeout=30)
      print("✓ tsnsrv-all service started")

      def wait_for_tsnsrv_registered(name):
          """Poll until tsnsrv appears in the list of hosts, then return its IP."""
          for _ in range(60):
              output = json.loads(machine.succeed("headscale nodes list -o json-line"))
              entry = [elt["ip_addresses"][0] for elt in output if elt["given_name"] == name]
              if len(entry) == 1:
                  return entry[0]
              time.sleep(1)
          raise Exception(f"Service {name} did not register within timeout")

      # Wait for first few services to register (as a health check)
      print("Waiting for services to register with Headscale...")
      for i in range(1, min(6, SERVICE_COUNT + 1)):
          service_name = f"service-{i}"
          service_ip = wait_for_tsnsrv_registered(service_name)
          print(f"✓ {service_name} registered with IP {service_ip}")

      # Wait for pprof endpoint to be available
      print("Waiting for pprof endpoint to be available...")
      # First, check what's listening on port 9099
      print("Checking what's listening on ports...")
      machine.succeed("ss -tlnp | grep 9099 || echo 'Nothing on 9099'")
      machine.succeed("ss -tlnp | grep tsnsrv || echo 'No tsnsrv listening'")
      # Wait a bit longer for tsnsrv to fully initialize
      time.sleep(10)
      machine.succeed("ss -tlnp | grep 9099 || echo 'Still nothing on 9099'")
      machine.wait_until_succeeds(f"curl -f http://{PPROF_ADDR}/debug/pprof/", timeout=60)
      print("✓ pprof endpoint available")

      # Warmup period
      print(f"\nWarming up for {WARMUP_SECONDS} seconds...")
      time.sleep(WARMUP_SECONDS)
      print("✓ Warmup complete")

      # Create results directory in VM
      results_dir = f"/tmp/profiling_results/{SERVICE_COUNT}_services"
      machine.succeed(f"mkdir -p {results_dir}")

      print("\nCollecting profiles...")

      # CPU profile (takes CPU_PROFILE_SECONDS)
      print(f"  - CPU profile ({CPU_PROFILE_SECONDS}s)...")
      machine.succeed(
          f"curl -s 'http://{PPROF_ADDR}/debug/pprof/profile?seconds={CPU_PROFILE_SECONDS}' "
          f"> {results_dir}/cpu.prof"
      )

      # Heap profile
      print("  - Heap profile...")
      machine.succeed(f"curl -s 'http://{PPROF_ADDR}/debug/pprof/heap' > {results_dir}/heap.prof")

      # Goroutine profile
      print("  - Goroutine profile...")
      machine.succeed(f"curl -s 'http://{PPROF_ADDR}/debug/pprof/goroutine' > {results_dir}/goroutine.prof")

      # Allocations profile
      print("  - Allocations profile...")
      machine.succeed(f"curl -s 'http://{PPROF_ADDR}/debug/pprof/allocs' > {results_dir}/allocs.prof")

      # Mutex profile
      print("  - Mutex profile...")
      machine.succeed(f"curl -s 'http://{PPROF_ADDR}/debug/pprof/mutex' > {results_dir}/mutex.prof")

      # Block profile
      print("  - Block profile...")
      machine.succeed(f"curl -s 'http://{PPROF_ADDR}/debug/pprof/block' > {results_dir}/block.prof")

      # Goroutine count (human readable)
      print("  - Goroutine count...")
      machine.succeed(
          f"curl -s 'http://{PPROF_ADDR}/debug/pprof/goroutine?debug=1' 2>/dev/null | "
          f"head -1 > {results_dir}/goroutine_count.txt"
      )

      # Process stats
      print("  - Process statistics...")
      tsnsrv_pid = machine.succeed("pgrep -f 'tsnsrv.*-config'").strip()
      machine.succeed(
          f"ps -p {tsnsrv_pid} -o pid,ppid,pcpu,pmem,vsz,rss,etime,comm > {results_dir}/ps_stats.txt"
      )

      print("\n✓ All profiles collected")

      # List collected files with sizes
      print("\nCollected profiles:")
      file_list = machine.succeed(f"ls -lh {results_dir}").strip()
      print(file_list)

      # Store the results directory path for extraction
      # Note: In actual usage, these files would need to be copied out of the VM
      # For now, we document where they are located
      print(f"\nProfiles are stored in VM at: {results_dir}")
      print("To extract profiles, use: nix-store --export or copy from VM")

      print("\n✅ Profiling test complete!")
    '';
  }
