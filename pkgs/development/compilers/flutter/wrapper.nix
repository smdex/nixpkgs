{ lib
, stdenv
, darwin
, callPackage
, flutter
, supportedTargetPlatforms ? [
    "universal"
    "web"
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux "linux"
  ++ lib.optional (stdenv.hostPlatform.isx86_64 || stdenv.hostPlatform.isDarwin) "android"
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ "macos" "ios" ]
, artifactHashes ? (import ./artifacts/hashes.nix).${flutter.version}
, extraPkgConfigPackages ? [ ]
, extraLibraries ? [ ]
, extraIncludes ? [ ]
, extraCxxFlags ? [ ]
, extraCFlags ? [ ]
, extraLinkerFlags ? [ ]
, makeWrapper
, runCommandLocal
, writeShellScript
, wrapGAppsHook
, git
, which
, pkg-config
, atk
, cairo
, gdk-pixbuf
, glib
, gtk3
, harfbuzz
, libepoxy
, pango
, libX11
, xorgproto
, libdeflate
, zlib
, cmake
, ninja
, clang
, lndir
, symlinkJoin
}:

let
  supportsLinuxDesktopTarget = builtins.elem "linux" supportedTargetPlatforms;

  platformArtifacts = lib.genAttrs supportedTargetPlatforms (platform:
    (callPackage ./artifacts/prepare-artifacts.nix {
      src = callPackage ./artifacts/fetch-artifacts.nix {
        inherit platform;
        # Use a version of Flutter with just enough capabilities to download
        # artifacts.
        flutter = callPackage ./wrapper.nix {
          inherit flutter;
          supportedTargetPlatforms = [ ];
        };
        hash = artifactHashes.${platform} or "";
      };
    }).overrideAttrs (
      if builtins.pathExists ./artifacts/overrides/${platform}.nix
      then callPackage ./artifacts/overrides/${platform}.nix { }
      else ({ ... }: { })
    ));

  cacheDir = symlinkJoin rec {
    name = "flutter-cache-dir";
    paths = builtins.attrValues platformArtifacts;
    postBuild = ''
      mkdir -p "$out/bin/cache"
      ln -s '${flutter}/bin/cache/dart-sdk' "$out/bin/cache"
    '';
    passthru.platform = platformArtifacts;
  };

  # By default, Flutter stores downloaded files (such as the Pub cache) in the SDK directory.
  # Wrap it to ensure that it does not do that, preferring home directories instead.
  # The sh file `$out/bin/internal/shared.sh` runs when launching Flutter and calls `"$FLUTTER_ROOT/bin/cache/` instead of our environment variable `FLUTTER_CACHE_DIR`.
  # We do not patch it since the script doesn't require engine artifacts(which are the only thing not added by the unwrapped derivation), so it shouldn't fail, and patching it will just be harder to maintain.
  immutableFlutter = writeShellScript "flutter_immutable" ''
    export PUB_CACHE=''${PUB_CACHE:-"$HOME/.pub-cache"}
    export FLUTTER_CACHE_DIR=''${FLUTTER_CACHE_DIR:-'${cacheDir}/bin/cache'}
    ${flutter}/bin/flutter "$@"
  '';

  # Tools that the Flutter tool depends on.
  tools = [ git which ];

  # Libraries that Flutter apps depend on at runtime.
  appRuntimeDeps = lib.optionals supportsLinuxDesktopTarget [
    atk
    cairo
    gdk-pixbuf
    glib
    gtk3
    harfbuzz
    libepoxy
    pango
    libX11
    libdeflate
  ];

  # Development packages required for compilation.
  appBuildDeps =
    let
      # https://discourse.nixos.org/t/handling-transitive-c-dependencies/5942/3
      deps = pkg: builtins.filter lib.isDerivation ((pkg.buildInputs or [ ]) ++ (pkg.propagatedBuildInputs or [ ]));
      collect = pkg: lib.unique ([ pkg ] ++ deps pkg ++ builtins.concatMap collect (deps pkg));
    in
    builtins.concatMap collect appRuntimeDeps;

  # Some header files and libraries are not properly located by the Flutter SDK.
  # They must be manually included.
  appStaticBuildDeps = (lib.optionals supportsLinuxDesktopTarget [ libX11 xorgproto zlib ]) ++ extraLibraries;

  # Tools used by the Flutter SDK to compile applications.
  buildTools = lib.optionals supportsLinuxDesktopTarget [
    pkg-config
    cmake
    ninja
    clang
  ];

  # Nix-specific compiler configuration.
  pkgConfigPackages = map (lib.getOutput "dev") (appBuildDeps ++ extraPkgConfigPackages);
  includeFlags = map (pkg: "-isystem ${lib.getOutput "dev" pkg}/include") (appStaticBuildDeps ++ extraIncludes);
  linkerFlags = (map (pkg: "-rpath,${lib.getOutput "lib" pkg}/lib") appRuntimeDeps) ++ extraLinkerFlags;
in
(callPackage ./sdk-symlink.nix { }) (stdenv.mkDerivation
{
  pname = "flutter-wrapped";
  inherit (flutter) version;

  nativeBuildInputs = [ makeWrapper ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.DarwinTools ]
    ++ lib.optionals supportsLinuxDesktopTarget [ glib wrapGAppsHook ];

  passthru = flutter.passthru // {
    unwrapped = flutter;
    inherit cacheDir;
  };

  dontUnpack = true;
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    for path in ${builtins.concatStringsSep " " (builtins.foldl' (paths: pkg: paths ++ (map (directory: "'${pkg}/${directory}/pkgconfig'") ["lib" "share"])) [ ] pkgConfigPackages)}; do
      addToSearchPath FLUTTER_PKG_CONFIG_PATH "$path"
    done

    mkdir -p $out/bin
    makeWrapper '${immutableFlutter}' $out/bin/flutter \
      --set-default ANDROID_EMULATOR_USE_SYSTEM_LIBS 1 \
      --suffix PATH : '${lib.makeBinPath (tools ++ buildTools)}' \
      --suffix PKG_CONFIG_PATH : "$FLUTTER_PKG_CONFIG_PATH" \
      --suffix LIBRARY_PATH : '${lib.makeLibraryPath appStaticBuildDeps}' \
      --prefix CXXFLAGS "''\t" '${builtins.concatStringsSep " " (includeFlags ++ extraCxxFlags)}' \
      --prefix CFLAGS "''\t" '${builtins.concatStringsSep " " (includeFlags ++ extraCFlags)}' \
      --prefix LDFLAGS "''\t" '${builtins.concatStringsSep " " (map (flag: "-Wl,${flag}") linkerFlags)}' \
      ''${gappsWrapperArgs[@]}

    runHook postInstall
  '';

  inherit (flutter) meta;
})
