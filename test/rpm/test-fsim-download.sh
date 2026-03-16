#! /usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/../ci/test-fsim-download.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/utils.sh"

# The owner systemd service runs as 'go-fdo-server-owner' and cannot read files
# from the test workdir under /home.  We mirror the download payload into
# ${rpm_owner_home_dir}/fsim/download/ (owned by the service user) and point the
# owner configuration there.
rpm_owner_download_dir="${rpm_owner_home_dir}/fsim/download"

# Override configure_service_owner to use RPM paths + fdo.download FSIM config.
# NOTE: generate_download_files() runs *after* configure_services() in run_test,
# so we only create the target directory here; the actual file copy is done in
# copy_download_files_to_service_dir() which is called after generate_download_files.
configure_service_owner() {
  sudo rm -rf "${rpm_owner_home_dir:?}"
  sudo mkdir -p "${rpm_owner_config_dir}" # creates home dir
  sudo mkdir -p "${rpm_owner_download_dir}/subdir"

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
      - fsim: "fdo.download"
        params:
          dir: "${rpm_owner_download_dir}"
          files:
            - src: "${owner_files[0]}"
              dst: "${device_files[0]}"
            - src: "${owner_files[1]}"
              dst: "${device_files[1]}"
            - src: "${owner_files[2]}"
              dst: "${device_files[2]}"
http:
  ip: "${owner_dns}"
  port: "${owner_port}"
EOF
  sudo cp "${owner_config_file}" "${rpm_owner_config_file}"
  sudo cp "${device_ca_crt}" "${rpm_owner_home_dir}"
  sudo cp "${owner_crt}" "${owner_key}" "${rpm_owner_home_dir}"
  sudo chown -R ${rpm_owner_user}:${rpm_server_group} ${rpm_owner_home_dir}
}

# Copy the generated download payload into the service home dir so the
# go-fdo-server-owner systemd service user can read it.
# Must be called AFTER generate_download_files() creates the source files.
copy_download_files_to_service_dir() {
  for f in "${owner_files[@]}"; do
    sudo cp "${owner_download_dir}/${f}" "${rpm_owner_download_dir}/${f}"
  done
  sudo chown -R ${rpm_owner_user}:${rpm_server_group} "${rpm_owner_download_dir}"
}

# Override run_test to insert the file-copy step between generate_download_files
# and start_services.
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
  directories+=("${tmp_dir}" "$owner_download_subdir" "$device_download_dir")
  create_directories

  log_info "Generating service certificates"
  generate_service_certs

  log_info "Build and install 'go-fdo-client' binary"
  install_client

  log_info "Build and install 'go-fdo-server' binary"
  install_server

  log_info "Configuring services"
  configure_services

  log_info "Generate the download payloads on owner side: ${owner_files[*]}"
  generate_download_files

  log_info "Copy download payloads into owner service home directory"
  copy_download_files_to_service_dir

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

  log_info "Running FIDO Device Onboard with FSIM fdo.download"
  run_fido_device_onboard "${guid}"

  log_info "Verify downloaded files"
  verify_downloads

  log_info "Unsetting the error trap handler"
  trap - ERR
  test_pass
}

# Allow running directly
[[ "${BASH_SOURCE[0]}" != "$0" ]] || {
  run_test
  cleanup
}
