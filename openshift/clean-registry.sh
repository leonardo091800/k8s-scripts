#!/bin/bash
# tested in OCP v4.9


helpFunction()
{
   echo ""
   echo "Usage: $0 [-t (--ntags) nTagsToKeep ]  [-n (--namespace) 'namespaceName']  [-c (--confirm)]  [-v / -vv / -vvv]"
   echo -e "\t--confirm to confirm the deletion (default is dry-run)"
   echo -e "\t--ntags number of tags to keep for each imagestream (default: 10)"
   echo -e "\t--namespace particular namespace you want (default: all-namespaces)"
   echo -e "\t-h print this help"
   exit 1 # Exit script after printing help
}

# Parameters
confirm=false
v=false
vv=false
vvv=false
nTagsToKeep=10
ns="A"
nTagsDeleted=0

# Parse command-line arguments
while [ $# -gt 0 ] ; do
   case $1 in
      -c | --confirm) confirm=true;;
      -t | --ntags) nTagsToKeep=$2;;
      -n | --namespace) ns="$2" ;;
      -v | --verbose) v=true;;
      -vv | --verbose) v=true; vv=true;;
      -vvv | --very-very-verbose) v=true; vv=true; vvv=true;;
      -h | --help) helpFunction ;;
   esac
   shift
done
#echo "nTagsToKeep = $nTagsToKeep \nn = $ns"
#echo "v=$v vv=$vv vvv=$vvv"

#Print helpFunction in case parameters are empty
if [[ $# -gt 0 ]]
then
   echo "Some or all of the parameters are empty";
   helpFunction
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
GREEN_IMP='\033[1;4;32m'
YELLOW='\033[0;33m'
YELLOW_IMP='\033[1;4;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'


###########################################################################################################
#get the list of desired namespaces
[[ "$ns" = "A" ]] && ns_list=$(oc get namespaces --no-headers -o custom-columns=':metadata.name') && echo "all ns selected!" || ns_list=$ns
#echo "ns_list: $ns_list"

# Iterate over each namespace
for ns in $ns_list; do
    $v && echo -e "\n${BLUE}ns: $ns ${NC}"
    # Get list of imagestreams inside namespace
    imagestreams=$(oc get imagestream  -n "${ns}" -ojson | jq -r '.items[].metadata.name')

    # cheack if imagestream exists
    if [ -z "$imagestreams" ]; then
        if $v; then
            echo -e "${CYAN} EMPTY ${NC}"
        fi
        continue
    fi
    # Iterate over each imagestream (if exists)
    for is in $imagestreams; do
        $vv && echo -e "${CYAN} \tis: $is ${NC}"

        # Get the list of tag + their quantity (for each image stream)
        tags=$(oc get imagestream "$is" -n $ns -ojson | jq -r '.status.tags[].tag' | sort -u)
        num_tags=$(echo "$tags" | wc -l)
        $vv && echo -e "\t\t$num_tags tags:"

        if [ "$num_tags" -gt "$nTagsToKeep" ]; then
            nTagsToDelete=$(($num_tags-$nTagsToKeep))
            tags_to_delete=$(echo "$tags" | head -n $nTagsToDelete)
            tags_to_keep=$(echo "$tags" | tail -n $nTagsToKeep)

            # show tags kept
            if $vvv; then
                for tag in $tags_to_keep; do
                    echo -e "\t\t${GREEN}$ns/$is:$tag${NC}"
                done
            fi

            # Iterate over each tag to delete
            for tag in $tags_to_delete; do
                $confirm && oc tag -d "$ns/$is:$tag"
                ((nTagsDeleted++))
                if $vvv; then
                    echo -e "\t\t${RED}$ns/$is:$tag !!!DELETED!!!  ${NC}"
                fi
            done
            $v && echo -e "\t\t${RED}$nTagsToDelete DELETED ${NC}"
        else
            $vv && echo -e "\t\t${GREEN}Skipping ${NC}"
        fi
    done
done

echo -e "deleted $nTagsDeleted tags"
################################################################
echo -e "\ncheck free space in registry... showing command df -h on registry pod:"
imageRegistryPodName=$(oc get po -n openshift-image-registry -o json | jq -r '.items[] | select(.metadata.labels."docker-registry"=="default") | .metadata.name')
oc exec $imageRegistryPodName -n openshift-image-registry -- df -h | grep -iE 'registry|Size'
################################################################
$confirm || echo -e "\n!!! \nto actually DELETE them, then, you need to run the command again with --confirm \n!!!\n\n(Use -vvv to see what tags are deleted and what remains)"
$confirm || exit
################################################################
echo -e "\n\n Now that you un-tagged them, do you actually want to prune them from the registry? (remember to launch this command from ocpadmin user that HAS ALREADY logged in)"
read -p "y/n: " deleteFromRegistry
[ $deleteFromRegistry != 'y' ] && echo -e "ok, bye"
[ $deleteFromRegistry != 'y' ] && exit
# enabling read only mode for security reasons...
oc patch configs.imageregistry.operator.openshift.io/cluster -p '{"spec":{"readOnly":true}}' --type=merge
# getting the route name
ocImageRegistryRoute=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
# activating the pruning
oc adm prune images --keep-tag-revisions=10 --keep-younger-than=172800m --registry-url $ocImageRegistryRoute --confirm
#oc adm prune images --keep-tag-revisions=10 --keep-younger-than=172800m --confirm
# ...disabling the read only mode
oc patch configs.imageregistry.operator.openshift.io/cluster -p '{"spec":{"readOnly":false}}' --type=merge

################################################################
echo -e "\ncheck free space in registry... showing command df -h on registry pod:"
imageRegistryPodName=$(oc get po -n openshift-image-registry -o json | jq -r '.items[] | select(.metadata.labels."docker-registry"=="default") | .metadata.name')
oc exec $imageRegistryPodName -n openshift-image-registry -- df -h | grep -iE 'registry|Size'


