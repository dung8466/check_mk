#!/bin/bash

# Define the CheckMK plugin output header
echo "<<<local>>>"

# Function to get RAID details for a specific array
get_raid_details() {
    local array=$1

    # Get RAID level
    raid_level=$(mdadm --detail $array | grep -E "Raid Level" | awk '{print $4}')
    
    # Check if RAID level is "container"
    if [ "$raid_level" == "container" ]; then
        echo -e "0 RAID_mdadm_cluster_info_${array} - ${array} is a parent raid container (skipping check health and disk member status)"
        return
    fi
    
    # Get RAID health State
    raid_health=$(mdadm --detail $array | grep -E "State :" | awk '{print $3, $4, $5}')

    # Get number of RAID devices and total devices
    raid_devices=$(mdadm --detail $array | grep -E "Raid Devices" | awk '{print $4}')
    total_devices=$(mdadm --detail $array | grep -E "Total Devices" | awk '{print $4}')

    # Check if "degraded" or "recovering" is present in the state
    degraded=$(echo "$raid_health" | grep -i "degraded")
    recovering=$(echo "$raid_health" | grep -i "recovering")

    # Determine the status code based on the health state
    if [ -n "$degraded" ] && [ -n "$recovering" ]; then
        status_code=1  # Warning if both degraded and recovering
    elif [ -n "$degraded" ]; then
        status_code=2  # Critical if degraded
    else
        status_code=0  # OK if neither degraded nor recovering
    fi

	# Output RAID level, number of devices, and health status
    echo -e "$status_code RAID_mdadm_cluster_info_${array} - RAID level: $raid_level, Health State: $raid_health"

    # Check if the number of total devices is smaller than the number of raid devices
    if [ "$total_devices" -lt "$raid_devices" ]; then
        echo -e "2 RAID_devices_info_${array} - RAID cluster is missing members. Total Member Devices: $total_devices, Raid Devices: $raid_devices"
    else
        echo -e "0 RAID_devices_info_${array} - Number of members in RAID cluster is normal. Total Member Devices: $total_devices, Raid Devices: $raid_devices"
    fi

    # Get rebuild status if applicable
    rebuild_status=$(mdadm --detail $array | grep -i "Rebuild Status" | awk -F ': ' '{print $2}')

    finish_rebuild_time=$(grep -E "finish" /proc/mdstat | awk '{for (i=1; i<=NF; i++) if ($i ~ /finish=/) {gsub(/=/, " = ", $i); gsub(/min/, " min", $i); print $i}}')

    # Output rebuild status if present
    if [ -n "$rebuild_status" ]; then
        echo -e "1 RAID_${array}_rebuild_status - Rebuild in progress: $rebuild_status - $finish_rebuild_time"
    fi

    # Check disk device health states
    check_disk_status $array  
}

# Function to check the status of each disk in a RAID array
check_disk_status() {
    local array=$1

    # Use mdadm to get details of the RAID array
    mdadm_output=$(mdadm --detail $array)

    # Extract the list of devices and their status
    devices=$(echo "$mdadm_output" | grep -E "/dev/sd*")

    # Loop through each device and report its status
    while IFS= read -r device; do
        device_name=$(echo "$device" | awk '{print $7}')
        device_status=$(echo "$device" | awk '{print $5}')

        case $device_status in
            active)
                echo -e "0 RAID_member_info_$device_name - disk $device_name is member in RAID array $array - status: active sync"
                ;;
            spare)
                echo -e "1 RAID_member_info_$device_name - disk $device_name is member in RAID array $array - status: spare rebuilding"
                ;;
            faulty|removed)
                echo -e "2 RAID_member_info_$device_name - disk $device_name is member in RAID array $array - status: $device_status"
                ;;
            *)
                echo -e "3 RAID_member_info_$device_name - disk $device_name is member in RAID array $array - status: unknown"
                ;;
        esac
    done <<< "$devices"
}

# Scan for RAID arrays using /proc/mdstat
arrays=$(cat /proc/mdstat | grep active | grep -o 'md[0-9]*')

# If no RAID arrays found, exit with an appropriate message
if [ -z "$arrays" ]; then
    echo -e "0 RAID_mdadm_cluster_info - No RAID mdadm cluster founded in server"
    exit 0
fi

# Loop through each RAID array and gather details
for array in $arrays; do
    get_raid_details /dev/$array
done
