{
  description = "PipePipeD — reproducible toolchain to build (and, from Phase 6, sign) APKs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # androidenv (and therefore this build) only makes sense on Linux/macOS.
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # --- Toolchain pinned to *this project's* build (PipePipeClient), NOT continuum's ---
      # PipePipeClient (upstream v5.2.3-beta): AGP 9.2.1, Gradle wrapper 9.5.1, Kotlin 2.3.21,
      # compileSdk 37, targetSdk 36, minSdk 23, Java 25 bytecode (sourceCompatibility/jvmTarget 25).
      # Build uses Jetpack Compose; settings.gradle applies the foojay-resolver-convention plugin
      # for JDK toolchain resolution (neutralised for the offline JDK case in mkGradleApp below).
      # The :ffmpeg module ships a prebuilt ffmpeg-kit.aar, so there is NO native code -> no NDK.
      platformVersions     = [ "37" ]; # resolves to platforms/android-37.0 via androidenv's ".0"
                                        # fallback (hasVersion); AGP 9.2's max supported API is 37.0.
      # AGP 9.2's default AND minimum build-tools is 36.0.0, and app/build.gradle sets no
      # buildToolsVersion -- so AGP uses 36.0.0; it must be present for the offline build.
      buildToolsVersions   = [ "36.0.0" ];
      aapt2BuildTools      = "36.0.0"; # which build-tools' aapt2 to feed AGP (see below)
      cmdLineToolsVersion  = "19.0";
      platformToolsVersion = "36.0.2"; # backward-compatible; not on the build critical path
                                       # (the install app uses the standalone android-tools adb).

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

          # Build with JDK 25: app/build.gradle sets sourceCompatibility/targetCompatibility
          # VERSION_25 and Kotlin jvmTarget 25, so the compiler needs a JDK 25 (AGP 9.2's own
          # minimum is only JDK 17, but you cannot emit Java 25 bytecode on 17). Use the PREBUILT
          # Temurin binary rather than a nixpkgs source-built JDK: Temurin is vendor-built and
          # sidesteps toolchain-dependent HotSpot miscompiles. temurin-bin-25 (25.0.3) is a
          # prebuilt drop-in, so the old gcc-15 source-build hazard that forced temurin-bin-11
          # in the JDK-11 era does not apply here.
          jdk = pkgs.temurin-bin-25;
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

            # --- Point Gradle at the Nix SDK ---
            # Always (re)write sdk.dir when it does not match: local.properties is gitignored and
            # holds only sdk.dir for this project, and a stale pin left by a previous toolchain
            # (whose Nix store path may since have been garbage-collected) otherwise shadows
            # ANDROID_HOME and breaks the build with "sdk.dir ... Directory does not exist".
            if [ ! -f local.properties ] || ! grep -q "^sdk.dir=${sdkRoot}$" local.properties; then
              echo "sdk.dir=${sdkRoot}" > local.properties
              echo "[*] wrote PipePipeClient/local.properties (sdk.dir -> Nix SDK)"
            fi

            # --- Build ---
            # Extra args (e.g. -PforkVersionName=... -PforkVersionCode=...) are forwarded via "$@".
            # -PforkAbiFilter=universal builds one all-architecture APK (mirrors CI; far faster than
            # the upstream 5-APK split). Override locally with: nix run .#build -- -PforkAbiFilter=arm64-v8a
            # ("$@" comes last, and Gradle honours the last -P value for a given property).
            echo "[*] ${blurb}"
            # -PforkMinify=false skips R8 on the release build (faster; the fork needs no
            # shrink/obfuscate). No-op for .#debug (assembleDebug never minifies). Override with
            # nix run .#build -- -PforkMinify=true to restore upstream's minified release.
            ./gradlew ${gradleTask} \
              -DskipFormatKtlint \
              -Dorg.gradle.java.installations.auto-download=false \
              -Dorg.gradle.java.installations.paths="${jdk.home}" \
              -PforkAbiFilter=universal \
              -PforkMinify=false \
              -Pandroid.aapt2FromMavenOverride="${aapt2}" \
              --no-daemon --stacktrace "$@"

            out="${outSubdir}"
            echo
            echo "[OK] Build complete. APKs in PipePipeClient/$out/:"
            find "$out" -maxdepth 1 -name '*.apk' -printf '   %f\n' | sort
          '';
        };

      # Default `.#build` produces the SIGNED release (PipePipeD identity), mirroring CI. It signs
      # when PipePipeClient/keystore.properties is present (the maintainer's gitignored local copy;
      # CI decodes it from the KEYSTORE_* secrets); without it, build.gradle emits an unsigned
      # release. Pass -PforkVersionName=... -PforkVersionCode=... to stamp a fork version.
      mkBuildApp = system: mkGradleApp system {
        name = "pipepiped-build";
        gradleTask = ":app:assembleRelease";
        outSubdir = "app/build/outputs/apk/release";
        blurb = "Building SIGNED release APKs (first run fetches Gradle 9.5.1 + deps over the network)...";
      };

      # `.#debug` keeps the fast, debug-key-signed build for local iteration.
      mkDebugApp = system: mkGradleApp system {
        name = "pipepiped-debug";
        gradleTask = ":app:assembleDebug";
        outSubdir = "app/build/outputs/apk/debug";
        blurb = "Building debug APKs (debug-key signed, fast local iteration)...";
      };

      # `.#install` pushes the already-built APK(s) to a connected ADB device.
      # It installs both the signed release and the debug APK when both are present; whichever
      # variant(s) exist under app/build/outputs/apk/{release,debug}/ are installed.
      # It does NOT build — run `.#build` and/or `.#debug` first. Uses the standalone
      # `android-tools` adb, so installing does not pull the full Android SDK.
      # Device selection: adb honours $ANDROID_SERIAL; extra args (e.g. -g, -d) are forwarded to
      # `adb install` via `nix run .#install -- <args>`.
      mkInstallApp = system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.writeShellApplication {
          name = "pipepiped-install";
          runtimeInputs = [ pkgs.android-tools pkgs.coreutils pkgs.findutils pkgs.gawk ];
          text = ''
            META_ROOT="''${META_ROOT:-$PWD}"
            RELEASE_DIR="$META_ROOT/PipePipeClient/app/build/outputs/apk/release"
            DEBUG_DIR="$META_ROOT/PipePipeClient/app/build/outputs/apk/debug"

            # Newest *.apk in a directory, or empty string if the dir does not exist / is empty.
            newest_apk() {
              local dir="$1"
              [ -d "$dir" ] || return 0
              find "$dir" -maxdepth 1 -type f -name '*.apk' -printf '%T@ %p\n' \
                | sort -rn | head -n1 | cut -d' ' -f2-
            }

            release_apk="$(newest_apk "$RELEASE_DIR")"
            debug_apk="$(newest_apk "$DEBUG_DIR")"

            if [ -z "$release_apk" ] && [ -z "$debug_apk" ]; then
              echo "error: no APKs found in release or debug output dirs." >&2
              echo "       Build first:" >&2
              echo "         nix run .#build   — signed release" >&2
              echo "         nix run .#debug   — debug key" >&2
              exit 1
            fi

            # Connected, authorised devices. adb honours $ANDROID_SERIAL to target a specific one.
            readarray -t serials < <(adb devices | awk 'NR>1 && $2 == "device" { print $1 }')
            if [ "''${#serials[@]}" -eq 0 ]; then
              echo "error: no authorised ADB device found." >&2
              echo "       Enable USB debugging + accept the RSA prompt, then check: adb devices" >&2
              exit 1
            fi
            if [ "''${#serials[@]}" -gt 1 ] && [ -z "''${ANDROID_SERIAL:-}" ]; then
              echo "error: multiple devices connected:" >&2
              printf '         %s\n' "''${serials[@]}" >&2
              echo "       set ANDROID_SERIAL=<serial> to choose one, e.g.:" >&2
              echo "         ANDROID_SERIAL=''${serials[0]} nix run .#install" >&2
              exit 1
            fi

            install_count=0
            for apk in "$release_apk" "$debug_apk"; do
              [ -n "$apk" ] || continue
              echo "[*] Installing (adb install -r): $(basename "$apk")"
              # -r reinstalls keeping app data (same signing key). Extra args ("$@", e.g. -g to
              # grant runtime permissions, -d to allow a version downgrade) precede the APK path.
              adb install -r "$@" "$apk"
              echo "[OK] Installed: $(basename "$apk")"
              install_count=$((install_count + 1))
            done
            echo "[OK] $install_count APK(s) installed."
          '';
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
            echo "PipePipeD dev shell -- JDK 25 + Android SDK (compileSdk 37)."
            echo "Build with:  cd PipePipeClient && ./gradlew :app:assembleDebug -DskipFormatKtlint"
          '';
        };
    in
    {
      apps = forAllSystems (system:
        let
          build = { type = "app"; program = "${mkBuildApp system}/bin/pipepiped-build"; };
          debug = { type = "app"; program = "${mkDebugApp system}/bin/pipepiped-debug"; };
          install = { type = "app"; program = "${mkInstallApp system}/bin/pipepiped-install"; };
        in { inherit build debug install; default = build; });

      devShells = forAllSystems (system: { default = mkDevShell system; });

      # Exposed for debugging / prefetching the toolchain (`nix build .#androidSdk`)
      # and to inspect/run the launcher without `nix run` (`nix build .#buildScript`).
      packages = forAllSystems (system:
        let tc = mkToolchain system;
        in {
          androidSdk = tc.androidComposition.androidsdk;
          buildScript = mkBuildApp system;
          installScript = mkInstallApp system;
        });
    };
}
