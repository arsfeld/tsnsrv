{
  pkgs,
  nixos-lib,
  nixosModule,
  validatorPackage,
}: let
  helper = import ./../helpers/cmdline_validation.nix {
    inherit pkgs nixos-lib nixosModule validatorPackage;
  };
in
  helper {
    name = "auth";
    testConfig = {
      services.tsnsrv.services.auth-test = {
        toURL = "http://127.0.0.1:3000";
        authURL = "http://authelia:9091";
        authPath = "/api/authz/forward-auth";
        authTimeout = "10s";
        authCopyHeaders = {
          "Remote-User" = "";
          "Remote-Groups" = "";
          "Remote-Email" = "";
        };
        authInsecureHTTPS = false;
        authBypassForTailnet = true;
      };
      systemd.services.tsnsrv-auth-test.enableStrictShellChecks = true;
    };
    testScript = ''
      machine.wait_for_unit("tsnsrv-auth-test")
    '';
  }