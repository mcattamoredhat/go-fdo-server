#! /usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/../ci/test-fsim-wget.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/utils.sh"

# Override configure_service_owner to use the RPM systemd service paths while
# preserving the fdo.wget FSIM configuration defined in test-fsim-wget.sh.
# test/rpm/utils.sh's generic configure_service_owner overwrites the ci version
# and strips out the service_info block, so we redefine it here (last wins).
configure_service_owner() {
  sudo rm -rf "${rpm_owner_home_dir:?}"
  sudo mkdir -p "${rpm_owner_config_dir}" # creates home dir
  cat >"${owner_config_file}" <<EOF
log:
  level: "debug"
db:
  type: "${rpm_owner_db_type}"
  dsn: "${rpm_owner_db_dsn}"
device_ca:
  cert: "${rpm_owner_home_dir}/device_ca.crt"
owner:
  cert: "${rpm_owner_home_dir}/owner.crt"
  key: "${rpm_owner_home_dir}/owner.key"
  reuse_credentials: "${owner_reuse_creds}"
  to0_insecure_tls: "${owner_to0_insecure_tls}"
  service_info:
    fsims:
      - fsim: "fdo.wget"
        params:
          files:
            - url: "${wget_source_url1}"
              dst: "${wget_device_download_relative_file}"
            - url: "${wget_source_url2}"
              dst: "${wget_device_download_absolute_file}"
            - url: "${wget_source_url3}"
http:
  ip: "${owner_dns}"
  port: "${owner_port}"
EOF
  sudo cp "${owner_config_file}" "${rpm_owner_config_file}"
  sudo cp "${device_ca_crt}" "${rpm_owner_home_dir}"
  sudo cp "${owner_crt}" "${owner_key}" "${rpm_owner_home_dir}"
  sudo chown -R ${rpm_owner_user}:${rpm_server_group} ${rpm_owner_home_dir}
}

# Override start_service_wget_httpd to evict any stale server from a prior
# run that may still be bound to the port before launching the new one.
# Without this the new python3 process fails to bind, dies immediately, its
# PID is recorded in the pid file, and the stale server keeps serving – so
# stop_service_wget_httpd kills the already-dead new process and leaves the
# stale server running.
start_service_wget_httpd() {
  # Kill any process already bound to the wget_httpd port
  local stale_pid
  stale_pid=$(ss -tlnpH "sport = :${wget_httpd_port}" 2>/dev/null \
    | grep -oP 'pid=\K[0-9]+' | head -1 || true)
  if [[ -n "${stale_pid}" ]]; then
    kill -9 "${stale_pid}" 2>/dev/null || true
    sleep 1
  fi
  # Start Python HTTP server in background (same as ci version)
  cd "${wget_httpd_dir}"
  nohup python3 -m http.server ${wget_httpd_port} >"${wget_httpd_log_file}" 2>&1 &
  echo -n $! >"${wget_httpd_pid_file}"
  cd - >/dev/null
}

# test/rpm/utils.sh defines stop_service() to dispatch to stop_service_<name>.
# It provides stop_service_{manufacturer,rendezvous,owner} via systemctl, but
# has no entry for wget_httpd (a plain Python process managed by PID file).
# Without this function stop_service wget_httpd is a silent no-op in the RPM
# context, so the HTTP server stays up and the "expected failure" test passes
# instead of failing as intended.
#
# We kill both: the PID recorded in the pid file AND whatever process is
# currently bound to the wget_httpd port. The port-based kill handles the case
# where a stale server from a previous test run is still listening (the pid
# file would point to the new, already-dead process that failed to bind).
stop_service_wget_httpd() {
  local pid
  # Kill by PID file
  if [[ -f "${wget_httpd_pid_file}" ]]; then
    pid=$(cat "${wget_httpd_pid_file}")
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      local i
      for i in $(seq 1 5); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
      done
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi
  # Also kill any process still bound to the wget_httpd port (handles stale
  # servers from prior runs whose PID was not recorded in the current pid file)
  local port_pid
  port_pid=$(ss -tlnpH "sport = :${wget_httpd_port}" 2>/dev/null \
    | grep -oP 'pid=\K[0-9]+' | head -1 || true)
  if [[ -n "${port_pid}" ]]; then
    kill "${port_pid}" 2>/dev/null || true
    local i
    for i in $(seq 1 5); do
      kill -0 "${port_pid}" 2>/dev/null || break
      sleep 1
    done
    kill -9 "${port_pid}" 2>/dev/null || true
  fi
}

# Override run_test to ensure all required directories exist.
# test/rpm/utils.sh re-sources test/ci/utils.sh which resets the 'directories'
# array via 'declare -a directories=(...)'. This wipes entries added at source
# time by test-fsim-config.sh (tmp_dir) and means pid_dir is never created
# (start_service_wget_httpd writes directly to ${pid_dir}/http_server.pid
# without a mkdir -p guard, unlike run_go_fdo_server).
run_test() {
  # Add the wget_httpd service defined above
  services+=("${wget_httpd_service_name}")

  log_info "Setting the error trap handler"
  trap on_failure ERR

  log_info "Environment variables"
  show_env

  log_info "Creating directories"
  # Re-add tmp_dir (wiped by declare -a reset, needed for TMPDIR / go-fdo-client
  # temp files) and pid_dir (needed by start_service_wget_httpd which writes the
  # PID file without its own mkdir -p).
  directories+=("${tmp_dir}" "${pid_dir}" "${wget_httpd_dir}" "${wget_device_download_absolute_dir}")
  create_directories

  log_info "Generating service certificates"
  generate_service_certs

  log_info "Build and install 'go-fdo-client' binary"
  install_client

  log_info "Build and install 'go-fdo-server' binary"
  install_server

  log_info "Configuring services"
  configure_services

  log_info "Start services"
  start_services

  log_info "Wait for the services to be ready:"
  wait_for_services_ready

  log_info "Prepare the wget test payload file on server side: '${wget_source_file1}', '${wget_source_file2}'"
  prepare_payload "${wget_source_file1}"
  prepare_payload "${wget_source_file2}"
  prepare_payload "${wget_source_file3}"

  log_info "Setting or updating Rendezvous Info (RendezvousInfo)"
  set_or_update_rendezvous_info "${manufacturer_url}" "${rv_info}"

  log_info "Adding Device CA certificate to rendezvous"
  add_device_ca_cert "${rendezvous_url}" "${device_ca_crt}" | jq -r -M .

  log_info "Run Device Initialization"
  guid=$(run_device_initialization)
  log_info "Device initialized with GUID: ${guid}"

  log_info "Setting or updating Owner Redirect Info (RVTO2Addr)"
  set_or_update_owner_redirect_info "${owner_url}" "${owner_service_name}" "${owner_dns}" "${owner_port}" "${owner_protocol}"

  log_info "Sending Device Ownership Voucher to the Owner"
  send_manufacturer_ov_to_owner "${manufacturer_url}" "${guid}" "${owner_url}"

  log_info "Stop HTTP Server to Simulate Loss of WGET Service"
  stop_service "${wget_httpd_service_name}"

  log_info "Attempt WGET with missing HTTP server, verify FSIM error occurs"
  ! run_fido_device_onboard "${guid}" --debug ||
    log_error "Expected Device onboard to fail!"

  log_info "Verifying the error was logged"
  # verify that the wget FSIM error is logged
  find_in_log "$(get_device_onboard_log_file_path "${guid}")" "error handling device service info .*fdo\.wget:error" ||
    log_error "The corresponding error was not logged"

  # Verify that Device can successfully onboard once the HTTP server is available
  log_info "Restarting HTTP Server"
  start_service "${wget_httpd_service_name}"
  wait_for_service_ready "${wget_httpd_service_name}"

  log_info "Re-running FIDO Device Onboard with FSIM fdo.wget"
  run_fido_device_onboard "${guid}" --debug

  # Note: go-fdo-client onboard executes in the ${credentials_dir} directory, expect
  # to find the relative pathnamed files there:
  log_info "Verify downloaded file ${credentials_dir}/${wget_device_download_relative_file}"
  verify_equal_files "${wget_source_file1}" "${credentials_dir}/${wget_device_download_relative_file}"

  log_info "Verify downloaded file ${wget_device_download_absolute_file}"
  verify_equal_files "${wget_source_file2}" "${wget_device_download_absolute_file}"

  log_info "Verify downloaded file ${credentials_dir}/${wget_file3_name}"
  verify_equal_files "${wget_source_file3}" "${credentials_dir}/${wget_file3_name}"

  log_info "Unsetting the error trap handler"
  trap - ERR
  test_pass
}

# Allow running directly
[[ "${BASH_SOURCE[0]}" != "$0" ]] || {
  run_test
  cleanup
}
