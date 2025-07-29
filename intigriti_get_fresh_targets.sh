#!/bin/bash

rm intigriti_handles.txt
rm intigriti_assets.txt

curl --request GET --url https://api.intigriti.com/external/researcher/v1/programs\?limit\=500 --header 'accept: application/json' --header 'Authorization: Bearer <TU_BEARER>'  | jq '.records[] | .id' | sed 's/"//g' > intigriti_handles.txt

while read linea; do
    echo "retrieving assets for $linea"
    curl --request GET --url "https://api.intigriti.com/external/researcher/v1/programs/$linea" --header 'accept: application/json' --header 'Authorization: Bearer <TU_BEARER>'  | jq -r '"\(.id), \(.name), \(.domains.content[] | .endpoint)"' | awk 'NR==1{print "id, name, endpoint"}1' >>  intigriti_assets.txt
done < intigriti_handles.txt

echo "######Corrida $(date +"%Y-%m-%d")#######" >> intigriti_fresh_targets.txt
cat intigriti_assets.txt | anew intigriti_fresh_targets.txt | /root/go/bin/notify
