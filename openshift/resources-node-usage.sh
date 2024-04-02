#!/bin/bash
# Tested in Openshift v4.9

# printf colors: ->
BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BRIGHT=$(tput bold)
NORMAL=$(tput sgr0)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)
# <-
# Resources color levels:
# come colori: 
# verde -> in questo nodo ci stanno almeno 2 repliche 
# giallo -> in questo nodo ci sta al massimo 1 replica in più
# rosso -> in questo non NON ci sta nessuna replica in più
CPU_red_level=1000
CPU_orange_level=2000
RAM_red_level=4000
RAM_orange_level=8000
#<-
# needed for indentation ->
nodeNameLength=38
cpuLength=14
cpu_whiteSpace_Length=3
ramLength=17
ram_whiteSpace_Length=3
#<-
# global env ->
nWorkerNodes=$(oc get nodes --selector='node-role.kubernetes.io/worker=' --no-headers | grep '\-worker\-' | wc -l)
available_cpu_if_hpa_activate=0
available_ram_if_hpa_activate=0
# <-

# Function to convert CPU and RAM values to a common unit
convert_to_common_unit() {
    local sentence="$1"
    local resource_info=$(echo "$sentence" | grep -oP '(memory|cpu)\s+(\d+)(Mi|Ki|m)' | awk '{print $2}')
    local value=$(echo $resource_info | tr -cd '0-9')  # Extract numeric part
    local unit=${resource_info//[0-9]/}  # Extract alphabetic part
#echo "local sentence: $sentence"
#echo "resource info: $resource_info"
#echo "value: $value"
#echo "unit: $unit"

    case $unit in
        "Ki")
            echo $((value / 1024))
            ;;
        "Mi")
            echo $value
            ;;
        "Gi")
            echo $((value * 1024))
            ;;
        "m")
            echo $value
            ;;
        *)
            echo "Invalid unit: $unit"
            exit 1
            ;;
    esac
}




# Function to convert memory units to MiB
convert_memory_to_mib() {
    local unit=${1: -2}  # Get the last two characters of the string (e.g., Mi, M, Gi, G)
    local value=${1%$unit}  # Remove the unit from the string
    case $unit in
        "Mi") echo $value ;;
        "M")  echo $(($value * 1024)) ;;
        "Gi") echo $(($value * 1024)) ;;
        "G")  echo $(($value * 1024 * 1024)) ;;
        *)    echo $1 ;;  # Default to the original value if the unit is unknown
    esac
}



oc get hpa -A -o custom-columns='Name:.metadata.name,Min:.spec.minReplicas,Current:.status.currentReplicas,Desired:.status.desiredReplicas,Max:.spec.maxReplicas'

# Store the output in variables
hpa_info=$(kubectl get hpa --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,HPA:.metadata.name,MAXREPLICAS:.spec.maxReplicas,CURRENTREPLICAS:.status.currentReplicas,TARGETCPU:.spec.targetCPUUtilizationPercentage,DEPLOYMENT:.spec.scaleTargetRef.name --no-headers)
# Variables to store the sum of CPU and memory products
sum_hpa_cpu=0
sum_hpa_ram=0

# Iterate over the lines and get deployment resource requests
while IFS= read -r line; do
    namespace=$(echo "$line" | awk '{print $1}')
    hpa_name=$(echo "$line" | awk '{print $2}')
    max_replicas=$(echo "$line" | awk '{print $3}')
    current_replicas=$(echo "$line" | awk '{print $4}')
    target_cpu=$(echo "$line" | awk '{print $5}')
    deployment_name=$(echo "$line" | awk '{print $6}')

    # Get CPU and memory requests for the deployment
    cpu_request=$(kubectl get deploy -n $namespace $deployment_name -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
    memory_request=$(kubectl get deploy -n $namespace $deployment_name -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')

                # Check if CPU request is in millicores and convert if necessary
    if [[ $cpu_request =~ "m" ]]; then
        cpu_request_millicores=${cpu_request%m}  # Remove 'm'
    else
        cpu_request_millicores=$((cpu_request * 1000))  # Convert to millicores
    fi

                # Convert memory request to MiB
    memory_request_mib=$(convert_memory_to_mib $memory_request)

    # Calculate the product of cpu_request and memory_request multiplied by the difference
    cpu_product=$((cpu_request_millicores * (max_replicas - current_replicas)))
    memory_product=$((memory_request_mib * (max_replicas - current_replicas)))

    # update the sum of hpa
    sum_hpa_cpu=$(($sum_hpa_cpu + $cpu_product))
    sum_hpa_ram=$(($sum_hpa_ram + $memory_product))



#    # Print information for each deployment
#    echo "Namespace: $namespace, HPA: $hpa_name"
#    echo "  - Deployment: $deployment_name"
#    echo "    - Target CPU: $target_cpu%"
#    echo "    - CPU Request: $cpu_request"
#    echo "    - Memory Request: $memory_request"
#    echo "    - Max Replicas: $max_replicas"
#    echo "    - Current Replicas: $current_replicas"
#    echo "    - CPU Product: $cpu_product"
#    echo "    - Memory Product: $memory_product"
#    echo ""
done <<< "$hpa_info"


## median cpu usage if all hpa were to activate
median_hpa_cpu_x_nodo=$(($sum_hpa_cpu / $nWorkerNodes))
median_hpa_ram_x_nodo=$(($sum_hpa_ram / $nWorkerNodes))
#echo " sum hpa cpu = $sum_hpa_cpu "
#echo " nWorkerNodes = $nWorkerNodes"
#echo " median cpu if HPA activates: $median_hpa_cpu_x_nodo"
#echo " sum hpa ram = $sum_hpa_ram "
#echo " nWorkerNodes = $nWorkerNodes"
#echo " median ram if HPA activates: $median_hpa_ram_x_nodo"


# Get nodes and their capacity
nodes=$(kubectl get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{"\n"}{end}')
#echo " nodes = $nodes"

# needed to confront with hpa later on
sum_available_ram=0
sum_available_cpu=0

echo -e "$(printf %-${nodeNameLength}s 'Node Name') | $(printf %-${cpuLength}s ' Requested CPU') | $(printf %-${ramLength}s 'Requested RAM') | $(printf %-${cpuLength}s 'Available CPU') | $(printf %-${ramLength}s 'Available RAM') | cpu and ram available if all HPA activate "

# Loop through each node

while read -r node cpu_capacity RAM_capacity; do
#echo "node = $node, cpu_capacity=$cpu_capacity, RAM_capacity=$RAM_capacity"


        cpu_capacity_m=$( echo $cpu_capacity | tr -cd '0-9')
        RAM_capacity_withoutKB=$(echo $RAM_capacity | tr -cd '0-9')
        RAM_capacity_mb=$( bc -l <<< "scale=0; $RAM_capacity_withoutKB / 1000" )
####echo "cpu capacity = $cpu_capacity"
#echo "cpu capacity_m = $cpu_capacity_m"
#echo "RAM capacity_withoutKB = $RAM_capacity_withoutKB"
#echo "RAM capacity_mb = $RAM_capacity_mb"

    # Get requested resources for the node
#    node_info=$(kubectl describe node $node | grep -A5 "Allocated resources" | tail -n +2)
    node_info=$(kubectl describe node $node | grep -A5 "Allocated resources")
#echo "node_info = $node_info"

        # Find the line containing "RAM" in each sentence
        requested_cpu_line=$(echo "$node_info" | grep -oP 'cpu\s+\S+')
        requested_RAM_line=$(echo "$node_info" | grep -oP 'memory\s+\S+')
#echo "requested cpu line = $requested_cpu_line"
#echo "requested RAM line = $requested_RAM_line"

        # Converting to a common Unit (milliCore and Mebibytes)
#convert_to_common_unit "$requested_RAM_line"
#exit
        requested_cpu_m=$(convert_to_common_unit "$requested_cpu_line")
        requested_RAM_mb=$(convert_to_common_unit "$requested_RAM_line")
#echo "requested cpu_m = $requested_cpu_m"
#echo "requested RAM_mb = $requested_RAM_mb"

#    # Extract requested CPU and RAM
#    requested_cpu=$(echo "$node_info" | awk '/cpu/{gsub(/m/, "", $2); print $2}')
#    requested_RAM=$(echo "$node_info" | awk '/memory/{gsub(/Mi/, "", $2); print $2}' | tr -cd '0-9')
#
#    requested_cpu_m=$requested_cpu
#    requested_RAM_mb=$requested_RAM

#   # Convert requested resources to MB
#   requested_cpu_mb=$(convert_to_mb $requested_cpu "m")
#   requested_RAM_mb=$(convert_to_mb $(echo $requested_RAM | sed 's/Mi//') "Mi")

    # Calculate available resources
    available_cpu_m=$((cpu_capacity_m - requested_cpu_m))
    available_RAM_mb=$((RAM_capacity_mb - requested_RAM_mb))

#    # get the sum if node is -worker-
#    if [[ $node == *-worker-* ]]; then
##       echo "$node is worker";
#        sum_available_ram=$((sum_available_ram + available_RAM_mb))
#        sum_available_cpu=$((sum_available_cpu + available_cpu_m))
##    else
##       echo "$node is NOT worker";
#    fi

#echo "available cpu_m = $available_cpu_m"
#echo "available RAM_mb = $available_RAM_mb"

        # calculate percentages
        requested_cpu_p=$(bc -l <<< "scale=2; $requested_cpu_m / $cpu_capacity_m * 100" | cut -f1 -d ".")
        requested_RAM_p=$(bc -l <<< "scale=2; $requested_RAM_mb / $RAM_capacity_mb * 100" | cut -f1 -d ".")
        available_cpu_p=$(bc -l <<< "scale=2; $available_cpu_m / $cpu_capacity_m * 100" | cut -f1 -d ".")
        available_RAM_p=$(bc -l <<< "scale=2; $available_RAM_mb / $RAM_capacity_mb * 100" | cut -f1 -d ".")

    # Print the results
    printf "%-${nodeNameLength}s |" "$node"
        printf "%6sm %4s%% %${cpu_whiteSPace_Length}s |" "${requested_cpu_m}" "${requested_cpu_p}" " "
        printf "%8sMi %4s%% %${ram_whiteSPace_Length}s |" "${requested_RAM_mb}" "${requested_RAM_p}" " "

        # color if resource is scarce:
        if [ "$available_cpu_m" -lt $CPU_red_level ]
        then
                printf "${RED}%6sm %4s%% %${cpu_whiteSPace_Length}s ${WHITE}|" "${available_cpu_m}" "${available_cpu_p}" " "
        elif [ "$available_cpu_m" -lt $CPU_orange_level ]
        then
                printf "${YELLOW}%6sm %4s%% %${cpu_whiteSPace_Length}s ${WHITE}|" "${available_cpu_m}" "${available_cpu_p}" " "
        else
                printf "${GREEN}%6sm %4s%% %${cpu_whiteSPace_Length}s ${WHITE}|" "${available_cpu_m}" "${available_cpu_p}" " "
        fi

        # color if resource is scarce:
        if [ $available_RAM_mb -lt $RAM_red_level ]
        then
                printf "${RED}%8sMi %4s%% %${ram_whiteSPace_Length}s ${WHITE}|" "${available_RAM_mb}" "${available_RAM_p}" " "
        elif [ $available_RAM_mb -lt $RAM_orange_level ]
        then
                printf "${YELLOW}%8sMi %4s%% %${ram_whiteSPace_Length}s ${WHITE}|" "${available_RAM_mb}" "${available_RAM_p}" " "
        else
                printf "${GREEN}%8sMi %4s%% %${ram_whiteSPace_Length}s ${WHITE}|" "${available_RAM_mb}" "${available_RAM_p}" " "
        fi

    if [[ $node == *-worker-* ]]; then
        # Available CPU if HPA were to activate
        # color if resource is scarce:

        available_cpu_if_hpa_activate=$(( $available_cpu_m - $median_hpa_cpu_x_nodo ))
        available_cpu_if_hpa_activate_p=$(bc -l <<< "scale=2; $available_cpu_if_hpa_activate / $cpu_capacity_m * 100" | cut -f1 -d ".")

        if [ "$available_cpu_if_hpa_activate" -lt $CPU_red_level ]
        then
                printf "${RED}%6sm %4s%% %${cpu_whiteSPace_Length}s ${WHITE}" "${available_cpu_if_hpa_activate}" "$available_cpu_if_hpa_activate_p" " "
        elif [ "$available_cpu_if_hpa_activate" -lt $CPU_orange_level ]
        then
                printf "${YELLOW}%6sm %4s%% %${cpu_whiteSPace_Length}s ${WHITE}" "${available_cpu_if_hpa_activate}" "$available_cpu_if_hpa_activate_p" " "
        else
                printf "${GREEN}%6sm %4s%% %${cpu_whiteSPace_Length}s ${WHITE}" "${available_cpu_if_hpa_activate}" "$available_cpu_if_hpa_activate_p" " "
        fi
    fi

    if [[ $node == *-worker-* ]]; then
        # Available RAM if HPA were to activate
        # color if resource is scarce:

        available_ram_if_hpa_activate=$(( $available_RAM_mb - $median_hpa_ram_x_nodo ))
        available_ram_if_hpa_activate_p=$(bc -l <<< "scale=2; $available_ram_if_hpa_activate / $RAM_capacity_mb * 100" | cut -f1 -d ".")

        if [ "$available_ram_if_hpa_activate" -lt $RAM_red_level ]
        then
                printf "${RED}%6sm %4s%% %${ram_whiteSPace_Length}s ${WHITE}|" "${available_ram_if_hpa_activate}" "$available_ram_if_hpa_activate_p" " "
        elif [ "$available_ram_if_hpa_activate" -lt $RAM_orange_level ]
        then
                printf "${YELLOW}%6sm %4s%% %${ram_whiteSPace_Length}s ${WHITE}|" "${available_ram_if_hpa_activate}" "$available_ram_if_hpa_activate_p" " "
        else
                printf "${GREEN}%6sm %4s%% %${ram_whiteSPace_Length}s ${WHITE}|" "${available_ram_if_hpa_activate}" "$available_ram_if_hpa_activate_p" " "
        fi
    fi

        printf "\n"
done <<< "$nodes"
