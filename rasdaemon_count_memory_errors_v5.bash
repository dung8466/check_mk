#!/bin/bash

# Define the CheckMK plugin output header
echo "<<<local>>>"

# Function to check RAM ECC error counts using ras-mc-ctl --error-count
check_ecc_errors_ras_mc_ctl() {
    local status_cpu0=0
    local status_cpu1=0
    local message_cpu0=""
    local message_cpu1=""

    # Run the ras-mc-ctl --error-count command and parse the output
    error_count_output=$(ras-mc-ctl --error-count 2>/dev/null)
    if [[ $? -ne 0 || "$error_count_output" == *"No DIMMs found"* ]]; then
        check_overall_memory_errors
        return
    fi

    # Parse the output
    while IFS= read -r line; do
        [[ "$line" == Label* ]] && continue  # Skip the header line

        label=$(awk '{print $1}' <<< "$line")
        ce_count=$(awk '{print $2}' <<< "$line")
        ue_count=$(awk '{print $3}' <<< "$line")

        # Assign status and message for each CPU
        if [[ "$label" == CPU_SrcID#0* ]]; then
            (( ce_count > 64 || ue_count > 0 )) && status_cpu0=2
            message_cpu0+="${message_cpu0:+, }$label CE=$ce_count UE=$ue_count"
        elif [[ "$label" == CPU_SrcID#1* ]]; then
            (( ce_count > 64 || ue_count > 0 )) && status_cpu1=2
            message_cpu1+="${message_cpu1:+, }$label CE=$ce_count UE=$ue_count"
        fi
    done <<< "$error_count_output"

    echo "$status_cpu0 Memory_ECC_Errors_Counter_CPU#0 - ${message_cpu0:-No ECC Errors Detected}"
    echo "$status_cpu1 Memory_ECC_Errors_Counter_CPU#1 - ${message_cpu1:-No ECC Errors Detected}"
}

# Function to check RAM ECC error counts using the sysfs method
check_ecc_errors_sysfs() {
    local status=0
    local dimms_data_cpu0=""
    local dimms_data_cpu1=""
    local fallback_to_overall_errors=false

    # Ensure sysfs directory exists
    if [[ ! -d /sys/devices/system/edac/mc ]]; then
        echo "3 Memory_ECC_Errors_Counter - EDAC sysfs not available"
        check_overall_memory_errors
        return
    fi

    # Iterate over all DIMMs
    for label_file in /sys/devices/system/edac/mc/mc*/dimm*/dimm_label; do
        if [[ ! -f "$label_file" ]]; then
            echo "3 Memory_ECC_Errors_Counter - DIMM label file not found: $label_file"
            fallback_to_overall_errors=true
            break
        fi

        label=$(<"$label_file")
        ce_count=0
        ue_count=0

        # Check for existence of CE and UE count files
        if [[ ! -f "${label_file/dimm_label/dimm_ce_count}" || ! -f "${label_file/dimm_label/dimm_ue_count}" ]]; then
            fallback_to_overall_errors=true
            break
        fi

        ce_count=$(<"${label_file/dimm_label/dimm_ce_count}")
        ue_count=$(<"${label_file/dimm_label/dimm_ue_count}")

        # Collect messages for CPUs
        if [[ "$label" == *SrcID#0* ]]; then
            dimms_data_cpu0+="${dimms_data_cpu0:+, }$label CE=$ce_count UE=$ue_count"
        elif [[ "$label" == *SrcID#1* ]]; then
            dimms_data_cpu1+="${dimms_data_cpu1:+, }$label CE=$ce_count UE=$ue_count"
        fi

        # Set appropriate status
        (( ce_count > 64 || ue_count > 0 )) && status=2
        (( ce_count >= 8 && ce_count <= 63 && status < 2 )) && status=1
    done

    # Fallback to check_overall_memory_errors if critical files are missing
    if [[ "$fallback_to_overall_errors" == true ]]; then
        check_overall_memory_errors
        return
    fi

    # Output the status and messages
    echo "$status Memory_ECC_Errors_Counter_CPU#0 - ${dimms_data_cpu0:-No ECC Errors Detected}"
    echo "$status Memory_ECC_Errors_Counter_CPU#1 - ${dimms_data_cpu1:-No ECC Errors Detected}"
}

# Function to check for overall errors using ras-mc-ctl --errors
check_overall_memory_errors() {
    if ! command -v ras-mc-ctl &>/dev/null; then
        echo "3 Memory_Total_Errors_Counter - ras-mc-ctl command not found"
        return
    fi

    errors_output=$(ras-mc-ctl --errors 2>/dev/null)
    if [[ $? -ne 0 || -z "$errors_output" ]]; then
        echo "3 Memory_Total_Errors_Counter - Failed to retrieve memory errors"
        return
    fi

    if grep -q "No Memory errors" <<< "$errors_output"; then
        echo "0 Memory_Total_Errors_Counter - No Total Errors Detected"
        return
    fi

    # Handle case 1: "Memory controller events" with detailed logs
    if grep -q "memory read error at unknown memory location" <<< "$errors_output"; then
        error_count=$(echo "$errors_output" | grep -c "memory read error at unknown memory location")
        echo "2 Memory_Total_Errors_Counter - Errors Detected: Memory controller events summary found $error_count memory read error(s) at unknown memory location"
        return
    fi

    # Handle case 2: "Memory controller events summary" with DIMM labels
    if grep -q "Corrected on DIMM Label(s):" <<< "$errors_output"; then
        formatted_errors=$(echo "$errors_output" | awk -F"Corrected on DIMM Label\\(s\\):" '
            /Corrected on DIMM Label\(s\)/ {
                gsub(/errors:/, "", $2);
                gsub(/location:.*/, "", $2);
                printf "corrected on DIMM Label(s): %s errors: %s | ", $2, $3
            }' | sed 's/| $//') # Remove trailing separator
        echo "2 Memory_Total_Errors_Counter - Errors Detected: Memory controller events summary found $formatted_errors"
        return
    fi

    # Default case if none of the above formats match
    echo "3 Memory_Total_Errors_Counter - Unknown error format detected"
}

# Main Logic: Determine available methods and check memory errors
if command -v ras-mc-ctl &>/dev/null && ras-mc-ctl --help | grep -q -- "--error-count"; then
    check_ecc_errors_ras_mc_ctl
elif [[ -d /sys/devices/system/edac/mc ]]; then
    check_ecc_errors_sysfs
else
    check_overall_memory_errors
fi
