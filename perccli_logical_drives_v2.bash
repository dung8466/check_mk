#!/bin/bash

# Function to check if the server is a Dell system
check_server_dell_raid_controller() {
    # Use dmidecode to get system information
    manufacturer=$(dmidecode -t system 2>/dev/null | grep -i "Manufacturer" | awk -F ':' '{print $2}' | xargs)

    # Check if the manufacturer is Dell
    if [[ "$manufacturer" == "Dell Inc." ]]; then
        check_raid_controller
    else
        echo "0 Raid_PERC_detected - No RAID PERC controller found on this server"
        exit 0
    fi
}

# Function to check if a RAID controller exists
check_raid_controller() {
    # Use lspci to search for RAID controllers
    raid_info=$(lspci | grep -i "RAID")

    if [[ -n "$raid_info" ]]; then
        check_raid_logical_drives
    else
        echo "0 Raid_PERC_detected - No RAID PERC controller found on this server"
    fi
}

# Define the local plugin check function
check_raid_logical_drives() {
    # Run perccli64 show all command and store the output
    output=$(perccli64 show all)

    # Check if the command executed successfully
    if [ $? -ne 0 ]; then
        echo "2 Raid_Logical_Drives - Error running perccli64 command"
        exit 1
    fi

    # Loop through the controllers and extract their indices
    echo "$output" | grep "^ *[0-9]" | while read -r line; do
        # Extract the controller index (Ctl field is the first number on the line)
        controller_id=$(echo "$line" | awk '{print $1}')
        model=$(echo "$line" | awk '{print $2}')

        # Check if the model is not empty before proceeding
        if [ -n "$model" ]; then
            # Fetch the logical drive information for the specific controller
            logical_drives_output=$(perccli64 /c"$controller_id" /vall show)

            # Check if the command executed successfully
            if [ $? -ne 0 ]; then
                echo "2 Raid_Logical_Drives_c$controller_id - Error fetching logical drives for Controller ID: $controller_id"
                continue
            fi

            # Parse the logical drives status
            echo "$logical_drives_output" | grep -A 20 "Virtual Drives :" | grep -v "Cac=CacheCade" | grep -v "^--" | grep -v "Virtual Drives :" | grep -v "^$" | while read -r line; do
                vd_id=$(echo "$line" | awk '{print $1}')
                state=$(echo "$line" | awk '{print $3}')

                if [[ "$vd_id" =~ [0-9]+/[0-9]+ ]] && [ -n "$state" ]; then
                    case "$state" in
                        Optl)
                            echo "0 Raid_Logical_Drive_$vd_id - Logical drive $vd_id is in Optimal state"
                            ;;
                        Rec)
                            echo "1 Raid_Logical_Drive_$vd_id - Logical drive $vd_id is in Recovery state"
                            ;;
                        OfLn|Pdgd|Dgrd)
                            echo "2 Raid_Logical_Drive_$vd_id - Logical drive $vd_id is in Critical state: ($state)"
                            ;;
                        *)
                            echo "3 Raid_Logical_Drive_$vd_id - Logical drive $vd_id is in Unknown state ($state)"
                            ;;
                    esac
                fi
            done
        fi
    done
}

# Run the check for Dell server
check_server_dell_raid_controller
