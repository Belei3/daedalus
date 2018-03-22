with (import (fetchTarball https://github.com/NixOS/nixpkgs/archive/ffea68a09cedab941d19f02c9041689ebc81192e.tar.gz) { config = {}; });

with haskell.lib;

(justStaticExecutables (haskell.packages.ghc802.callPackage ./cardano-installer.nix {})).override
  (with haskell.packages.ghc802; {
    dhall-json = (overrideCabal dhall-json (drv: {
      src = pkgs.fetchFromGitHub {
        owner  = "dhall-lang";
        repo   = "dhall-json";
        rev    = "d6adaa265dcf8ab5899396b05d612b2d8092dca4";
        sha256 = "0pvbpbg6475drvpakny12y3z2dv0vj6x4hlk853dgb84xbsd8i33";
      };
      jailbreak = true;
      libraryHaskellDepends = drv.libraryHaskellDepends ++ [
        aeson-pretty
      ];
    })).override {
      dhall      = overrideCabal dhall (drv: {
        src = pkgs.fetchFromGitHub {
          owner  = "dhall-lang";
          repo   = "dhall-haskell";
          rev    = "4a085aa3d622886cf7dd96a1ad475ba914d5ab1f";
          sha256 = "0849rvv9m5rgxgvn60q2bwfr7m1syjkgxrrs4xafs10ymfdx0g9f";
        };
        jailbreak = true;
        libraryHaskellDepends = drv.libraryHaskellDepends ++ [
          base16-bytestring
          insert-ordered-containers
          lens-family-core
          prettyprinter-ansi-terminal
          repline
        ];
      });
    };
  })
