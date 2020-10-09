#!/bin/bash

[[ -z $1 ]] && { echo "Url is not set as parameter!"; exit; }

url=$1

while true; do
  curl $url
  echo
  sleep .5
done