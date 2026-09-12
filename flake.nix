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

      # --- Emulator rig (automated performance testing; see docs/perf-automation-plan.md) ---
      # DELIBERATELY a second composeAndroidPackages call rather than flags on the build's.
      # Setting includeEmulator/includeSystemImages on mkToolchain would change the BUILD's SDK
      # derivation and force the whole build closure to be re-realised, so `nix run .#build` would
      # stop being byte-identical across this change. Keeping them apart costs one extra
      # derivation and keeps the build path untouched.
      emulatorVersion    = "36.6.9"; # newest in the pinned nixpkgs (repo.json `latest` is 36.5.11,
                                     # but 36.6.9 is present and is what we pin).
      emulatorApiVersion = "36";     # matches targetSdk 36. compileSdk 37 is a *build* concern;
                                     # the AVD wants the API the app actually targets.
      emulatorImageType  = "google_apis"; # NOT google_apis_playstore: Play images are `user`
                                     # builds that refuse `adb root`, and perfetto capture needs it.
                                     # Also not *_atd: ATD images strip GPU rendering, so they
                                     # cannot produce frame timings at all.
      emulatorAbi        = "x86_64"; # :ffmpeg ships prebuilt native libs for arm64-v8a + x86_64
                                     # only, and x86_64 is the one that runs at native speed on
                                     # this host under KVM.
      avdName            = "pipepiped_bench_api${emulatorApiVersion}";

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

      # Emulator-only SDK: cmdline-tools (for avdmanager), the emulator, and exactly one system
      # image. No build-tools -- nothing here compiles.
      mkEmulatorToolchain = system:
        let
          pkgs = mkPkgs system;
          composition = pkgs.androidenv.composeAndroidPackages {
            inherit cmdLineToolsVersion platformToolsVersion emulatorVersion;
            buildToolsVersions  = [ ];
            platformVersions    = [ emulatorApiVersion ];
            systemImageTypes    = [ emulatorImageType ];
            abiVersions         = [ emulatorAbi ];
            includeEmulator     = true;
            includeSystemImages = true;
            includeNDK          = false;
            includeSources      = false;
          };
          sdkRoot = "${composition.androidsdk}/libexec/android-sdk";
        in
        { inherit pkgs composition sdkRoot; };

      # Shared launcher: run a Gradle task in the PipePipeClient submodule under the Nix toolchain.
      mkGradleApp = system: { name, gradleTask, outSubdir, blurb, extraProps ? "" }:
        let
          inherit (mkToolchain system) pkgs jdk sdkRoot aapt2;
          # Fold extraProps onto the -PforkMinify line rather than emitting its own line. An
          # empty extraProps must produce text byte-identical to before this parameter existed,
          # or `.#build`'s derivation hash changes and the "adding perf tooling leaves the build
          # untouched" guarantee quietly stops being true.
          forkProps =
            if extraProps == "" then "-PforkMinify=false" else "-PforkMinify=false ${extraProps}";
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
              ${forkProps} \
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

      # `.#benchmark` builds the NON-DEBUGGABLE benchmark variant used for performance work.
      # This exists because ART refuses to AOT-compile a debuggable package: on the debug build
      # `cmd package compile -m speed -f` reports Success and silently leaves the filter at
      # "verify", so every number measured there is interpreted+JIT and the compilation state can
      # be neither controlled nor truthfully recorded. Verified: the benchmark variant reports
      # [status=speed], the debug one stays [status=verify].
      #
      # It inherits mkGradleApp's -PforkMinify=false so the measured binary matches what this
      # fork actually SHIPS via `.#build` -- measuring a minified build we never release would
      # answer the wrong question. Installs as wtf.pipepiped.benchmark, alongside debug/release.
      mkBenchmarkApp = system: mkGradleApp system {
        name = "pipepiped-benchmark";
        gradleTask = ":app:assembleBenchmark";
        extraProps = "-PforkBenchmark=true";
        outSubdir = "app/build/outputs/apk/benchmark";
        blurb = "Building the non-debuggable benchmark APK (AOT-compilable, profileable)...";
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

      # `.#emulator` creates the pinned AVD if missing, boots it headless, waits for the system to
      # be genuinely usable (not just for adbd), and applies the settings that make measurement
      # reproducible. Stays in the foreground; Ctrl-C shuts the emulator down.
      #
      # Knobs (all env vars):
      #   PIPEPIPED_AVD_HOME  where AVDs live          (default ~/.local/share/pipepiped-perf/avd)
      #   PIPEPIPED_EMU_PORT  adb port                 (default 5554)
      #   PIPEPIPED_EMU_WIPE  0 to keep /data          (default 1 -- wipe, for reproducibility)
      #   PIPEPIPED_EMU_WINDOW 1 to show the window    (default 0 -- headless)
      #   PIPEPIPED_EMU_CORES / _RAM_MB                (default 4 / 4096)
      mkEmulatorApp = system:
        let
          inherit (mkEmulatorToolchain system) pkgs sdkRoot composition;
          inherit (mkToolchain system) jdk;
        in
        pkgs.writeShellApplication {
          name = "pipepiped-emulator";
          runtimeInputs = [
            jdk
            pkgs.android-tools
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gawk
          ];
          text = ''
            SDK_ROOT="${sdkRoot}"
            AVD_NAME="${avdName}"
            SYSTEM_IMAGE="system-images;android-${emulatorApiVersion};${emulatorImageType};${emulatorAbi}"

            AVD_HOME="''${PIPEPIPED_AVD_HOME:-$HOME/.local/share/pipepiped-perf/avd}"
            EMU_PORT="''${PIPEPIPED_EMU_PORT:-5554}"
            EMU_WIPE="''${PIPEPIPED_EMU_WIPE:-1}"
            EMU_WINDOW="''${PIPEPIPED_EMU_WINDOW:-0}"
            EMU_CORES="''${PIPEPIPED_EMU_CORES:-4}"
            EMU_RAM_MB="''${PIPEPIPED_EMU_RAM_MB:-4096}"
            # swiftshader_indirect is the default because it is deterministic -- it removes the
            # host GPU driver, compositor and thermal behaviour from every number. The cost is
            # that software rasterization DOMINATES the frame (measured: gpuSwap ~21ms of a
            # ~29ms frame), which hides UI-thread work and makes UI-thread optimisations look
            # worthless. Set PIPEPIPED_EMU_GPU=host when the question is about UI-thread cost.
            EMU_GPU="''${PIPEPIPED_EMU_GPU:-swiftshader_indirect}"

            export JAVA_HOME="${jdk.home}"
            export ANDROID_HOME="$SDK_ROOT"
            export ANDROID_SDK_ROOT="$SDK_ROOT"
            export ANDROID_AVD_HOME="$AVD_HOME"
            export ANDROID_SERIAL="emulator-$EMU_PORT"

            # KVM is what makes an x86_64 AVD usable. Without it the emulator falls back to full
            # emulation and every number below is meaningless, so fail loudly rather than measure
            # something useless.
            if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
              echo "error: /dev/kvm is not readable+writable by $(id -un)." >&2
              echo "       Check: ls -l /dev/kvm   (want crw-rw-rw- or membership of the kvm group)" >&2
              exit 1
            fi

            # Refuse to start onto a serial something else already owns. Two rigs on one serial
            # means adb commands land on whichever booted last, and an A/B silently compares
            # two different machines.
            if adb devices | awk -v s="$ANDROID_SERIAL" 'NR>1 && $1 == s { found=1 } END { exit !found }'; then
              echo "error: $ANDROID_SERIAL is already present in 'adb devices'." >&2
              echo "       Stop it first (adb -s $ANDROID_SERIAL emu kill), or pick another" >&2
              echo "       port: PIPEPIPED_EMU_PORT=5556 nix run .#emulator" >&2
              exit 1
            fi

            mkdir -p "$AVD_HOME"

            if [ ! -d "$AVD_HOME/$AVD_NAME.avd" ]; then
              echo "[*] Creating AVD '$AVD_NAME' from $SYSTEM_IMAGE"
              # No --device: a named hardware profile would silently set properties we then
              # fight with below. Start generic and pin every value explicitly.
              echo "no" | "$SDK_ROOT/cmdline-tools/${cmdLineToolsVersion}/bin/avdmanager" create avd \
                --name "$AVD_NAME" \
                --package "$SYSTEM_IMAGE" \
                --force
            fi

            # --- Pin the hardware profile -------------------------------------------------
            # Every value here is a measurement variable. Leaving them to the emulator's
            # defaults means they can change under a nixpkgs bump and silently move results.
            CONFIG="$AVD_HOME/$AVD_NAME.avd/config.ini"
            set_cfg() {
              local key="$1" value="$2"
              if grep -q "^$key=" "$CONFIG" 2>/dev/null; then
                sed -i "s|^$key=.*|$key=$value|" "$CONFIG"
              else
                printf '%s=%s\n' "$key" "$value" >> "$CONFIG"
              fi
            }
            set_cfg hw.cpu.ncore       "$EMU_CORES"
            set_cfg hw.ramSize         "$EMU_RAM_MB"
            set_cfg vm.heapSize        512
            set_cfg hw.lcd.density     440
            set_cfg hw.lcd.width       1080
            set_cfg hw.lcd.height      2400
            set_cfg hw.gpu.enabled     yes
            set_cfg hw.gpu.mode        "$EMU_GPU"
            set_cfg hw.audioInput      no
            set_cfg hw.audioOutput     no
            set_cfg hw.keyboard        yes
            set_cfg disk.dataPartition.size 6G

            # --- Launch -------------------------------------------------------------------
            emu_args=(
              -avd "$AVD_NAME"
              -port "$EMU_PORT"
              -gpu "$EMU_GPU"
              -no-snapshot
              -no-audio
              -no-boot-anim
              -netdelay none
              -netspeed full
              -camera-back none
              -camera-front none
              -memory "$EMU_RAM_MB"
              -accel on
            )
            [ "$EMU_WINDOW" = "1" ] || emu_args+=( -no-window )
            [ "$EMU_WIPE" = "1" ] && emu_args+=( -wipe-data )

            # androidenv exposes the emulator both under the SDK root and on the composition's
            # bin/. Resolve rather than assume, so a nixpkgs layout change fails loudly here
            # instead of somewhere less obvious.
            if [ -x "$SDK_ROOT/emulator/emulator" ]; then
              EMULATOR_BIN="$SDK_ROOT/emulator/emulator"
            elif [ -x "${composition.androidsdk}/bin/emulator" ]; then
              EMULATOR_BIN="${composition.androidsdk}/bin/emulator"
            else
              echo "error: no emulator binary found under $SDK_ROOT" >&2
              exit 1
            fi

            echo "[*] SDK:      $SDK_ROOT"
            echo "[*] Emulator: $EMULATOR_BIN"
            echo "[*] AVD home: $AVD_HOME"
            echo "[*] Booting $AVD_NAME on port $EMU_PORT (wipe=$EMU_WIPE, window=$EMU_WINDOW)"

            "$EMULATOR_BIN" "''${emu_args[@]}" &
            EMU_PID=$!
            # shellcheck disable=SC2317  # invoked via trap
            shutdown() {
              trap - INT TERM EXIT
              # Only ever kill the emulator THIS script started. `adb emu kill` addresses a
              # SERIAL, and serials are reused the moment a port frees up -- an earlier run
              # timing out after a newer one has claimed emulator-5554 would otherwise kill
              # the newer one. Gate on our own PID still being alive, which is what proves we
              # still own that serial.
              if kill -0 "$EMU_PID" 2>/dev/null; then
                echo
                echo "[*] Stopping emulator (pid $EMU_PID)..."
                adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
                for _ in $(seq 1 20); do
                  kill -0 "$EMU_PID" 2>/dev/null || break
                  sleep 0.5
                done
                kill "$EMU_PID" >/dev/null 2>&1 || true
              fi
              wait "$EMU_PID" 2>/dev/null || true
            }
            trap shutdown INT TERM EXIT

            # --- Wait for the system to be genuinely usable -------------------------------
            # `adb wait-for-device` returns as soon as adbd answers, which is long before the
            # framework is up. All three checks below are needed.
            echo "[*] Waiting for boot (timeout 600s)..."
            adb start-server >/dev/null 2>&1 || true
            BOOT_DEADLINE=$(( SECONDS + 600 ))
            boot_deadline_check() {
              if [ "$SECONDS" -ge "$BOOT_DEADLINE" ]; then
                echo "error: emulator did not finish booting within 600s (stuck at: $1)." >&2
                exit 1
              fi
              sleep 2
            }

            # 1. adbd answering at all.
            timeout 600 adb -s "$ANDROID_SERIAL" wait-for-device || {
              echo "error: device never appeared to adb." >&2; exit 1; }
            # 2. The framework reports boot complete.
            while [ "$(adb -s "$ANDROID_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
              boot_deadline_check sys.boot_completed
            done
            # 3. PackageManager actually answers -- boot_completed fires before it is usable.
            while ! adb -s "$ANDROID_SERIAL" shell pm path android >/dev/null 2>&1; do
              boot_deadline_check "pm path android"
            done
            # 4. Boot animation gone, so the first measured frame is not competing with it.
            # NOTE: the emulator boots with androidboot.debug.sf.nobootanimation=1, so the
            # bootanim service never runs and the property stays EMPTY -- it never becomes
            # "stopped". Waiting only for "stopped" hangs until the timeout. Empty is only
            # trusted here because steps 2 and 3 have already passed, so an unset property
            # means "no such service", not "too early to tell".
            while true; do
              bootanim="$(adb -s "$ANDROID_SERIAL" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')"
              [ "$bootanim" = "stopped" ] && break
              [ -z "$bootanim" ] && break
              boot_deadline_check init.svc.bootanim
            done

            # --- Quiet the device ---------------------------------------------------------
            # -wipe-data resets all of this, so it re-applies on every boot by design.
            adb -s "$ANDROID_SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true
            for scale in window_animation_scale transition_animation_scale animator_duration_scale; do
              adb -s "$ANDROID_SERIAL" shell settings put global "$scale" 0.0 || true
            done
            adb -s "$ANDROID_SERIAL" shell svc power stayon true >/dev/null 2>&1 || true
            adb -s "$ANDROID_SERIAL" shell settings put global auto_time 0 >/dev/null 2>&1 || true
            adb -s "$ANDROID_SERIAL" shell settings put global auto_time_zone 0 >/dev/null 2>&1 || true
            # Background dexopt and doze both wake up mid-measurement and move numbers.
            adb -s "$ANDROID_SERIAL" shell cmd package bg-dexopt-job --disable >/dev/null 2>&1 || true
            adb -s "$ANDROID_SERIAL" shell dumpsys deviceidle disable >/dev/null 2>&1 || true

            echo
            echo "[OK] $ANDROID_SERIAL ready."
            echo "     API:        $(adb -s "$ANDROID_SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
            echo "     ABI:        $(adb -s "$ANDROID_SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')"
            echo "     Build type: $(adb -s "$ANDROID_SERIAL" shell getprop ro.build.type | tr -d '\r')"
            for scale in window_animation_scale transition_animation_scale animator_duration_scale; do
              printf '     %-26s %s\n' "$scale" \
                "$(adb -s "$ANDROID_SERIAL" shell settings get global "$scale" | tr -d '\r')"
            done
            echo
            echo "     Use ANDROID_SERIAL=$ANDROID_SERIAL for adb/gradle. Ctrl-C here to shut down."
            wait "$EMU_PID"
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
          emulator = { type = "app"; program = "${mkEmulatorApp system}/bin/pipepiped-emulator"; };
          benchmark = { type = "app"; program = "${mkBenchmarkApp system}/bin/pipepiped-benchmark"; };
        in { inherit build debug install emulator benchmark; default = build; });

      devShells = forAllSystems (system: { default = mkDevShell system; });

      # Exposed for debugging / prefetching the toolchain (`nix build .#androidSdk`)
      # and to inspect/run the launcher without `nix run` (`nix build .#buildScript`).
      packages = forAllSystems (system:
        let tc = mkToolchain system;
        in {
          androidSdk = tc.androidComposition.androidsdk;
          buildScript = mkBuildApp system;
          installScript = mkInstallApp system;
          # `nix build .#androidEmulatorSdk` prefetches the emulator + system image (several GB)
          # without booting anything.
          androidEmulatorSdk = (mkEmulatorToolchain system).composition.androidsdk;
          emulatorScript = mkEmulatorApp system;
          benchmarkScript = mkBenchmarkApp system;
        });
    };
}
