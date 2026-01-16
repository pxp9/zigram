{
  description = "A Nix-flake-based Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {nixpkgs-unstable, ...}:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        nixpkgs-unstable.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import nixpkgs-unstable {
              inherit system;
              config = {
                allowUnfree = true;
              };

            };
          }
        );
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              zig
              zls
              lldb
              claude-code
              bun
              # TDLib build dependencies
              cmake
              git
              gcc
              openssl
              zlib
              gperf
              pkg-config
              ccache
              # For extracting pre-compiled TDLib binaries
              unzip
              curl
              # LLVM libc++ for TDLib (pre-compiled with clang)
              llvmPackages.libcxx
              llvmPackages.libunwind
            ];
            # Make required libraries available at runtime
            LD_LIBRARY_PATH = "${pkgs.llvmPackages.libcxx}/lib:${pkgs.llvmPackages.libunwind}/lib:${pkgs.openssl.out}/lib:${pkgs.zlib.out}/lib";
          };
        }
      );
    };
}
