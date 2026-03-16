#! /usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/../ci/test-resale.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/utils.sh"

# Override run_test to inject configure_services before start_services.
# test/ci/test-resale.sh's run_test calls start_services directly (which works
# in the CI context where services are started as plain processes with all
# config passed as CLI flags). In the RPM context, manufacturer/rendezvous/owner
# are systemd services that read config files written by configure_service_*,
# so configure_services must be called first.
# new_owner is still started as a plain nohup process (no RPM systemd unit),
# so it works without configure_service_new_owner.
run_test() {
  # Add the new owner service defined above
  services+=("${new_owner_service_name}")

  log_info "Setting the error trap handler"
  trap on_failure ERR

  log_info "Environment variables"
  show_env

  log_info "Creating directories"
  create_directories

  log_info "Generating service certificates"
  generate_service_certs

  log_info "Build and install the 'go-fdo-client' binary"
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

  log_info "Sending Ownership Voucher to the Owner"
  send_manufacturer_ov_to_owner "${manufacturer_url}" "${guid}" "${owner_url}"

  log_info "Extracting the public key from the New Owner cert"
  extract_pubkey_from_cert ${new_owner_crt} ${new_owner_pub}

  log_info "Trigger the Resell protocol on the current owner"
  resell "${owner_url}" "${guid}" "${new_owner_pub}" "${new_owner_ov}"

  log_info "Setting or updating the New Owner Redirect Info (RVTO2Addr)"
  set_or_update_owner_redirect_info "${new_owner_url}" "${new_owner_service_name}" "${new_owner_dns}" "${new_owner_port}" "${new_owner_protocol}"

  log_info "Sending the Ownership Voucher to the New Owner"
  send_ov_to_owner "${new_owner_url}" "${new_owner_ov}"

  log_info "Running FIDO Device Onboard"
  run_fido_device_onboard "${guid}" --debug

  log_info "Unsetting the error trap handler"
  trap - ERR
  test_pass
}

# Allow running directly
[[ "${BASH_SOURCE[0]}" != "$0" ]] || {
  run_test
  cleanup
}
