{
  pkgs,
  nixos-lib,
  nixosModule,
}: let
  stunPort = 3478;
in
  nixos-lib.runTest {
    name = "systemd";
    hostPkgs = pkgs;

    defaults.services.tsnsrv.enable = true;
    defaults.services.tsnsrv.defaults.tsnetVerbose = true;

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
      virtualisation.memorySize = 1024;
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
        allowedTCPPorts = [80 443];
        allowedUDPPorts = [stunPort];
      };

      services.static-web-server = {
        enable = true;
        listen = "127.0.0.1:3000";
        root = pkgs.writeTextDir "index.html" "It works!";
      };
      services.tsnsrv = {
        defaults.urlParts.host = "127.0.0.1";
        defaults.loginServerUrl = config.services.headscale.settings.server_url;
        defaults.authKeyPath = "/run/ts-authkey";
        services.basic = {
          timeout = "10s";
          listenAddr = ":80";
          plaintext = true; # HTTPS requires certs
          toURL = "http://127.0.0.1:3000";
        };
        services.urlparts = {
          timeout = "10s";
          listenAddr = ":80";
          plaintext = true; # HTTPS requires certs
          urlParts.port = 3000;
        };
      };
      systemd.services.tsnsrv-all = {
        enableStrictShellChecks = true;
        unitConfig.ConditionPathExists = config.services.tsnsrv.defaults.authKeyPath;
      };
    };

    testScript = ''
      import time
      import json

      machine.start()
      machine.wait_for_unit("tailscaled.service", timeout=30)
      machine.wait_for_unit("headscale.service", timeout=30)
      machine.wait_until_succeeds("headscale users list", timeout=90)
      machine.succeed("headscale users create machine")
      machine.succeed("headscale preauthkeys create --reusable -e 24h -u 1 > /run/ts-authkey")
      machine.succeed("tailscale-up-for-tests", timeout=30)

      def wait_for_tsnsrv_registered(name):
          """Poll until tsnsrv appears in the list of hosts, then return its IP."""
          for _ in range(60):
              output = json.loads(machine.succeed("headscale nodes list -o json-line"))
              entry = [elt["ip_addresses"][0] for elt in output if elt["given_name"] == name]
              if len(entry) == 1:
                  return entry[0]
              time.sleep(1)
          raise Exception(f"Service {name} did not register within timeout")

      # Start the single multi-service tsnsrv instance
      machine.wait_until_succeeds("headscale nodes list -o json-line")
      machine.systemctl("start tsnsrv-all")
      machine.wait_for_unit("tsnsrv-all", timeout=30)
      print("✓ tsnsrv-all service started")

      # Wait for both services to register
      basic_ip = wait_for_tsnsrv_registered("basic")
      print(f"✓ basic service registered with IP {basic_ip}")

      urlparts_ip = wait_for_tsnsrv_registered("urlparts")
      print(f"✓ urlparts service registered with IP {urlparts_ip}")

      # Test connectivity to both services
      machine.wait_until_succeeds(f"tailscale ping {basic_ip}", timeout=30)
      print("✓ basic service is pingable")

      machine.wait_until_succeeds(f"tailscale ping {urlparts_ip}", timeout=30)
      print("✓ urlparts service is pingable")

      # Verify content from both services
      basic_output = machine.succeed(f"curl -f http://{basic_ip}")
      assert "It works!" in basic_output, f"Basic service returned unexpected content: {basic_output}"
      print("✓ basic service content verified")

      urlparts_output = machine.succeed(f"curl -f http://{urlparts_ip}")
      assert "It works!" in urlparts_output, f"Urlparts service returned unexpected content: {urlparts_output}"
      print("✓ urlparts service content verified")

      print("\n✅ All systemd tests passed!")
    '';
  }
