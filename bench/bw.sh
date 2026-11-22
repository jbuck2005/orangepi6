#!/bin/bash
# 3x memory bandwidth on the board (stress-ng memrate 4x256M, 30 s each), MB/s
for i in 1 2 3; do
  stress-ng --memrate 4 --memrate-bytes 256M --timeout 30s --metrics 2>&1 \
    | grep -iE "memrate.*(read|write)64 " | sed -E "s/.*memrate +([0-9.]+) (write64|read64).*/run $i: \2 \1 MB\/s/"
done
