{
  pkgs,
  nixos-lib,
  nixosModule,
}: let
  stunPort = 3478;
  # Test users credentials
  testUser = "testuser";
  testPassword = "testpassword123";
in
  nixos-lib.runTest {
    name = "authelia-integration";
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
        allowedTCPPorts = [80 443 9091];
        allowedUDPPorts = [stunPort];
      };

      # Backend service to proxy to
      services.static-web-server = {
        enable = true;
        listen = "127.0.0.1:3000";
        root = pkgs.writeTextDir "index.html" "Authenticated content!";
      };

      # Authelia configuration
      services.authelia.instances.main = {
        enable = true;
        secrets = {
          jwtSecretFile = pkgs.writeText "jwt-secret" "insecure_jwt_secret_for_testing";
          storageEncryptionKeyFile = pkgs.writeText "storage-key" "insecure_storage_key_for_testing";
        };
        settings = {
          theme = "light";
          log.level = "debug";

          server = {
            address = "tcp://127.0.0.1:9091";
          };

          # Use in-memory storage for testing
          storage.local.path = "/var/lib/authelia-main/db.sqlite3";

          # Authentication backend with file provider
          authentication_backend = {
            refresh_interval = "5m";
            file = {
              # Path to users database file
              path = pkgs.writeText "authelia-users.yml" ''
                users:
                  ${testUser}:
                    disabled: false
                    displayname: "Test User"
                    password: "$argon2id$v=19$m=65536,t=3,p=4$BpLfEqc85fbijsUMNx4fhA$ZykkLVc6JjqRSd0UR1tDTdvMfBEY0Y9zQQOaRj5WXX8"
                    email: testuser@example.com
                    groups:
                      - admins
                      - dev
              '';
            };
          };

          # Access control rules
          access_control = {
            default_policy = "deny";
            rules = [
              {
                domain = ["*"];
                policy = "one_factor";
              }
            ];
          };

          # Session configuration
          session = {
            cookies = [
              {
                domain = "example.com";
                authelia_url = "https://auth.example.com";
              }
            ];
            expiration = "1h";
            inactivity = "5m";
          };

          # Notifier configuration (required)
          notifier = {
            filesystem = {
              filename = "/var/lib/authelia-main/notification.txt";
            };
          };
        };
      };

      # tsnsrv configuration
      services.tsnsrv = {
        defaults.urlParts.host = "127.0.0.1";
        defaults.loginServerUrl = config.services.headscale.settings.server_url;
        defaults.authKeyPath = "/run/ts-authkey";

        services.authenticated = {
          timeout = "10s";
          listenAddr = ":80";
          plaintext = true;
          toURL = "http://127.0.0.1:3000";
          authURL = "http://127.0.0.1:9091";
          authPath = "/api/authz/forward-auth";
          authTimeout = "10s";
          authCopyHeaders = {
            "Remote-User" = "";
            "Remote-Groups" = "";
            "Remote-Email" = "";
          };
        };

        services.with-bypass = {
          timeout = "10s";
          listenAddr = ":80";
          plaintext = true;
          toURL = "http://127.0.0.1:3000";
          authURL = "http://127.0.0.1:9091";
          authPath = "/api/authz/forward-auth";
          authTimeout = "10s";
          authBypassForTailnet = true;
          authCopyHeaders = {
            "Remote-User" = "";
          };
        };
      };

      systemd.services.tsnsrv-all = {
        enableStrictShellChecks = true;
        unitConfig.ConditionPathExists = config.services.tsnsrv.defaults.authKeyPath;
        after = ["authelia-main.service"];
        wants = ["authelia-main.service"];
      };
    };

    testScript = ''
      import time
      import json

      machine.start()

      # Wait for services to be ready
      machine.wait_for_unit("tailscaled.service", timeout=30)
      machine.wait_for_unit("headscale.service", timeout=30)
      machine.wait_for_unit("authelia-main.service", timeout=30)
      machine.wait_for_unit("static-web-server.service", timeout=30)

      # Setup Tailscale
      machine.wait_until_succeeds("headscale users list", timeout=90)
      machine.succeed("headscale users create machine")
      machine.succeed("headscale preauthkeys create --reusable -e 24h -u 1 > /run/ts-authkey")
      machine.succeed("tailscale-up-for-tests", timeout=30)

      # Verify Authelia is responding
      machine.wait_until_succeeds("curl -f http://127.0.0.1:9091/api/health", timeout=30)
      print("✓ Authelia is healthy")

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
      machine.systemctl("start tsnsrv-all")
      machine.wait_for_unit("tsnsrv-all", timeout=30)
      print("✓ tsnsrv-all service started")

      # Wait for both services to register
      authenticated_ip = wait_for_tsnsrv_registered("authenticated")
      print(f"✓ authenticated service registered with IP {authenticated_ip}")

      bypass_ip = wait_for_tsnsrv_registered("with-bypass")
      print(f"✓ with-bypass service registered with IP {bypass_ip}")

      # Test connectivity
      machine.wait_until_succeeds(f"tailscale ping {authenticated_ip}", timeout=30)
      print("✓ authenticated service is pingable")

      machine.wait_until_succeeds(f"tailscale ping {bypass_ip}", timeout=30)
      print("✓ with-bypass service is pingable")

      # Test 1: Authenticated service - unauthenticated request should be denied
      print("Testing authenticated service without credentials (should be denied)...")
      machine.fail(f"curl -f http://{authenticated_ip}/")
      print("✓ Unauthenticated request correctly denied")

      # Test 2: Bypass service - request from Tailscale network should bypass auth
      print("Testing with-bypass service from Tailscale network (should bypass auth)...")
      output = machine.succeed(f"curl -f http://{bypass_ip}/")
      assert "Authenticated content!" in output, f"Expected content not found. Got: {output}"
      print("✓ Auth bypass for Tailscale users is working correctly")

      print("\n✅ All Authelia integration tests passed!")
    '';
  }
