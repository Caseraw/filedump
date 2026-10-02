#!/bin/bash
set -euo pipefail

# Array of iDRAC IP addresses to configure
IDRAC_IPS=(
  "xxx.xxx.xxx.xxx"
  "xxx.xxx.xxx.xxx"
)

IDRAC_USER="USER"
IDRAC_PASS="PASS"
ISO_URL="http://xxx.xxx.xxx.xxx/rhel-10.2-x86_64-boot.iso"

# Polling configuration (tries 15 times, 2s apart = 30s timeout per step)
MAX_RETRIES=15
RETRY_INTERVAL=2

# Helper function for Redfish API requests
redfish_req() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [ -n "$data" ]; then
    curl -s -k -u "${IDRAC_USER}:${IDRAC_PASS}" \
      -X "$method" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "https://${IDRAC_IP}${path}"
  else
    curl -s -k -u "${IDRAC_USER}:${IDRAC_PASS}" \
      -X "$method" \
      -H "Content-Type: application/json" \
      "https://${IDRAC_IP}${path}"
  fi
}

# Arrays to track execution results
SUCCESSFUL_NODES=()
FAILED_NODES=()

echo "=== Starting Verified iDRAC Virtual Media Boot Workflow (${#IDRAC_IPS[@]} Hosts) ==="

for IDRAC_IP in "${IDRAC_IPS[@]}"; do
  echo ""
  echo "=================================================="
  echo " Processing iDRAC: ${IDRAC_IP}"
  echo "=================================================="

  # Execute workflow in a subshell to isolate errors per host
  if (
    set -e

    # 0. Sanity Check: Verify API Reachability
    echo "[0/4] Checking iDRAC Redfish API connection..."
    HTTP_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -u "${IDRAC_USER}:${IDRAC_PASS}" \
      "https://${IDRAC_IP}/redfish/v1/Managers/iDRAC.Embedded.1")

    if [ "$HTTP_STATUS" -ne 200 ]; then
      echo "ERROR: Unable to reach iDRAC API (HTTP $HTTP_STATUS). Check network or credentials."
      exit 1
    fi
    echo "  -> API connection verified."

    # 1. Eject Media & Verify Unmounted State
    echo "[1/4] Ejecting existing virtual media..."
    redfish_req POST "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" '{}' > /dev/null

    EJECTED=false
    for ((i=1; i<=MAX_RETRIES; i++)); do
      RES=$(redfish_req GET "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD")
      INSERTED=$(echo "$RES" | jq -r '.Inserted // false')
      IMAGE=$(echo "$RES" | jq -r '.Image // empty')

      if [ "$INSERTED" = "false" ] || [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ]; then
        EJECTED=true
        break
      fi
      sleep "$RETRY_INTERVAL"
    done

    if [ "$EJECTED" = "false" ]; then
      echo "ERROR: Timed out waiting for virtual media to eject."
      exit 1
    fi
    echo "  -> Virtual media ejected successfully."

    # 2. Insert ISO & Verify Active Mount
    echo "[2/4] Attaching ISO: ${ISO_URL}"
    redfish_req POST "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" \
      "{\"Image\": \"${ISO_URL}\", \"Inserted\": true}" > /dev/null

    MOUNTED=false
    for ((i=1; i<=MAX_RETRIES; i++)); do
      RES=$(redfish_req GET "/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD")
      INSERTED=$(echo "$RES" | jq -r '.Inserted // false')
      IMAGE=$(echo "$RES" | jq -r '.Image // empty')

      if [ "$INSERTED" = "true" ] && [ "$IMAGE" = "$ISO_URL" ]; then
        MOUNTED=true
        break
      fi
      sleep "$RETRY_INTERVAL"
    done

    if [ "$MOUNTED" = "false" ]; then
      echo "ERROR: ISO failed to attach properly within timeout."
      echo "Last Redfish response: $RES"
      exit 1
    fi
    echo "  -> ISO successfully mounted and verified."

    # 3. Set Boot Override & Verify Applied Configuration
    echo "[3/4] Configuring one-time boot override to Virtual CD (Cd)..."
    redfish_req PATCH "/redfish/v1/Systems/System.Embedded.1" \
      '{"Boot": {"BootSourceOverrideTarget": "Cd", "BootSourceOverrideEnabled": "Once"}}' > /dev/null

    BOOT_SET=false
    for ((i=1; i<=MAX_RETRIES; i++)); do
      RES=$(redfish_req GET "/redfish/v1/Systems/System.Embedded.1")
      TARGET=$(echo "$RES" | jq -r '.Boot.BootSourceOverrideTarget // empty')
      ENABLED=$(echo "$RES" | jq -r '.Boot.BootSourceOverrideEnabled // empty')

      if [ "$TARGET" = "Cd" ] && [ "$ENABLED" = "Once" ]; then
        BOOT_SET=true
        break
      fi
      sleep "$RETRY_INTERVAL"
    done

    if [ "$BOOT_SET" = "false" ]; then
      echo "ERROR: Boot override configuration failed to apply."
      exit 1
    fi
    echo "  -> Boot override verified: Target=Cd, Mode=Once."

    # 4. Determine Power State & Trigger Reset/Power-On
    echo "[4/4] Checking current power state and powering on/rebooting..."

    POWER_STATE=$(redfish_req GET "/redfish/v1/Systems/System.Embedded.1" | jq -r '.PowerState // empty')
    echo "  -> Current server power state: ${POWER_STATE}"

    case "$POWER_STATE" in
      "Off")
        RESET_TYPE="On"
        ;;
      "On")
        RESET_TYPE="ForceRestart"
        ;;
      *)
        echo "  -> Server in transitional state (${POWER_STATE}), waiting 5 seconds..."
        sleep 5
        RESET_TYPE="PowerCycle"
        ;;
    esac

    echo "  -> Executing action: ${RESET_TYPE}..."
    RESET_RESPONSE=$(curl -s -k -w "\n%{http_code}" -u "${IDRAC_USER}:${IDRAC_PASS}" \
      -X POST "https://${IDRAC_IP}/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset" \
      -H "Content-Type: application/json" \
      -d "{\"ResetType\": \"${RESET_TYPE}\"}")

    HTTP_CODE=$(echo "$RESET_RESPONSE" | tail -n 1)

    if [[ "$HTTP_CODE" =~ ^(200|204)$ ]]; then
      echo "  -> Power action (${RESET_TYPE}) acknowledged by iDRAC (HTTP $HTTP_CODE)."
    else
      echo "ERROR: Failed to reset/power on system (HTTP $HTTP_CODE)."
      echo "Response details: $(echo "$RESET_RESPONSE" | head -n -1)"
      exit 1
    fi

    echo "=== Completed workflow for ${IDRAC_IP} ==="
  ); then
    SUCCESSFUL_NODES+=("$IDRAC_IP")
  else
    FAILED_NODES+=("$IDRAC_IP")
  fi
done

# Final Summary Report
echo ""
echo "=================================================="
echo "                 SUMMARY REPORT                   "
echo "=================================================="
echo " Successful (${#SUCCESSFUL_NODES[@]}): ${SUCCESSFUL_NODES[*]:-None}"
echo " Failed     (${#FAILED_NODES[@]}): ${FAILED_NODES[*]:-None}"
echo "=================================================="

# Exit with non-zero code if any host failed
if [ ${#FAILED_NODES[@]} -gt 0 ]; then
  exit 1
fi