{
  pkgs,
  nixos-lib,
  nixosModule,
  ...
}: let
  # Import the test template
  makeProfilingTest = serviceCount:
    import ./test.nix {
      inherit pkgs nixos-lib nixosModule serviceCount;
    };
in {
  # Create tests for different service counts
  # These verify that profiling infrastructure works
  # For actual profile collection, use the profiling runner script
  services-10 = makeProfilingTest 10;
  services-20 = makeProfilingTest 20;
  services-30 = makeProfilingTest 30;
  services-40 = makeProfilingTest 40;
  services-50 = makeProfilingTest 50;
}
