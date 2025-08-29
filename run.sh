sudo docker run --rm -it -v "$PWD":/app -w /app starknetfoundation/starknet-dev:2.11.4 \
  bash -lc 'scarb build && snforge test'

