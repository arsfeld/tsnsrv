{
  pkgs,
  nixos-lib,
  nixosModule,
  ...
}: {
  systemd = import ./systemd.nix {inherit pkgs nixos-lib nixosModule;};
  oci = import ./oci.nix {inherit pkgs nixos-lib nixosModule;};
  authelia = import ./authelia.nix {inherit pkgs nixos-lib nixosModule;};
  multi-service = import ./multi-service.nix {inherit pkgs nixos-lib nixosModule;};
  separate-processes = import ./separate-processes.nix {inherit pkgs nixos-lib nixosModule;};
}
