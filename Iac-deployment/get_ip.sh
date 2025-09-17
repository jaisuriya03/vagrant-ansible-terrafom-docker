#!/usr/bin/env bash
ip=$(hostname -I | awk '{print $2}')
echo "{\"ip\":\"$ip\"}"
