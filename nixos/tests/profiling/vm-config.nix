# NixOS configuration for profiling VM
# This creates a VM that can be used to collect profiling data
{
  pkgs,
  nixosModule,
  serviceCount ? 10,
}: let
  stunPort = 3478;
  pprofPort = 9099;

  # Generate service configurations for profiling
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
        tags = pkgs.lib.optional (n <= 10) "tag:profiling";
      };
    })
    serviceNumbers);
in
  pkgs.nixos ({
    config,
    lib,
    ...
  }: {
    imports = [nixosModule];

    # Minimal system configuration for VM
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };

    # Packages needed for profiling
    environment.systemPackages = with pkgs; [
      headscale
      tailscale
      curl
      jq
    ];

    # Headscale setup
    services.headscale = {
      enable = true;
      settings = {
        server_url = "http://127.0.0.1:8080";
        listen_addr = "127.0.0.1:8080";
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

    # tsnsrv configuration
    services.tsnsrv = {
      enable = true;
      defaults = {
        loginServerUrl = config.services.headscale.settings.server_url;
        authKeyPath = "/run/ts-authkey";
        urlParts.host = "127.0.0.1";
        timeout = "10s";
        listenAddr = ":80";
        prometheusAddr = ":${toString pprofPort}";
        tsnetVerbose = false;
      };

      services = generateServices serviceCount;
    };

    # Setup script to initialize Headscale and create auth key
    systemd.services.profiling-setup = {
      description = "Setup profiling environment";
      after = ["headscale.service" "tailscaled.service"];
      wants = ["headscale.service" "tailscaled.service"];
      before = ["tsnsrv-all.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Wait for headscale to be ready
        for i in {1..30}; do
          if ${pkgs.headscale}/bin/headscale users list >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        # Create user and auth key
        ${pkgs.headscale}/bin/headscale users create machine || true
        ${pkgs.headscale}/bin/headscale preauthkeys create --reusable -e 24h -u machine > /run/ts-authkey

        # Connect tailscale
        ${pkgs.tailscale}/bin/tailscale up \
          --login-server=${config.services.headscale.settings.server_url} \
          --auth-key="$(cat /run/ts-authkey)"
      '';
    };

    systemd.services.tsnsrv-all = {
      enableStrictShellChecks = true;
      unitConfig.ConditionPathExists = "/run/ts-authkey";
      after = ["profiling-setup.service"];
      wants = ["profiling-setup.service"];
    };

    # Firewall configuration
    networking.firewall.enable = false; # Disable for easier VM access

    # VM configuration
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      # Forward pprof port to host
      forwardPorts = [
        {
          from = "host";
          host.port = pprofPort;
          guest.port = pprofPort;
        }
      ];
    };

    # Minimal networking
    networking.useDHCP = false;
    networking.interfaces.eth0.useDHCP = true;

    services.getty.autologinUser = "root";
    users.users.root.password = "";

    system.stateVersion = "24.05";
  })
