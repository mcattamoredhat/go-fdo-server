#! /usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/../ci/test-fsim-upload.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/utils.sh"

# Override configure_service_owner to use the RPM systemd service paths while
# preserving the fdo.upload FSIM configuration defined in test-fsim-upload.sh.
# test/rpm/utils.sh's generic configure_service_owner overwrites the ci version
# and strips out the service_info block, so we redefine it here (last wins).
#
# The owner systemd service runs as 'go-fdo-server-owner' and cannot write to
# the test workdir under /home.  We redirect owner_uploads_dir into
# ${rpm_owner_home_dir}/fsim/upload/ so the service can write there.
# verify_uploads() will read from that location after a chmod o+rX.
configure_service_owner() {
  sudo rm -rf "${rpm_owner_home_dir:?}"
  sudo mkdir -p "${rpm_owner_config_dir}" # creates home dir

  # Redirect upload destination to service home dir (writable by service user).
  # Re-assign here so the config below and verify_uploads() pick up the new path.
  owner_uploads_dir="${rpm_owner_home_dir}/fsim/upload"
  sudo mkdir -p "${owner_uploads_dir}"

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
      - fsim: "fdo.upload"
        params:
          dir: "${owner_uploads_dir}"
          files:
            - src: "${device_files[0]}"
              dst: "${owner_files[0]}"
            - src: "${device_files[1]}"
              dst: "${owner_files[1]}"
            - src: "${device_files[2]}"
http:
  ip: "${owner_dns}"
  port: "${owner_port}"
EOF
  sudo cp "${owner_config_file}" "${rpm_owner_config_file}"
  sudo cp "${device_ca_crt}" "${rpm_owner_home_dir}"
  sudo cp "${owner_crt}" "${owner_key}" "${rpm_owner_home_dir}"
  sudo chown -R ${rpm_owner_user}:${rpm_server_group} ${rpm_owner_home_dir}
}

# Override run_test to add a chmod step after onboarding so verify_uploads()
# (running as the test user) can read files written by the service user.
run_test() {
  log_info "Setting the error trap handler"
  trap on_failure ERR

  log_info "Environment variables"
  show_env

  log_info "Creating directories"
  # tmp_dir is added to directories[] by test-fsim-config.sh at source time,
  # but test/rpm/utils.sh re-sources test/ci/utils.sh which resets the array
  # via 'declare -a directories=(...)'. Re-add it here so TMPDIR exists for
  # go-fdo-client (required to avoid cross-filesystem os.Rename failures).
  # NOTE: owner_uploads_dir is intentionally omitted here — configure_service_owner
  # reassigns it to ${rpm_owner_home_dir}/fsim/upload and creates it with sudo mkdir.
  directories+=("${tmp_dir}" "${device_uploads_subdir}")
  create_directories

  log_info "Generating service certificates"
  generate_service_certs

  log_info "Build and install 'go-fdo-client' binary"
  install_client

  log_info "Build and install 'go-fdo-server' binary"
  install_server

  log_info "Configuring services"
  configure_services

  log_info "Configure DNS and start services"
  start_services

  log_info "Wait for the services to be ready:"
  wait_for_services_ready

  log_info "Setting or updating Rendezvous Info (RendezvousInfo)"
  set_or_update_rendezvous_info "${manufacturer_url}" "${rv_info}"

  log_info "Adding Device CA certificate to rendezvous"
  add_device_ca_cert "${rendezvous_url}" "${device_ca_crt}" | jq -r -M .

  log_info "Run Device Initialization"
  guid=$(run_device_initialization)
  log_info "Device initialized with GUID: ${guid}"

  log_info "Setting or updating Owner Redirect Info (RVTO2Addr)"
  set_or_update_owner_redirect_info "${owner_url}" "${owner_service_name}" "${owner_dns}" "${owner_port}" "${owner_protocol}"

  log_info "Sending Ownership Voucher to the Owner"
  send_manufacturer_ov_to_owner "${manufacturer_url}" "${guid}" "${owner_url}"

  log_info "Prepare the upload payloads on client side: ${device_files[*]}"
  generate_upload_files

  log_info "Running FIDO Device Onboard with FSIM fdo.upload"
  run_fido_device_onboard "${guid}"

  # Make the service-owned upload directory readable by the test user
  sudo chmod -R o+rX "${owner_uploads_dir}"

  device_guid=$(get_device_guid "${owner_url}" "${guid}")
  log_info "Device GUID after onboarding: ${device_guid}"

  log_info "Verify uploaded files"
  verify_uploads "${device_guid}"

  log_info "Unsetting the error trap handler"
  trap - ERR
  test_pass
}

# Allow running directly
[[ "${BASH_SOURCE[0]}" != "$0" ]] || {
  run_test
  cleanup
}
