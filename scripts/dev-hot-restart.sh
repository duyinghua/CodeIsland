#!/usr/bin/env bash
# CodeIsland 开发热重启脚本：启动时构建并运行应用，随后监听源码变更，构建成功后自动重启。
# 优先使用 fswatch 高效监听；未安装 fswatch 时使用 Python3 标准库轮询文件状态。
set -euo pipefail

# 使用示例：
#   scripts/dev-hot-restart.sh --debounce 1.0 --paths "Sources,Tests,Package.swift"
#   scripts/dev-hot-restart.sh --build-cmd "swift build --disable-sandbox"
#   scripts/dev-hot-restart.sh --with-tests
#   scripts/dev-hot-restart.sh --socket-path /tmp/codeisland-dev.sock

DEBOUNCE="0.8"
WATCH_PATHS="Sources,Tests,Package.swift"
APP_PATH=".build/debug/CodeIsland.app"
APP_BUNDLE=""
APP_EXECUTABLE_SOURCE=""
BUILD_CMD="swift build --disable-sandbox"
WITH_TESTS=0
SOCKET_PATH=""

print_usage() {
  cat <<'EOF'
Usage: scripts/dev-hot-restart.sh [options]

Watch source changes, run the build pipeline at startup, and restart CodeIsland app only when builds succeed.
If any build fails, current app keeps running.

Examples:
  scripts/dev-hot-restart.sh --debounce 1.0 --paths "Sources,Tests,Package.swift"
  scripts/dev-hot-restart.sh --build-cmd "swift build --disable-sandbox"
  scripts/dev-hot-restart.sh --with-tests
  scripts/dev-hot-restart.sh --socket-path /tmp/codeisland-dev.sock

Options:
  --paths <csv>          Watch paths (default: Sources,Tests,Package.swift)
  --debounce <seconds>   Debounce window (default: 0.8)
  --app-path <path>      Development .app destination or built executable path
                         (default: .build/debug/CodeIsland.app)
  --build-cmd <command>  Build command (default: swift build --disable-sandbox)
  --with-tests           Run swift test after successful build before restart
  --socket-path <path>   Set CODEISLAND_SOCKET_PATH when launching app
  --help                 Show this help message
EOF
}

log() {
  printf '[dev-hot-restart] %s\n' "$*"
}

fail() {
  printf '[dev-hot-restart] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing command: $1"
  fi
}

resolve_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$script_dir/.." && pwd)"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --paths)
        WATCH_PATHS="$2"
        shift 2
        ;;
      --debounce)
        DEBOUNCE="$2"
        shift 2
        ;;
      --app-path)
        APP_PATH="$2"
        shift 2
        ;;
      --build-cmd)
        BUILD_CMD="$2"
        shift 2
        ;;
      --with-tests)
        WITH_TESTS=1
        shift
        ;;
      --socket-path)
        SOCKET_PATH="$2"
        shift 2
        ;;
      --help)
        print_usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

quit_app() {
  local existing_pids
  existing_pids="$(pgrep -x "CodeIsland" || true)"
  [[ -z "$existing_pids" ]] && return 0

  log "Stopping existing CodeIsland process(es): $existing_pids"
  local pid
  for pid in $existing_pids; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done

  local deadline all_gone
  deadline=$((SECONDS + 2))
  while ((SECONDS < deadline)); do
    all_gone=1
    for pid in $existing_pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        all_gone=0
        break
      fi
    done
    ((all_gone == 1)) && return 0
    sleep 0.1
  done

  log "SIGTERM did not stop app within 2s; escalating to SIGKILL"
  for pid in $existing_pids; do
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done

  deadline=$((SECONDS + 2))
  while ((SECONDS < deadline)); do
    all_gone=1
    for pid in $existing_pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        all_gone=0
        break
      fi
    done
    ((all_gone == 1)) && return 0
    sleep 0.1
  done

  fail "Existing CodeIsland process(es) still alive after SIGKILL; aborting restart"
}

prepare_app_bundle() {
  local executable_dir helper_source resource_bundle sparkle_source candidate nested_code
  local staging_bundle staging_contents previous_bundle sparkle_framework sparkle_version_dir
  executable_dir="$(dirname "$APP_EXECUTABLE_SOURCE")"
  helper_source="$executable_dir/codeisland-bridge"
  staging_bundle="${APP_BUNDLE%.app}.staging.$$.app"
  staging_contents="$staging_bundle/Contents"
  previous_bundle="${APP_BUNDLE%.app}.previous.$$.app"

  [[ -x "$APP_EXECUTABLE_SOURCE" ]] || {
    log "App executable not found after successful build: $APP_EXECUTABLE_SOURCE"
    return 1
  }
  [[ -x "$helper_source" ]] || {
    log "Helper executable not found after successful build: $helper_source"
    return 1
  }
  [[ -f "$REPO_ROOT/Info.plist" ]] || {
    log "Missing Info.plist: $REPO_ROOT/Info.plist"
    return 1
  }
  [[ -f "$REPO_ROOT/CodeIsland.entitlements" ]] || {
    log "Missing entitlements: $REPO_ROOT/CodeIsland.entitlements"
    return 1
  }

  sparkle_source=""
  for candidate in \
    "/Applications/CodeIsland.app/Contents/Frameworks/Sparkle.framework" \
    "$REPO_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then
      sparkle_source="$candidate"
      break
    fi
  done
  [[ -n "$sparkle_source" ]] || {
    log "Sparkle.framework not found in /Applications or SwiftPM artifacts"
    return 1
  }

  rm -rf "$staging_bundle" "$previous_bundle"
  if ! mkdir -p "$staging_contents/MacOS" "$staging_contents/Helpers" \
      "$staging_contents/Resources" "$staging_contents/Frameworks"; then
    rm -rf "$staging_bundle"
    return 1
  fi

  log "Preparing development app bundle: $APP_BUNDLE"
  cp "$APP_EXECUTABLE_SOURCE" "$staging_contents/MacOS/CodeIsland" || { rm -rf "$staging_bundle"; return 1; }
  cp "$helper_source" "$staging_contents/Helpers/codeisland-bridge" || { rm -rf "$staging_bundle"; return 1; }
  cp "$REPO_ROOT/Info.plist" "$staging_contents/Info.plist" || { rm -rf "$staging_bundle"; return 1; }
  if [[ -f "$REPO_ROOT/Sources/CodeIsland/Resources/AppIcon.icns" ]]; then
    cp "$REPO_ROOT/Sources/CodeIsland/Resources/AppIcon.icns" "$staging_contents/Resources/AppIcon.icns" || {
      rm -rf "$staging_bundle"
      return 1
    }
  fi

  local copied_resource_bundle=0
  for resource_bundle in "$executable_dir"/*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    ditto "$resource_bundle" "$staging_contents/Resources/$(basename "$resource_bundle")" || {
      rm -rf "$staging_bundle"
      return 1
    }
    copied_resource_bundle=1
  done
  if ((copied_resource_bundle == 0)); then
    log "No SwiftPM resource bundle found beside executable: $executable_dir"
    rm -rf "$staging_bundle"
    return 1
  fi

  ditto "$sparkle_source" "$staging_contents/Frameworks/Sparkle.framework" || {
    rm -rf "$staging_bundle"
    return 1
  }
  if ! otool -l "$staging_contents/MacOS/CodeIsland" | grep -Fq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$staging_contents/MacOS/CodeIsland" || {
      rm -rf "$staging_bundle"
      return 1
    }
  fi

  xattr -cr "$staging_bundle" 2>/dev/null || true
  sparkle_framework="$staging_contents/Frameworks/Sparkle.framework"
  sparkle_version_dir="$sparkle_framework/Versions/Current"
  for nested_code in "$sparkle_version_dir"/XPCServices/*.xpc; do
    [[ -e "$nested_code" ]] || continue
    codesign --force --options runtime --sign - "$nested_code" || { rm -rf "$staging_bundle"; return 1; }
  done
  if [[ -e "$sparkle_version_dir/Autoupdate" ]]; then
    codesign --force --options runtime --sign - "$sparkle_version_dir/Autoupdate" || { rm -rf "$staging_bundle"; return 1; }
  fi
  if [[ -d "$sparkle_version_dir/Updater.app" ]]; then
    codesign --force --options runtime --sign - "$sparkle_version_dir/Updater.app" || { rm -rf "$staging_bundle"; return 1; }
  fi
  codesign --force --options runtime --sign - "$sparkle_framework" || { rm -rf "$staging_bundle"; return 1; }
  codesign --force --options runtime --sign - "$staging_contents/Helpers/codeisland-bridge" || { rm -rf "$staging_bundle"; return 1; }
  codesign --force --options runtime --entitlements "$REPO_ROOT/CodeIsland.entitlements" \
    --sign - "$staging_bundle" || { rm -rf "$staging_bundle"; return 1; }
  codesign --verify --deep --strict "$staging_bundle" || { rm -rf "$staging_bundle"; return 1; }

  if [[ -e "$APP_BUNDLE" ]]; then
    mv "$APP_BUNDLE" "$previous_bundle" || { rm -rf "$staging_bundle"; return 1; }
  fi
  if ! mv "$staging_bundle" "$APP_BUNDLE"; then
    [[ -e "$previous_bundle" ]] && mv "$previous_bundle" "$APP_BUNDLE"
    rm -rf "$staging_bundle"
    return 1
  fi
  rm -rf "$previous_bundle"
}

launch_app() {
  if [[ -n "$SOCKET_PATH" ]]; then
    log "Launching app with CODEISLAND_SOCKET_PATH=$SOCKET_PATH"
    open -n --env "CODEISLAND_SOCKET_PATH=$SOCKET_PATH" "$APP_BUNDLE"
  else
    log "Launching app: $APP_BUNDLE"
    open -n "$APP_BUNDLE"
  fi
}

run_build_pipeline() {
  log "Building: $BUILD_CMD"
  # shellcheck disable=SC2206
  local build_cmd_parts=( $BUILD_CMD )
  if ((${#build_cmd_parts[@]} == 0)); then
    return 1
  fi
  if ! "${build_cmd_parts[@]}"; then
    return 1
  fi

  if ((WITH_TESTS == 1)); then
    log "Running tests: swift test"
    swift test
  fi
}

collect_watch_args() {
  IFS=',' read -r -a WATCH_ARRAY <<<"$WATCH_PATHS"
  WATCH_ARGS=()
  for raw in "${WATCH_ARRAY[@]}"; do
    local trimmed
    trimmed="${raw## }"
    trimmed="${trimmed%% }"
    [[ -z "$trimmed" ]] && continue

    local full_path="$REPO_ROOT/$trimmed"
    if [[ -e "$full_path" ]]; then
      WATCH_ARGS+=("$full_path")
    else
      log "Skip missing watch path: $trimmed"
    fi
  done

  if ((${#WATCH_ARGS[@]} == 0)); then
    fail "No valid watch paths left. Use --paths to configure existing paths."
  fi
}

start_watcher() {
  if command -v fswatch >/dev/null 2>&1; then
    log "Watcher: fswatch"
    fswatch -0 --event Created --event Updated --event Removed --event Renamed "${WATCH_ARGS[@]}" | while IFS= read -r -d '' _event; do
      printf '.' >>"$EVENT_FILE"
    done &
    WATCHER_PID=$!
    return
  fi

  require_command python3
  log "Watcher: Python3 polling (fswatch not found)"
  python3 - "$EVENT_FILE" "${WATCH_ARGS[@]}" <<'PY' &
import os
import sys
import time


def snapshot(paths):
    result = {}
    for path in paths:
        if os.path.isdir(path):
            for root, _, files in os.walk(path):
                for name in files:
                    file_path = os.path.join(root, name)
                    try:
                        stat = os.stat(file_path)
                    except OSError:
                        continue
                    result[file_path] = (stat.st_mtime_ns, stat.st_size)
        else:
            try:
                stat = os.stat(path)
            except OSError:
                continue
            result[path] = (stat.st_mtime_ns, stat.st_size)
    return result


# 每轮比较文件路径、纳秒修改时间和大小，批次变化写入一个事件。
event_file, *watch_paths = sys.argv[1:]
previous = snapshot(watch_paths)
with open(event_file, "ab", buffering=0) as events:
    while True:
        time.sleep(0.2)
        current = snapshot(watch_paths)
        if current != previous:
            events.write(b".")
            previous = current
PY
  WATCHER_PID=$!
}

wait_for_quiet_window() {
  while true; do
    local before after
    before=$(wc -c <"$EVENT_FILE")
    sleep "$DEBOUNCE"
    after=$(wc -c <"$EVENT_FILE")
    if [[ "$before" == "$after" ]]; then
      return
    fi
  done
}

cleanup() {
  if [[ -n "${WATCHER_PID:-}" ]]; then
    kill "$WATCHER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$EVENT_FILE"
}

main() {
  parse_args "$@"
  resolve_repo_root

  cd "$REPO_ROOT"

  require_command swift
  require_command pgrep
  require_command open
  require_command ditto
  require_command otool
  require_command install_name_tool
  require_command codesign
  if ! command -v fswatch >/dev/null 2>&1; then
    require_command python3
  fi

  if [[ "$APP_PATH" != /* ]]; then
    APP_PATH="$REPO_ROOT/${APP_PATH#./}"
  fi
  if [[ "$APP_PATH" == *.app ]]; then
    APP_BUNDLE="$APP_PATH"
    APP_EXECUTABLE_SOURCE="$(dirname "$APP_PATH")/CodeIsland"
  else
    APP_EXECUTABLE_SOURCE="$APP_PATH"
    APP_BUNDLE="$(dirname "$APP_PATH")/CodeIsland.app"
  fi

  collect_watch_args

  log "Watching paths: ${WATCH_ARGS[*]}"
  log "Debounce: ${DEBOUNCE}s"
  log "Build command: $BUILD_CMD"
  ((WITH_TESTS == 1)) && log "Test gate enabled"

  # 首次启动也执行完整构建门禁；构建或 bundle 准备失败均不影响当前实例。
  if ! run_build_pipeline; then
    fail "Initial build failed; keeping current app instance running"
  fi
  if ! prepare_app_bundle; then
    fail "Initial app bundle preparation failed; keeping current app instance running"
  fi

  log "Initial build and app bundle preparation succeeded"
  quit_app
  launch_app
  log "Initial launch complete"

  EVENT_FILE="$(mktemp -t codeisland-hot-restart-events)"
  trap cleanup EXIT INT TERM
  start_watcher

  local seen latest_before_build latest_after_build
  seen=$(wc -c <"$EVENT_FILE")

  while true; do
    latest_before_build=$(wc -c <"$EVENT_FILE")
    if [[ "$latest_before_build" == "$seen" ]]; then
      sleep 0.2
      continue
    fi

    wait_for_quiet_window
    latest_before_build=$(wc -c <"$EVENT_FILE")

    if run_build_pipeline; then
      log "Build succeeded"
      if prepare_app_bundle; then
        log "App bundle preparation succeeded"
        quit_app
        launch_app
        log "Restart complete"
      else
        log "App bundle preparation failed; keeping current app instance running"
      fi
    else
      log "Build failed; keeping current app instance running"
    fi

    latest_after_build=$(wc -c <"$EVENT_FILE")
    if [[ "$latest_after_build" != "$latest_before_build" ]]; then
      log "Detected new changes during build/restart; running next build cycle"
      continue
    fi

    seen="$latest_after_build"
  done
}

main "$@"
