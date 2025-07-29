#!/bin/bash

rm h1_handles.txt
rm h1_assets.txt

H1_TOKEN="<TU_TOKEN>"
# Replace with your actual H1 username (often just your token is enough, but included as per your script)
H1_USERNAME="<TU_HANDLE>"

i=0
echo $1
while [ $i -lt 10 ] 
do
    curl "https://api.hackerone.com/v1/hackers/programs?page\[size\]=100&page\[number\]=$i" -X GET -u "${H1_USERNAME}:${H1_TOKEN}" -H 'Accept: application/json' | jq -r '.data[].attributes.handle' >> h1_handles.txt
    echo $i
    ((i=i+1))
    echo $1
done
echo "finish retrieving handles"


while read linea; do
    echo "retrieving assets for $linea"
    curl "https://api.hackerone.com/v1/hackers/programs/$linea" -X GET -u "${H1_USERNAME}:${H1_TOKEN}" -H 'Accept: application/json' |
    jq -r '.relationships.structured_scopes.data[] | [.attributes.asset_type, .attributes.asset_identifier, .attributes.created_at, .attributes.eligible_for_submission, .attributes.eligible_for_bounty] | @csv' |
    awk -v linea="$linea" '{print linea "," $1}' >> h1_assets.txt
done < h1_handles.txt

echo "######Run  $(date)#######" >> h1_fresh_targets.txt
grep "$(date +"%Y-%m-%d")" h1_assets.txt | grep 'true,true' | anew h1_fresh_targets.txt | notify
