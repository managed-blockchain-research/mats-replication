#!/usr/bin/env python3
"""
Deploy N StateBloater contracts and update networkconfig.json.

Usage:
    python3 deploy_multi_contracts.py [N]   # default N=30
"""

import json
import sys
from web3 import Web3

N = int(sys.argv[1]) if len(sys.argv) > 1 else 30

w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
if not w3.is_connected():
    print('ERROR: Cannot connect to node at localhost:8545')
    sys.exit(1)

print(f'Connected. Block: {w3.eth.block_number}. Deploying {N} StateBloater contracts...')

with open('StateBloater.json', 'r') as f:
    artifact = json.load(f)

private_key = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'
account = w3.eth.account.from_key(private_key)
Contract = w3.eth.contract(abi=artifact['abi'], bytecode=artifact['bytecode'])

addresses = []
tx_hashes = []
nonce = w3.eth.get_transaction_count(account.address)

# Submit all deployments at once (batch submit, no waiting per tx)
for i in range(N):
    tx = Contract.constructor().build_transaction({
        'from': account.address,
        'nonce': nonce + i,
        'gas': 8000000,
        'gasPrice': 0,
        'chainId': 1337,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    tx_hashes.append(tx_hash)
    if (i + 1) % 10 == 0:
        print(f'  Submitted {i + 1}/{N} deployment txs...')

print(f'All {N} deployment txs submitted. Waiting for confirmations...')

for i, tx_hash in enumerate(tx_hashes):
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300)
    addr = receipt.contractAddress
    addresses.append(addr)
    print(f'  SB{i}: {addr}')

print(f'\nAll {N} contracts deployed. Updating networkconfig.json...')

with open('networkconfig.json', 'r') as f:
    config = json.load(f)

# Keep ABI from existing StateBloater entry (or from artifact)
abi = config['ethereum']['contracts'].get('StateBloater', {}).get('abi', artifact['abi'])
gas_limit = config['ethereum']['contracts'].get('StateBloater', {}).get('gas', {'gasLimit': 8000000})

# Rebuild contracts section with SB0..SBN-1
new_contracts = {}
for i, addr in enumerate(addresses):
    new_contracts[f'SB{i}'] = {
        'address': addr,
        'abi': abi,
        'gas': gas_limit,
    }

config['ethereum']['contracts'] = new_contracts

# Set transactionPollingTimeout to 90s so warmup settles within 90s of last submission
config['ethereum']['transactionPollingTimeout'] = 90

with open('networkconfig.json', 'w') as f:
    json.dump(config, f, indent=2)

print(f'networkconfig.json updated with {N} contracts (SB0..SB{N-1})')
print(f'Contract Address: {addresses[0]}')  # sentinel for run script grep

# Write addresses to a sidecar file for reference
with open('deployed_contracts.json', 'w') as f:
    json.dump({'contracts': [f'SB{i}' for i in range(N)], 'addresses': addresses}, f, indent=2)

print(f'\nDeployed contracts list: deployed_contracts.json')
print('Done.')
