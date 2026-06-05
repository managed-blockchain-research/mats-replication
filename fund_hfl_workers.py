#!/usr/bin/env python3
"""
Fund 30 HD-wallet worker accounts for stateBloatMixed.js caliper experiment.
Derived from seed=deadbeef...deadbeef via m/44'/60'/{i}'/0/0.

Usage:
    python3 fund_hfl_workers.py [--rpc http://localhost:8545]
"""
import argparse
import sys
from web3 import Web3

WORKER_ADDRESSES = [
    "0xe1D4272D5f2A2455a720b098486C207191A76CB2",
    "0x9FcFE0f92f323ee80Fe7AB0D6aE7fd93762C47f3",
    "0x2c17859D6E1AB27998f6DADeDCa0Dfb710F92B68",
    "0xF6496202fF0C645B2870Ad9Ea8a79C7a9b887d1F",
    "0x989Fb518e50E6C0ce5ccF5f90EE1fe21E7249432",
    "0xf0Dac90A5676bE80D8fA5dAf4acae10649eA8De1",
    "0xe6B5a48149e44d02a9EAF1c4e67bE9ce19Eb94da",
    "0x5a4313D26aE36Dd1181F3EF80533cC88Ed8557F3",
    "0x5cdcD7410c4fBC1b1f9602285107Ff55D4033e62",
    "0x9AFe63BeDfe7910900ebEbCf8F9112Ddf2324EFF",
    "0x3167aeBC055eaC8104A88F05123B8D4fd10880db",
    "0x6f2884453F928359733E29b540Ae455B9c674171",
    "0x8E4214C09efEB0Eee7454e7A6b814D4481c85529",
    "0x9e36f9C486B5d0187C220AB875f280Da9A4F6749",
    "0x4707638E6eC7d725f40517548610B0B1B5bD0C44",
    "0x49A405229d24a0aa9c5A5a20f0C5a06991428684",
    "0x7Fb8a45f942beE65741CA4e43C2918ec92783e4D",
    "0x3E1E902eb8Fe084A8FC7a707e7F693B3E80Ec7D8",
    "0x62749d3F9C2B02712714becAb6D52cfc88D86546",
    "0x7cA663411db0C4AA773D2E611B3C92f41Ff41E68",
    "0xeCC22ace99D41015cc84AFAd85bc049a1517134c",
    "0xD83694cCC1C27be4F41B36816A60D0c942232A8c",
    "0x1e70A7C4a2b14ADCFFD057366da5711693E38A14",
    "0xF53d007d8401AD1310e83f164D8BCD32cc399f96",
    "0xf41446AF10e636a9354F6b082e1356C53f37A07f",
    "0x6C452DD5B1Bb484D63460D0a970ddB9eFbc48F66",
    "0x76fA8D689773240341fB7aCca36C75AF26447a49",
    "0xeA6f9c2B1609416644ca2fB75187014c5AD2c495",
    "0x2644C6D406f41Bbd46B7e71F0EcF8B86803419eF",
    "0x7ca7ef901381119c35Ac59148ae2E84d48060c2A",
]

FUND_AMOUNT = 10 * 10**18  # 10 ETH each
DEPLOYER_KEY = '0x8f2a55949038a9610f502c24114d051185071191bc20b60811a2d7fba4513689'

parser = argparse.ArgumentParser()
parser.add_argument('--rpc', default='http://localhost:8545')
args = parser.parse_args()

w3 = Web3(Web3.HTTPProvider(args.rpc))
if not w3.is_connected():
    print('ERROR: cannot connect', file=sys.stderr)
    sys.exit(1)

deployer = w3.eth.account.from_key(DEPLOYER_KEY)
nonce = w3.eth.get_transaction_count(deployer.address)
chain_id = w3.eth.chain_id

print(f'Funding {len(WORKER_ADDRESSES)} worker accounts with 10 ETH each...')
print(f'Funder: {deployer.address}  chainId={chain_id}  nonce={nonce}', flush=True)

funded = 0
for i, addr in enumerate(WORKER_ADDRESSES):
    bal = w3.eth.get_balance(addr)
    if bal >= FUND_AMOUNT:
        print(f'  [{i}] {addr} already funded ({bal//10**18} ETH), skip', flush=True)
        continue
    tx = {
        'to': addr,
        'value': FUND_AMOUNT,
        'gas': 21000,
        'gasPrice': 1_000_000_000,
        'nonce': nonce,
        'chainId': chain_id,
    }
    signed = deployer.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f'  [{i}] {addr} → tx {h.hex()[:16]}... (waiting for receipt)', flush=True)
    # Confirm each transaction before sending the next — avoids Besu LAYERED pool
    # not promoting future nonces after block confirmation.
    w3.eth.wait_for_transaction_receipt(h, timeout=120)
    nonce += 1
    funded += 1
    print(f'  [{i}] confirmed.', flush=True)

print(f'Done. Funded {funded} accounts (skipped {len(WORKER_ADDRESSES)-funded} already-funded).', flush=True)
