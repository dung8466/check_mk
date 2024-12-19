#!/bin/bash

# Define the CheckMK plugin output header
echo "<<<local>>>"

# List of SMART attributes and their corresponding IDs for critical alerts
declare -A critical_attributes=(
    [1]="Raw_Read_Error_Rate"
    [3]="Spin_Up_Time"
    [5]="Reallocated_Sector_Ct"
    [7]="Seek_Error_Rate"
    [8]="Seek_Time_Performance"
    [10]="Spin_Retry_Count"
    [184]="End-to-End_Error"
    [187]="Reported_Uncorrect"
    [188]="Command_Timeout"
    [196]="Reallocated_Event_Count"
    [197]="Current_Pending_Sector"
    [198]="Offline_Uncorrectable_Sector_Count"
)

# List of SMART attributes and their corresponding IDs for warning alerts
declare -A warning_attributes=(
    [189]="High_Fly_Writes"
    [191]="G-Sense_Error_Rate"
    [195]="Hardware_ECC_Recovered"
    [199]="UDMA_CRC_Error_Count"
    [200]="Multi_Zone_Error_Rate"
)

# Function to convert power-on hours to years and days
convert_hours_to_years_days() {
    local hours=$1
    local years=$((hours / 8760))
    local days=$(( (hours % 8760) / 24 ))
    echo "$years years and $days days"
}

# Function to convert total LBAs written to GB
convert_lbas_to_gb() {
    local lbas=$1
    local sectors_per_lba=512
    local bytes=$((lbas * sectors_per_lba))
    local gb=$((bytes / 1024 / 1024 / 1024))
    echo "$gb"
}

# Function to convert detailed Power_On_Hours to plain hours
convert_detailed_hours_to_plain() {
    local detailed_hours=$1
    local hours=$(echo "$detailed_hours" | awk -F'[hms+]' '{print $1}')
    local minutes=$(echo "$detailed_hours" | awk -F'[hms+]' '{print $2}')
    local seconds=$(echo "$detailed_hours" | awk -F'[hms+]' '{print $3}')
    hours=${hours:-0}
    minutes=${minutes:-0}
    seconds=${seconds:-0}
    echo $(echo "$hours + ($minutes / 60) + ($seconds / 3600)" | bc -l | awk '{print int($1)}')
}

# Function to calculate health using the hdsentinel-vccorp-mixing method

calculate_health_strict() {
    local health=100
    local reallocated_sectors=${1:-0}
    local seek_error_rate=${2:-0}
    local spin_retry_count=${3:-0}
    local reallocation_event_count=${4:-0}
    local pending_sectors=${5:-0}
    local offline_uncorrectable=${6:-0}

    # Define maximum limits for each SMART attribute
    local max_reallocated_sectors=70
    local max_seek_error_rate=20
    local max_spin_retry_count=60
    local max_reallocation_event_count=30
    local max_pending_sectors=48
    local max_offline_uncorrectable=70

    # Cap each SMART attribute value at its limit
    reallocated_sectors=$(( reallocated_sectors > max_reallocated_sectors ? max_reallocated_sectors : reallocated_sectors ))
    seek_error_rate=$(( seek_error_rate > max_seek_error_rate ? max_seek_error_rate : seek_error_rate ))
    spin_retry_count=$(( spin_retry_count > max_spin_retry_count ? max_spin_retry_count : spin_retry_count ))
    reallocation_event_count=$(( reallocation_event_count > max_reallocation_event_count ? max_reallocation_event_count : reallocation_event_count ))
    pending_sectors=$(( pending_sectors > max_pending_sectors ? max_pending_sectors : pending_sectors ))
    offline_uncorrectable=$(( offline_uncorrectable > max_offline_uncorrectable ? max_offline_uncorrectable : offline_uncorrectable ))

    # Reallocated Sectors Count
    health=$(echo "$health * (100 - $reallocated_sectors * 4) / 100" | bc -l)
    
    # Seek Error Rate
    health=$(echo "$health * (100 - $seek_error_rate * 1) / 100" | bc -l)
    
    # Spin Retry Count
    health=$(echo "$health * (100 - $spin_retry_count * 4) / 100" | bc -l)
    
    # Reallocation Event Count
    health=$(echo "$health * (100 - $reallocation_event_count * 2) / 100" | bc -l)
    
    # Current Pending Sectors Count
    health=$(echo "$health * (100 - $pending_sectors * 2) / 100" | bc -l)
    
    # Offline Uncorrectable Sectors Count
    health=$(echo "$health * (100 - $offline_uncorrectable * 4) / 100" | bc -l)

    # Round off the health value
    echo $(printf "%.0f" "$health")
}

# Function to check SMART attributes for a specific disk and calculate health
check_smart_attributes() {
    local disk=$1
    local device_type=$2

    # Determine the smartctl command based on the disk name
    if [[ "$disk" =~ ^/dev/sd[a-z] ]]; then
		smartctl_info=$(smartctl -i "$disk")
		smartctl_output=$(smartctl -A "$disk")
	elif [[ "$disk" =~ ^/dev/sg[0-9]+$ ]]; then
		smartctl_info=$(smartctl -i "$disk" -d scsi)
		smartctl_output=$(smartctl -A "$disk" -d scsi)
	else
		smartctl_info=$(smartctl -i "$disk" -d "$device_type")
		smartctl_output=$(smartctl -A "$disk" -d "$device_type")
	fi

    local status=0
    local model=""
    local serial=""
    local capacity=""
    local vendor=""
    local rotation_rate=""
    local sata_version=""
    local temperature=""
    local total_lbas_written=""
    local power_on_hours=""
    
    # Extract the model, serial number, and vendor
    model=$(echo "$smartctl_info" | grep -i "Device Model" | awk -F ':' '{print $2}' | xargs)
    serial=$(echo "$smartctl_info" | grep -i "Serial Number" | awk -F ':' '{print $2}' | xargs)
    vendor=$(echo "$smartctl_info" | grep -i "Vendor" | awk -F ':' '{print $2}' | xargs)

    # If the vendor is "LSI" or if there's no serial number, it's a RAID cluster, so skip further checks
    if [[ "$vendor" == "LSI" ]] || [[ -z "$serial" ]]; then
        echo "0 SMART_Info_Raid_LSI_Unknown - $disk is part of a RAID cluster (had vendor is LSI or no serial number). No SMART further checks needed."
        return
    fi

    # Extract disk capacity (in GB)
    capacity=$(echo "$smartctl_info" | grep -i "User Capacity" | awk -F'[][]' '{print $2}' | xargs)

    # Determine if the disk is SSD or HDD based on rotation rate
    rotation_rate=$(echo "$smartctl_info" | grep -i "Rotation Rate" | awk -F ':' '{print $2}' | xargs)
    if [[ "$rotation_rate" == *"SSD"* ]] || [[ "$rotation_rate" == *"Solid State"* ]] || [[ "$rotation_rate" == "0" ]]; then
        disk_type="SSD"
    else
        disk_type="HDD"
    fi

    # Check SATA version 
    sata_version=$(echo "$smartctl_info" | grep -i "SATA Version is" | awk -F ':' '{print $2}' | sed 's/ (current//' | xargs)

    # Check temperature
    temperature=$(echo "$smartctl_output" | awk '/Airflow_Temperature_Cel|Temperature_Celsius|Temperature/ {print $10; exit}' | xargs)

    # Check total LBAs written and convert to GB
    total_lbas_written=$(echo "$smartctl_output" | grep -i "Total_LBAs_Written" | awk '{print $10}' | xargs)
    total_lbas_written_gb=$(convert_lbas_to_gb "$total_lbas_written")
	
	# Check power-on hours and convert to plain hours
    local power_on_raw=$(echo "$smartctl_output" | grep -i "Power_On_Hours" | awk '{print $10}' | xargs)
    if [[ "$power_on_raw" =~ [0-9]+h ]]; then
        local power_on_hours=$(convert_detailed_hours_to_plain "$power_on_raw")
    else
        local power_on_hours=$power_on_raw
    fi
    local power_on_years_days=$(convert_hours_to_years_days "$power_on_hours")

    # Determine status based on power-on hours and output separately
    local power_on_years=$((power_on_hours / 8760))
    if [[ "$power_on_years" -ge 7 ]]; then
        echo "2 SMART_Info_"$disk"_$serial - Model: $model, Capacity: $capacity, Type: $disk_type, SATA Version: $sata_version, Current Temperature: ${temperature}°C, Total LBAs Written: ${total_lbas_written_gb}GB, and has been Powered on for over 7 years: $power_on_years_days."
    elif [[ "$power_on_years" -ge 5 ]]; then
        echo "1 SMART_Info_"$disk"_$serial - Model: $model, Capacity: $capacity, Type: $disk_type, SATA Version: $sata_version, Current Temperature: ${temperature}°C, Total LBAs Written: ${total_lbas_written_gb}GB, and has been Powered on for over 5 years: $power_on_years_days."
    else
        echo "0 SMART_Info_"$disk"_$serial - Model: $model, Capacity: $capacity, Type: $disk_type, SATA Version: $sata_version, Current Temperature: ${temperature}°C, Total LBAs Written: ${total_lbas_written_gb}GB, and has been Powered on for $power_on_years_days."
    fi
    
    # Tracking SMART critical and warning attributes
    while IFS= read -r line; do
        attribute_id=$(echo $line | awk '{print $1}')
        raw_value=$(echo $line | awk '{print $10}')

        # Validate that attribute_id is numeric before accessing the array
        if [[ $attribute_id =~ ^[0-9]+$ ]]; then
            # Check for critical attributes
            if [[ -n "${critical_attributes[$attribute_id]}" && "$raw_value" -gt 0 ]]; then
                attribute_name="${critical_attributes[$attribute_id]}"
                echo "2 SMART_Critical_Attributes_"$disk"_$serial - $attribute_name ($attribute_id) on $disk - $serial has raw value $raw_value."
            fi

            # Check for warning attributes
            if [[ -n "${warning_attributes[$attribute_id]}" && "$raw_value" -gt 0  ]]; then
                attribute_name="${warning_attributes[$attribute_id]}"
                echo "1 SMART_Warning_Attributes_"$disk"_$serial - $attribute_name ($attribute_id) on $disk - $serial has raw value $raw_value."
            fi
        fi

    done <<< "$(echo "$smartctl_output" | grep -E '^[ ]*[0-9]+')"

	# Get SMART attributes for calculate health
    reallocated_sectors=$(echo "$smartctl_output" | grep "Reallocated_Sector_Ct" | awk '{print $10}')
    seek_error_rate=$(echo "$smartctl_output" | grep "Seek_Error_Rate" | awk '{print $10}')
    spin_retry_count=$(echo "$smartctl_output" | grep "Spin_Retry_Count" | awk '{print $10}')
    reallocation_event_count=$(echo "$smartctl_output" | grep "Reallocation_Event_Count" | awk '{print $10}')
    pending_sectors=$(echo "$smartctl_output" | grep "Current_Pending_Sector" | awk '{print $10}')
    offline_uncorrectable=$(echo "$smartctl_output" | grep "Offline_Uncorrectable" | awk '{print $10}')

    # Ensure all attributes default to 0 if they are empty
    reallocated_sectors=${reallocated_sectors:-0}
    seek_error_rate=${seek_error_rate:-0}
    spin_retry_count=${spin_retry_count:-0}
    reallocation_event_count=${reallocation_event_count:-0}
    pending_sectors=${pending_sectors:-0}
    offline_uncorrectable=${offline_uncorrectable:-0}

    # Calculate health and output health status
    health=$(calculate_health_strict $reallocated_sectors $seek_error_rate $spin_retry_count $reallocation_event_count $pending_sectors $offline_uncorrectable)
    
    # Determine the status
    if (( $(echo "$health >= 80" | bc -l) )); then
        echo "0 SMART_Health_"$disk"_$serial - disk health is in normal state: ${health}%"
    elif (( $(echo "$health >= 65 && $health < 80" | bc -l) )); then
        echo "1 SMART_Health_"$disk"_$serial - disk health is in warning state: ${health}%"
    else
        echo "2 SMART_Health_"$disk"_$serial - disk health is in critical state: ${health}%"
    fi
}

# Ensure smartctl is available
if ! command -v smartctl &> /dev/null; then    
    echo "smartctl could not be found"
    exit 1
fi

# Get a list of all disk devices using smartctl --scan
disks=$(smartctl --scan | awk '{print $1, $2, $3}')

# Check SMART attributes for each disk
while IFS= read -r disk_line; do
    disk=$(echo $disk_line | awk '{print $1}')
    device_type=$(echo $disk_line | awk '{print $3}')
    
    if [[ -n "$device_type" ]]; then
        check_smart_attributes "$disk" "$device_type"
    else
        check_smart_attributes "$disk"
    fi
done <<< "$disks"
