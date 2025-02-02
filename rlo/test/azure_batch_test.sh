#!/bin/bash
set -e
set -x

# Pytorch is nondeterministic on GPU, so don't include it here.
bash ./test/determinism_test.sh --tensorflow --output_keep_prob 1.0 --graph_state_keep_prob 1.0
bash ./test/gpu_test.sh
bash ./test/ray_test.sh

# Many of these tests also run in QuickTest and the pytest portion of BuildAndTest. However, those run on CPU.
# we only really care about the medium tests (which are also executed by BuildAndTest but on CPU).
pytest test/rlo/ --durations=5
