{
  pkgs,
  nixos-lib,
  nixosModule,
}: let
  stunPort = 3478;
in
  nixos-lib.runTest {
    name = "separate-processes-mode";
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
      virtualisation.memorySize = 2048;

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
        allowedTCPPorts = [80 443 9099 9100 9101];
        allowedUDPPorts = [stunPort];
      };

      # Backend services to proxy to
      services.static-web-server = {
        enable = true;
        listen = "127.0.0.1:3000";
        root = pkgs.writeTextDir "index.html" "Service 1 content!";
      };

      systemd.services.test-service-2 = {
        description = "Test backend service 2";
        wantedBy = ["multi-user.target"];
        script = ''
          ${pkgs.python3}/bin/python -m http.server 3001 --bind 127.0.0.1 --directory ${
            pkgs.writeTextDir "index.html" "Service 2 content!"
          }
        '';
      };

      systemd.services.test-service-3 = {
        description = "Test backend service 3";
        wantedBy = ["multi-user.target"];
        script = ''
          ${pkgs.python3}/bin/python -m http.server 3002 --bind 127.0.0.1 --directory ${
            pkgs.writeTextDir "index.html" "Service 3 content!"
          }
        '';
      };

      # tsnsrv configuration with separate processes enabled
      services.tsnsrv = {
        separateProcesses = true;
        prometheusAddr = ":9099";

        defaults = {
          loginServerUrl = config.services.headscale.settings.server_url;
          authKeyPath = "/run/ts-authkey";
          urlParts.host = "127.0.0.1";
          timeout = "10s";
          listenAddr = ":80";
        };

        services = {
          service-1 = {
            urlParts.port = 3000;
            plaintext = true;
          };

          service-2 = {
            urlParts.port = 3001;
            ephemeral = true;
            plaintext = true;
          };

          service-3 = {
            urlParts.port = 3002;
            tags = ["tag:test"];
            plaintext = true;
          };
        };
      };

      # Each service should have its own systemd unit
      systemd.services.tsnsrv-service-1 = {
        enableStrictShellChecks = true;
        unitConfig.ConditionPathExists = config.services.tsnsrv.defaults.authKeyPath;
      };
      systemd.services.tsnsrv-service-2 = {
        enableStrictShellChecks = true;
        unitConfig.ConditionPathExists = config.services.tsnsrv.defaults.authKeyPath;
      };
      systemd.services.tsnsrv-service-3 = {
        enableStrictShellChecks = true;
        unitConfig.ConditionPathExists = config.services.tsnsrv.defaults.authKeyPath;
      };
    };

    testScript = ''
      import time
      import json

      machine.start()

      # Wait for services to be ready
      machine.wait_for_unit("tailscaled.service", timeout=30)
      machine.wait_for_unit("headscale.service", timeout=30)
      machine.wait_for_unit("test-service-2.service", timeout=30)
      machine.wait_for_unit("test-service-3.service", timeout=30)

      # Setup Tailscale
      machine.wait_until_succeeds("headscale users list", timeout=90)
      machine.succeed("headscale users create machine")
      machine.succeed("headscale preauthkeys create --reusable -e 24h -u 1 > /run/ts-authkey")
      machine.succeed("tailscale-up-for-tests", timeout=30)

      # Start the individual service instances
      machine.systemctl("start tsnsrv-service-1")
      machine.systemctl("start tsnsrv-service-2")
      machine.systemctl("start tsnsrv-service-3")
      machine.wait_for_unit("tsnsrv-service-1", timeout=30)
      machine.wait_for_unit("tsnsrv-service-2", timeout=30)
      machine.wait_for_unit("tsnsrv-service-3", timeout=30)
      print("✓ All tsnsrv service units started")

      # Verify that individual systemd services exist (NOT tsnsrv-all)
      print("Verifying separate-process mode creates individual systemd units...")
      machine.succeed("systemctl list-units | grep -q 'tsnsrv-service-1.service'")
      machine.succeed("systemctl list-units | grep -q 'tsnsrv-service-2.service'")
      machine.succeed("systemctl list-units | grep -q 'tsnsrv-service-3.service'")
      machine.fail("systemctl list-units | grep -q 'tsnsrv-all.service'")
      print("✓ Individual systemd services confirmed")

      # Verify unique prometheus ports are assigned
      print("Verifying unique Prometheus ports...")
      machine.succeed("curl -f http://localhost:9099/metrics")
      machine.succeed("curl -f http://localhost:9100/metrics")
      machine.succeed("curl -f http://localhost:9101/metrics")
      print("✓ Unique Prometheus ports confirmed")

      def wait_for_tsnsrv_registered(name):
          """Poll until tsnsrv appears in the list of hosts, then return its IP."""
          for _ in range(60):
              output = json.loads(machine.succeed("headscale nodes list -o json-line"))
              entry = [elt["ip_addresses"][0] for elt in output if elt["given_name"] == name]
              if len(entry) == 1:
                  return entry[0]
              time.sleep(1)
          raise Exception(f"Service {name} did not register within timeout")

      # Wait for all three services to register
      print("Waiting for all services to register with Tailscale...")
      service1_ip = wait_for_tsnsrv_registered("service-1")
      service2_ip = wait_for_tsnsrv_registered("service-2")
      service3_ip = wait_for_tsnsrv_registered("service-3")
      print(f"✓ service-1 registered with IP {service1_ip}")
      print(f"✓ service-2 registered with IP {service2_ip}")
      print(f"✓ service-3 registered with IP {service3_ip}")

      # Test connectivity to all services
      print("Testing connectivity to all services...")
      machine.wait_until_succeeds(f"tailscale ping {service1_ip}", timeout=30)
      machine.wait_until_succeeds(f"tailscale ping {service2_ip}", timeout=30)
      machine.wait_until_succeeds(f"tailscale ping {service3_ip}", timeout=30)
      print("✓ All services are pingable")

      # Verify content from each service
      print("Verifying service content...")
      output1 = machine.succeed(f"curl -f http://{service1_ip}/")
      assert "Service 1 content!" in output1, f"Service 1 returned unexpected content: {output1}"
      print("✓ Service 1 content verified")

      output2 = machine.succeed(f"curl -f http://{service2_ip}/")
      assert "Service 2 content!" in output2, f"Service 2 returned unexpected content: {output2}"
      print("✓ Service 2 content verified")

      output3 = machine.succeed(f"curl -f http://{service3_ip}/")
      assert "Service 3 content!" in output3, f"Service 3 returned unexpected content: {output3}"
      print("✓ Service 3 content verified")

      print("\n✅ All separate-processes mode tests passed!")
    '';
  }
