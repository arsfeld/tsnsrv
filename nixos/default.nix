{flake}: {
  pkgs,
  config,
  lib,
  ...
}: let
  urlPartsSubmodule.options = with lib; {
    protocol = mkOption {
      description = "URL Scheme or protocol to use for reaching the upstream service.";
      type = types.str;
      default = "http";
    };

    host = mkOption {
      description = "Host where the upstream service can be reached.";
      type = types.str;
    };

    port = mkOption {
      description = "Port where the upstream service can be reached.";
      type = types.int;
    };
  };

  urlPartsSubmoduleWithDefaults.options = with lib; let
    inherit (config.services.tsnsrv) defaults;
  in {
    protocol = mkOption {
      description = "URL Scheme or protocol to use for reaching the upstream service.";
      type = types.str;
      default = defaults.urlParts.protocol;
      defaultText = lib.literalExpression "config.services.tsnsrv.defaults.urlParts.protocol";
    };

    host = mkOption {
      description = "Host where the upstream service can be reached.";
      type = types.str;
      default = defaults.urlParts.host;
      defaultText = lib.literalExpression "config.services.tsnsrv.defaults.urlParts.host";
    };

    port = mkOption {
      description = "Port where the upstream service can be reached.";
      type = types.port;
      default = defaults.urlParts.port;
      defaultText = lib.literalExpression "config.services.tsnsrv.defaults.urlParts.port";
    };
  };

  serviceSubmodule = with lib; let
    inherit (config.services.tsnsrv) defaults;
  in ({config, ...}: {
    options = {
      authKeyPath = mkOption {
        description = "Path to a file containing a tailscale auth key. Make this a secret";
        type = types.path;
        default = defaults.authKeyPath;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authKeyPath";
      };

      ephemeral = mkOption {
        description = "Delete the tailnet participant shortly after it goes offline";
        type = types.bool;
        default = defaults.ephemeral;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.ephemeral";
      };

      funnel = mkOption {
        description = "Serve HTTP as a funnel, meaning that it is available on the public internet.";
        type = types.bool;
        default = false;
      };

      insecureHTTPS = mkOption {
        description = "Disable TLS certificate validation for requests from upstream. Insecure.";
        type = types.bool;
        default = false;
      };

      listenAddr = mkOption {
        description = "Address to listen on";
        type = types.str;
        default = defaults.listenAddr;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.listenAddr";
      };

      loginServerUrl = lib.mkOption {
        description = "Login server URL to use. If unset, defaults to the official tailscale service.";
        default = defaults.loginServerUrl;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.loginServerUrl";
        type = with types; nullOr str;
      };

      package = mkOption {
        description = "Package to use for this tsnsrv service.";
        default = defaults.package;
        type = types.package;
      };

      plaintext = mkOption {
        description = "Whether to serve non-TLS-encrypted plaintext HTTP";
        type = types.bool;
        default = false;
      };

      certificateFile = mkOption {
        description = "Custom certificate file to use for TLS listening instead of Tailscale's builtin way";
        type = with types; nullOr path;
        default = defaults.certificateFile;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.certificateFile";
      };

      certificateKey = mkOption {
        description = "Custom key file to use for TLS listening instead of Tailscale's builtin way.";
        type = with types; nullOr path;
        default = defaults.certificateKey;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.certificateKey";
      };

      acmeHost = mkOption {
        description = "Populate certificateFile and certificateKey option from this certificate name from security.acme module.";
        type = with types; nullOr str;
        default = defaults.acmeHost;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.acmeHost";
      };

      upstreamUnixAddr = mkOption {
        description = "Connect only to the given UNIX Domain Socket";
        type = types.nullOr types.path;
        default = null;
      };

      prefixes = mkOption {
        description = "URL path prefixes to allow in forwarding. Acts as an allowlist but if no prefixes are set, all prefixes are allowed.";
        type = types.listOf (types.strMatching "^(/|tailnet:/|funnel:/).*");
        default = [];
        example = ["tailnet:/" "funnel:/.well-known/"];
      };

      stripPrefix = mkOption {
        description = "Strip matched prefix from request to upstream. Probably should be true when allowlisting multiple prefixes.";
        type = types.bool;
        default = true;
      };

      whoisTimeout = mkOption {
        description = "Maximum amount of time that a requestor lookup may take.";
        type = types.nullOr types.str;
        default = null;
      };

      suppressWhois = mkOption {
        description = "Disable passing requestor information to upstream service";
        type = types.bool;
        default = false;
      };

      upstreamHeaders = mkOption {
        description = "Headers to set on requests to upstream.";
        type = types.attrsOf types.str;
        default = {};
      };

      suppressTailnetDialer = mkOption {
        description = "Disable using the tsnet-provided dialer, which can sometimes cause issues hitting addresses outside the tailnet";
        type = types.bool;
        default = false;
      };

      readHeaderTimeout = mkOption {
        description = "";
        type = types.nullOr types.str;
        default = null;
      };

      urlParts = mkOption {
        description = "URL parts that make up an alternative to the toURL option.";
        type = types.nullOr (types.submodule urlPartsSubmoduleWithDefaults);
        default = null;
      };

      toURL = mkOption {
        description = "URL to forward HTTP requests to. Either this or the urlParts option must be set.";
        type = types.str;
        default = "${config.urlParts.protocol}://${config.urlParts.host}:${toString config.urlParts.port}";
        defaultText = lib.literalExpression "\${config.services.tsnsrv.<name>.urlParts.protocol}://\${config.services.tsnsrv.<name>.urlParts.host}:\${toString config.services.tsnsrv.<name>.urlParts.port}";
      };

      supplementalGroups = mkOption {
        description = "List of groups to run the service under (in addition to the 'tsnsrv' group)";
        type = types.listOf types.str;
        default = defaults.supplementalGroups;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.supplementalGroups";
      };

      tags = mkOption {
        description = "Tags for minting an auth key from an OAuth2 client. Must be prefixed with `tag:`";
        type = types.listOf (types.strMatching "^tag:.*");
        default = defaults.tags;
        example = ["tag:foo" "tag:bar"];
      };

      timeout = mkOption {
        description = "Maximum amount of time that authenticating to the tailscale API may take";
        type = with types; nullOr str;
        default = defaults.timeout;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.timeout";
      };

      tsnetVerbose = mkOption {
        description = "Whether to log verbosely from tsnet. Can be useful for seeing first-time authentication URLs.";
        type = types.bool;
        default = defaults.tsnetVerbose;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.tsnetVerbose";
      };

      upstreamAllowInsecureCiphers = mkOption {
        description = "Whether to allow the upstream to have only ciphersuites that don't offer Perfect Forward Secrecy. If a connection attempt to an upstream returns the error `remote error: tls: handshake failure`, try setting this to true.";
        type = types.bool;
        default = defaults.upstreamAllowInsecureCiphers;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.upstreamAllowInsecureCiphers";
      };

      authURL = mkOption {
        description = "Authorization service URL for forward auth (e.g., http://authelia:9091). If set, all requests will be validated against this service before being proxied.";
        type = with types; nullOr str;
        default = defaults.authURL;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authURL";
      };

      authPath = mkOption {
        description = "Authorization service endpoint path";
        type = types.str;
        default = defaults.authPath;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authPath";
      };

      authTimeout = mkOption {
        description = "Timeout for authorization requests";
        type = with types; nullOr str;
        default = defaults.authTimeout;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authTimeout";
      };

      authCopyHeaders = mkOption {
        description = "Headers to copy from auth response to upstream request";
        type = types.attrsOf types.str;
        default = defaults.authCopyHeaders;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authCopyHeaders";
      };

      authInsecureHTTPS = mkOption {
        description = "Disable TLS certificate validation for auth service";
        type = types.bool;
        default = defaults.authInsecureHTTPS;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authInsecureHTTPS";
      };

      authBypassForTailnet = mkOption {
        description = "Bypass forward auth for requests from Tailscale network (authenticated users)";
        type = types.bool;
        default = defaults.authBypassForTailnet;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authBypassForTailnet";
      };

      extraArgs = mkOption {
        description = "Extra arguments to pass to this tsnsrv process.";
        type = types.listOf types.str;
        default = [];
      };
    };
  });

  serviceArgs = {
    name,
    service,
  }: let
    readHeaderTimeout =
      if service.readHeaderTimeout == null
      then
        if service.funnel
        then "1s"
        else "0s"
      else service.readHeaderTimeout;
  in
    [
      "-name=${name}"
      "-ephemeral=${lib.boolToString service.ephemeral}"
      "-funnel=${lib.boolToString service.funnel}"
      "-plaintext=${lib.boolToString service.plaintext}"
      "-listenAddr=${service.listenAddr}"
      "-stripPrefix=${lib.boolToString service.stripPrefix}"
      "-insecureHTTPS=${lib.boolToString service.insecureHTTPS}"
      "-suppressTailnetDialer=${lib.boolToString service.suppressTailnetDialer}"
      "-readHeaderTimeout=${readHeaderTimeout}"
      "-tsnetVerbose=${lib.boolToString service.tsnetVerbose}"
      "-upstreamAllowInsecureCiphers=${lib.boolToString service.upstreamAllowInsecureCiphers}"
      "-authInsecureHTTPS=${lib.boolToString service.authInsecureHTTPS}"
      "-authBypassForTailnet=${lib.boolToString service.authBypassForTailnet}"
      "-authPath=${service.authPath}"
    ]
    ++ lib.optionals (service.authURL != null) ["-authURL=${service.authURL}"]
    ++ lib.optionals (service.authTimeout != null) ["-authTimeout=${service.authTimeout}"]
    ++ lib.optionals (service.whoisTimeout != null) ["-whoisTimeout" service.whoisTimeout]
    ++ lib.optionals (service.upstreamUnixAddr != null) ["-upstreamUnixAddr" service.upstreamUnixAddr]
    ++ lib.optionals (service.certificateFile != null && service.certificateKey != null) [
      "-certificateFile=${service.certificateFile}"
      "-keyFile=${service.certificateKey}"
    ]
    ++ lib.optionals (service.timeout != null) ["-timeout=${service.timeout}"]
    ++ map (t: "-tag=${t}") service.tags
    ++ map (p: "-prefix=${p}") service.prefixes
    ++ map (h: "-upstreamHeader=${h}") (lib.mapAttrsToList (name: service: "${name}: ${service}") service.upstreamHeaders)
    ++ map (h: "-authCopyHeader=${h}") (lib.mapAttrsToList (name: value: "${name}: ${value}") service.authCopyHeaders)
    ++ service.extraArgs
    ++ [service.toURL];

  # Function to convert a service configuration to YAML format
  # Takes additional parameters for runtime paths that need to be substituted
  serviceToYaml = {name, service, stateBaseDir ? null, authKeyPath ? null}: let
    # Helper to format headers for YAML
    formatHeaders = headers:
      lib.mapAttrs (k: v: v) headers;
  in {
    inherit name;
    upstream = service.toURL;

    # Optional fields - only include if set to non-default values
  } // lib.optionalAttrs (service.upstreamUnixAddr != null) {
    upstreamUnixAddr = service.upstreamUnixAddr;
  } // lib.optionalAttrs service.ephemeral {
    ephemeral = true;
  } // lib.optionalAttrs (service.tags != []) {
    tags = service.tags;
  } // lib.optionalAttrs service.funnel {
    funnel = true;
  } // lib.optionalAttrs (service.listenAddr != ":443") {
    listenAddr = service.listenAddr;
  } // lib.optionalAttrs service.plaintext {
    plaintext = true;
  } // lib.optionalAttrs (service.certificateFile != null && service.certificateKey != null) {
    certificateFile = service.certificateFile;
    keyFile = service.certificateKey;
  } // lib.optionalAttrs (service.prefixes != []) {
    prefixes = service.prefixes;
  } // lib.optionalAttrs (!service.stripPrefix) {
    stripPrefix = false;
  } // lib.optionalAttrs (service.upstreamHeaders != {}) {
    upstreamHeaders = formatHeaders service.upstreamHeaders;
  } // lib.optionalAttrs service.insecureHTTPS {
    insecureHTTPS = true;
  } // lib.optionalAttrs service.upstreamAllowInsecureCiphers {
    upstreamAllowInsecureCiphers = true;
  } // lib.optionalAttrs service.suppressWhois {
    suppressWhois = true;
  } // lib.optionalAttrs (service.whoisTimeout != null) {
    whoisTimeout = service.whoisTimeout;
  } // lib.optionalAttrs service.suppressTailnetDialer {
    suppressTailnetDialer = true;
  } // lib.optionalAttrs (service.authURL != null) {
    authURL = service.authURL;
  } // lib.optionalAttrs (service.authPath != "/api/authz/forward-auth") {
    authPath = service.authPath;
  } // lib.optionalAttrs (service.authTimeout != null && service.authTimeout != "5s") {
    authTimeout = service.authTimeout;
  } // lib.optionalAttrs (service.authCopyHeaders != {}) {
    authCopyHeaders = formatHeaders service.authCopyHeaders;
  } // lib.optionalAttrs service.authInsecureHTTPS {
    authInsecureHTTPS = true;
  } // lib.optionalAttrs service.authBypassForTailnet {
    authBypassForTailnet = true;
  } // lib.optionalAttrs (service.timeout != null) {
    timeout = service.timeout;
  } // lib.optionalAttrs (service.readHeaderTimeout != null) {
    readHeaderTimeout = service.readHeaderTimeout;
  } // lib.optionalAttrs service.tsnetVerbose {
    tsnetVerbose = true;
  } // lib.optionalAttrs (stateBaseDir != null) {
    # Each service gets its own subdirectory within the state directory
    stateDir = "${stateBaseDir}/${name}";
  } // lib.optionalAttrs (authKeyPath != null) {
    # All services share the same auth key path
    authkeyPath = authKeyPath;
  };

  # Generate YAML config for multi-service mode
  # This generates a template that will be expanded at runtime with systemd variables
  generateMultiServiceConfig = {services, stateBaseDir ? null, authKeyPath ? null, prometheusAddr ? ":9099"}: let
    # Convert services to list
    serviceNames = lib.attrNames services;

    servicesList = map (name: let
      service = services.${name};
      # Generate base service YAML
      serviceYaml = serviceToYaml {
        inherit name service stateBaseDir authKeyPath;
      };
    in
      serviceYaml
    ) serviceNames;
  in pkgs.writeText "tsnsrv-config.yaml" (
    lib.generators.toYAML {} (
      # prometheusAddr is now a top-level field
      {
        services = servicesList;
      } // lib.optionalAttrs (prometheusAddr != null) {
        prometheusAddr = prometheusAddr;
      }
    )
  );
in {
  options = with lib; {
    services.tsnsrv.enable = mkOption {
      description = "Enable tsnsrv";
      type = types.bool;
      default = false;
    };

    services.tsnsrv.defaults = {
      package = mkOption {
        description = "Package to run tsnsrv out of";
        default = flake.packages.${pkgs.stdenv.targetPlatform.system}.tsnsrv;
        type = types.package;
      };

      authKeyPath = lib.mkOption {
        description = "Path to a file containing a tailscale auth key. Make this a secret";
        type = types.path;
      };

      acmeHost = mkOption {
        description = "Populate certificateFile and certificateKey option from this certifcate name from security.acme module.";
        type = with types; nullOr str;
        default = null;
      };

      certificateFile = mkOption {
        description = "Custom certificate file to use for TLS listening instead of Tailscale's builtin way";
        type = with types; nullOr path;
        default = null;
      };

      certificateKey = mkOption {
        description = "Custom key file to use for TLS listening instead of Tailscale's builtin way.";
        type = with types; nullOr path;
        default = null;
      };

      ephemeral = mkOption {
        description = "Delete the tailnet participant shortly after it goes offline";
        type = types.bool;
        default = false;
      };

      listenAddr = mkOption {
        description = "Address to listen on";
        type = types.str;
        default = ":443";
      };

      loginServerUrl = lib.mkOption {
        description = "Login server URL to use. If unset, defaults to the official tailscale service.";
        default = null;
        type = with types; nullOr str;
      };

      supplementalGroups = mkOption {
        description = "List of groups to run the service under (in addition to the 'tsnsrv' group)";
        type = types.listOf types.str;
        default = [];
      };

      tags = mkOption {
        description = "Tags for minting an auth key from an OAuth2 client. Must be prefixed with `tag:`";
        type = types.listOf (types.strMatching "^tag:.*");
        default = [];
        example = ["tag:foo" "tag:bar"];
      };

      timeout = mkOption {
        description = "Maximum amount of time that authenticating to the tailscale API may take";
        type = with types; nullOr str;
        default = null;
      };

      tsnetVerbose = mkOption {
        description = "Whether to log verbosely from tsnet. Can be useful for seeing first-time authentication URLs.";
        type = types.bool;
        default = false;
      };

      upstreamAllowInsecureCiphers = mkOption {
        description = "Whether to require the upstream to support Perfect Forward Secrecy cipher suites. If a connection attempt to an upstream returns the error `remote error: tls: handshake failure`, try setting this to true.";
        type = types.bool;
        default = false;
      };

      authURL = mkOption {
        description = "Default authorization service URL for forward auth (e.g., http://authelia:9091). If set, all requests will be validated against this service before being proxied.";
        type = with types; nullOr str;
        default = null;
      };

      authPath = mkOption {
        description = "Default authorization service endpoint path";
        type = types.str;
        default = "/api/authz/forward-auth";
      };

      authTimeout = mkOption {
        description = "Default timeout for authorization requests";
        type = with types; nullOr str;
        default = "5s";
      };

      authCopyHeaders = mkOption {
        description = "Default headers to copy from auth response to upstream request";
        type = types.attrsOf types.str;
        default = {};
        example = {
          "Remote-User" = "";
          "Remote-Groups" = "";
          "Remote-Name" = "";
          "Remote-Email" = "";
        };
      };

      authInsecureHTTPS = mkOption {
        description = "Default setting for disabling TLS certificate validation for auth service";
        type = types.bool;
        default = false;
      };

      authBypassForTailnet = mkOption {
        description = "Default setting for bypassing forward auth for requests from Tailscale network (authenticated users)";
        type = types.bool;
        default = false;
      };

      urlParts = mkOption {
        description = "Default URL parts for tsnsrv services. Each service will have the parts here interpolated onto its .toURL option by default.";
        type = types.submodule urlPartsSubmodule;
      };
    };

    services.tsnsrv.prometheusAddr = mkOption {
      description = "Address to expose Prometheus metrics and pprof endpoints on for the entire tsnsrv process. Set to null to disable.";
      type = with types; nullOr str;
      default = ":9099";
    };

    services.tsnsrv.services = mkOption {
      description = "tsnsrv services";
      default = {};
      type = types.attrsOf (types.submodule serviceSubmodule);
      example = false;
    };

    virtualisation.oci-sidecars.tsnsrv = {
      enable = mkEnableOption "tsnsrv oci sidecar containers";

      authKeyPath = mkOption {
        description = "Path to a file containing a tailscale auth key. Make this a secret";
        type = types.path;
        default = config.services.tsnsrv.defaults.authKeyPath;
        defaultText = lib.literalExpression "config.services.tsnsrv.defaults.authKeyPath";
      };

      containers = mkOption {
        description = "Attrset mapping sidecar container names to their respective tsnsrv service definition. Each sidecar container will be attached to the container it belongs to, sharing its network.";
        type = types.attrsOf (types.submodule {
          options = {
            name = mkOption {
              description = "Name to use for the tsnet service. This defaults to the container name.";
              type = types.nullOr types.str;
              default = null;
            };

            forContainer = mkOption {
              description = "The container to which to attach the sidecar.";
              type = types.str; # TODO: see if we can constrain this to all the oci containers in the system definition, with types.oneOf or an appropriate check.
            };

            service = mkOption {
              description = "tsnsrv service definition for the sidecar.";
              type = types.submodule serviceSubmodule;
            };
          };
        });
      };
    };
  };

  config = let
    lockedDownserviceConfig = {
      PrivateNetwork = false; # We need access to the internet for ts
      # Activate a bunch of strictness:
      DeviceAllow = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateMounts = true;
      PrivateTmp = true;
      PrivateUsers = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectProc = "noaccess";
      ProtectKernelModules = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelTunables = true;
      RestrictNamespaces = true;
      AmbientCapabilities = "";
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      RemoveIPC = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      UMask = "0066";
    };

    # Determine which package to use (use first service's package or default)
    multiServicePackage = let
      firstService = lib.head (lib.attrValues config.services.tsnsrv.services);
    in firstService.package or config.services.tsnsrv.defaults.package;

    # Collect all supplemental groups from all services
    allSupplementalGroups = lib.unique (
      lib.flatten (
        lib.mapAttrsToList (_: service: service.supplementalGroups)
        config.services.tsnsrv.services
      )
    );
  in
    lib.mkMerge [
      (lib.mkIf (config.services.tsnsrv.enable || config.virtualisation.oci-sidecars.tsnsrv.enable)
        {users.groups.tsnsrv = {};})
      (lib.mkIf config.services.tsnsrv.enable {
        assertions =
          lib.mapAttrsToList (name: service: {
            assertion = ((service.certificateFile != null) && (service.certificateKey != null)) || ((service.certificateFile == null) && (service.certificateKey == null));
            message = "Both certificateFile and certificateKey must either be set or null on services.tsnsrv.services.${name}";
          })
          config.services.tsnsrv.services;

        systemd.services.tsnsrv-all = let
          configFile = generateMultiServiceConfig {
            services = config.services.tsnsrv.services;
            stateBaseDir = "/var/lib/tsnsrv-all";
            authKeyPath = "/run/credentials/tsnsrv-all.service/authKey";
            prometheusAddr = config.services.tsnsrv.prometheusAddr;
          };
          # Use first service for loginServerUrl, or null
          firstService = lib.head (lib.attrValues config.services.tsnsrv.services);
          loginServerUrl = firstService.loginServerUrl or null;
        in {
          wantedBy = ["multi-user.target"];
          after = ["network-online.target"];
          wants = ["network-online.target"];
          script = ''
            exec ${lib.getExe multiServicePackage} -config=${configFile}
          '';
          stopIfChanged = false;
          serviceConfig =
            ({
              DynamicUser = true;
              Restart = "always";
              SupplementaryGroups = [config.users.groups.tsnsrv.name] ++ allSupplementalGroups;
              StateDirectory = "tsnsrv-all";
              StateDirectoryMode = "0700";
              LoadCredential = [
                "authKey:${config.services.tsnsrv.defaults.authKeyPath}"
              ];
              Environment = ["HOME=%S/tsnsrv-all"];
            }
            // lib.optionalAttrs (loginServerUrl != null) {
              Environment = ["HOME=%S/tsnsrv-all" "TS_URL=${loginServerUrl}"];
            })
            // lockedDownserviceConfig;
        };
      })

      (lib.mkIf config.virtualisation.oci-sidecars.tsnsrv.enable {
        virtualisation.oci-containers.containers =
          lib.mapAttrs' (name: sidecar: {
            inherit name;
            value = let
              serviceName = "${config.virtualisation.oci-containers.backend}-${name}";
              credentialsDir = "/run/credentials/${serviceName}.service";
            in {
              imageFile = flake.packages.${pkgs.stdenv.targetPlatform.system}.tsnsrvOciImage;
              image = "tsnsrv:latest";
              dependsOn = [sidecar.forContainer];
              user = config.virtualisation.oci-containers.containers.${sidecar.forContainer}.user;
              volumes = [
                # The service's state dir; we have to infer /var/lib
                # because the backends don't support using the
                # $STATE_DIRECTORY environment variable in volume specs.
                "/var/lib/${serviceName}:/state"

                # Same for the service's credentials dir:
                "${credentialsDir}:${credentialsDir}"
              ];
              extraOptions = [
                "--network=container:${sidecar.forContainer}"
              ];
              environment = lib.optionalAttrs (sidecar.service.loginServerUrl != null) {
                TS_URL = sidecar.service.loginServerUrl;
              };
              cmd =
                ["-stateDir=/state" "-authkeyPath=${credentialsDir}/authKey"]
                ++ (serviceArgs {
                  name =
                    if sidecar.name == null
                    then name
                    else sidecar.name;
                  inherit (sidecar) service;
                });
            };
          })
          config.virtualisation.oci-sidecars.tsnsrv.containers;

        systemd.services =
          (
            # systemd unit settings for the respective podman services:
            lib.mapAttrs' (name: sidecar: let
              serviceName = "${config.virtualisation.oci-containers.backend}-${name}";
            in {
              name = serviceName;
              value = {
                path = ["/run/wrappers"];
                serviceConfig = {
                  StateDirectory = serviceName;
                  StateDirectoryMode = "0700";
                  SupplementaryGroups = [config.users.groups.tsnsrv.name] ++ sidecar.service.supplementalGroups;
                  LoadCredential = [
                    "authKey:${sidecar.service.authKeyPath}"
                  ];
                };
              };
            })
            config.virtualisation.oci-sidecars.tsnsrv.containers
          )
          // (
            # systemd unit of the container we're sidecar-ing to:
            # Ensure that the sidecar is up when the "main" container is up.
            lib.foldAttrs (item: acc: {unitConfig.Upholds = acc.unitConfig.Upholds ++ ["${item}.service"];})
            {unitConfig.Upholds = [];}
            (lib.mapAttrsToList (name: sidecar: let
                fromServiceName = "${config.virtualisation.oci-containers.backend}-${sidecar.forContainer}";
                toServiceName = "${config.virtualisation.oci-containers.backend}-${name}";
              in {
                "${fromServiceName}" = toServiceName;
              })
              config.virtualisation.oci-sidecars.tsnsrv.containers)
          );
      })
    ];
}
