{
  description = "PipePipe+ — reproducible toolchain to build (and, from Phase 6, sign) APKs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # androidenv (and therefore this build) only makes sense on Linux/macOS.
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # --- Toolchain pinned to *this project's* build (PipePipeClient), NOT continuum's ---
      # PipePipeClient: AGP 7.3.0, Gradle wrapper 7.5, Kotlin 1.7.20, compileSdk/targetSdk 33,
      # minSdk 21, Java 11 bytecode. Upstream CI (.github/workflows/ci.yml) builds with JDK 11.
      # The :ffmpeg module ships a prebuilt ffmpeg-kit.aar, so there is NO native code -> no NDK.
      platformVersions     = [ "33" ];
      # AGP 7.3.0's default build-tools is 30.0.3; 33.0.1 is kept to pair with compileSdk 33.
      buildToolsVersions   = [ "30.0.3" "33.0.1" ];
      aapt2BuildTools      = "33.0.1"; # which build-tools' aapt2 to feed AGP (see below)
      cmdLineToolsVersion  = "19.0";
      platformToolsVersion = "36.0.2"; # platform-tools is backward-compatible; fine for SDK 33

      mkPkgs = system: import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true; # the Android SDK is unfree
          android_sdk.accept_license = true;
        };
      };

      mkToolchain = system:
        let
          pkgs = mkPkgs system;

          androidComposition = pkgs.androidenv.composeAndroidPackages {
            inherit cmdLineToolsVersion platformToolsVersion
              buildToolsVersions platformVersions;
            includeNDK = false; # no native C/C++; :ffmpeg is a prebuilt .aar
            includeEmulator = false;
            includeSystemImages = false;
            includeSources = false;
          };

          # Build with JDK 11 to match upstream CI (Gradle 7.5 + AGP 7.3 do NOT support JDK 21).
          # Use the PREBUILT Temurin binary, NOT nixpkgs' source-built `jdk11`: on nixpkgs-unstable
          # the latter is compiled by gcc 15, which miscompiles OpenJDK 11's HotSpot lock code and
          # segfaults the Gradle daemon inside ObjectSynchronizer::inflate (null deref, si_addr=0x0)
          # under concurrent monitor contention at build startup -- reproduced 3/3, independent of
          # biased locking and JIT tier (it crashed from both the interpreter and C1). Temurin is
          # vendor-built with an OpenJDK-11-era toolchain and builds cleanly (BUILD SUCCESSFUL,
          # 5 APKs). See docs/progress.md (Session 6) for the full root-cause write-up.
          jdk = pkgs.temurin-bin-11;
          sdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";
          # AGP otherwise downloads its own aapt2 from Maven (a prebuilt ELF that won't run on
          # NixOS). Point it at the autoPatchelf'd SDK binary instead.
          aapt2 = "${sdkRoot}/build-tools/${aapt2BuildTools}/aapt2";
        in
        { inherit pkgs androidComposition jdk sdkRoot aapt2; };

      # Shared launcher: run a Gradle task in the PipePipeClient submodule under the Nix toolchain.
      mkGradleApp = system: { name, gradleTask, outSubdir, blurb }:
        let
          inherit (mkToolchain system) pkgs jdk sdkRoot aapt2;
        in
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ jdk pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
          text = ''
            # The PipePipe meta-repo has no gradlew at its root — the app lives in the
            # PipePipeClient submodule, which composite-includes ../PipePipeExtractor.
            META_ROOT="''${META_ROOT:-$PWD}"
            CLIENT_DIR="$META_ROOT/PipePipeClient"
            if [ ! -x "$CLIENT_DIR/gradlew" ]; then
              echo "error: $CLIENT_DIR/gradlew not found." >&2
              echo "       Run this from the PipePipe meta-repo root with submodules" >&2
              echo "       checked out (git submodule update --init PipePipeClient PipePipeExtractor)." >&2
              exit 1
            fi
            cd "$CLIENT_DIR"

            # --- Nix-provided toolchain ---
            export JAVA_HOME="${jdk.home}"
            export ANDROID_HOME="${sdkRoot}"
            export ANDROID_SDK_ROOT="${sdkRoot}"
            export PATH="$JAVA_HOME/bin:$PATH"

            echo "[*] JDK:         ${jdk.home}"
            echo "[*] Android SDK: ${sdkRoot}"

            # --- Point Gradle at the Nix SDK (only if not already pinned) ---
            if [ ! -f local.properties ]; then
              echo "sdk.dir=${sdkRoot}" > local.properties
              echo "[*] wrote PipePipeClient/local.properties (sdk.dir -> Nix SDK)"
            elif ! grep -q "^sdk.dir=${sdkRoot}$" local.properties; then
              echo "[WARNING] PipePipeClient/local.properties pins a different sdk.dir — the Nix SDK at" >&2
              echo "          ${sdkRoot} will NOT be used. Remove it to use the Nix SDK." >&2
            fi

            # --- Build ---
            # Extra args (e.g. -PforkVersionName=... -PforkVersionCode=...) are forwarded via "$@".
            echo "[*] ${blurb}"
            ./gradlew ${gradleTask} \
              -DskipFormatKtlint \
              -Pandroid.aapt2FromMavenOverride="${aapt2}" \
              --no-daemon --stacktrace "$@"

            out="${outSubdir}"
            echo
            echo "[OK] Build complete. APKs in PipePipeClient/$out/:"
            find "$out" -maxdepth 1 -name '*.apk' -printf '   %f\n' | sort
          '';
        };

      # Default `.#build` produces the SIGNED release (PipePipe+ identity), mirroring CI. It signs
      # when PipePipeClient/keystore.properties is present (the maintainer's gitignored local copy;
      # CI decodes it from the KEYSTORE_* secrets); without it, build.gradle emits an unsigned
      # release. Pass -PforkVersionName=... -PforkVersionCode=... to stamp a fork version.
      mkBuildApp = system: mkGradleApp system {
        name = "pipepipe-plus-build";
        gradleTask = ":app:assembleRelease";
        outSubdir = "app/build/outputs/apk/release";
        blurb = "Building SIGNED release APKs (first run fetches Gradle 7.5 + deps over the network)...";
      };

      # `.#debug` keeps the fast, debug-key-signed build for local iteration.
      mkDebugApp = system: mkGradleApp system {
        name = "pipepipe-plus-debug";
        gradleTask = ":app:assembleDebug";
        outSubdir = "app/build/outputs/apk/debug";
        blurb = "Building debug APKs (debug-key signed, fast local iteration)...";
      };

      mkDevShell = system:
        let
          inherit (mkToolchain system) pkgs jdk sdkRoot aapt2;
        in
        pkgs.mkShell {
          packages = [ jdk ];
          ANDROID_HOME = sdkRoot;
          ANDROID_SDK_ROOT = sdkRoot;
          JAVA_HOME = jdk.home;
          # Same aapt2 fix as the build app; export so `./gradlew` works in the shell.
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2}";
          shellHook = ''
            echo "PipePipe+ dev shell — JDK 11 + Android SDK (compileSdk 33)."
            echo "Build with:  cd PipePipeClient && ./gradlew :app:assembleDebug -DskipFormatKtlint"
          '';
        };
    in
    {
      apps = forAllSystems (system:
        let
          build = { type = "app"; program = "${mkBuildApp system}/bin/pipepipe-plus-build"; };
          debug = { type = "app"; program = "${mkDebugApp system}/bin/pipepipe-plus-debug"; };
        in { inherit build debug; default = build; });

      devShells = forAllSystems (system: { default = mkDevShell system; });

      # Exposed for debugging / prefetching the toolchain (`nix build .#androidSdk`)
      # and to inspect/run the launcher without `nix run` (`nix build .#buildScript`).
      packages = forAllSystems (system:
        let tc = mkToolchain system;
        in {
          androidSdk = tc.androidComposition.androidsdk;
          buildScript = mkBuildApp system;
        });
    };
}
