#!/usr/bin/env python3
"""Check this assignment's manifest values, including the prior schema regressions."""

import json
from pathlib import Path


def validate(data):
    expected = {
        "kind": "custom_token",
        "token": {
            "contract": "PSSToken",
            "name": "Pepelstiltskin",
            "symbol": "PSS",
            "decimals": 18,
            "constructorArgs": [],
            "totalSupply": "1000000000000000000000000000",
        },
        "contracts": [],
        "pool": {
            "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
            "fee": 3000,
            "tickSpacing": 60,
            "initialPrice": "125270724187523965593206900",
        },
        "economics": {
            "poolBps": 9000,
            "initialMarketCapWei": "2500000000000000000000",
            "remainderTo": "0x000000000000000000000000000000000000dead",
        },
    }
    if not isinstance(data, dict) or set(data) != set(expected) | {"notes"}:
        raise ValueError("Unexpected or missing root keys; chainId is not a manifest key")
    if not isinstance(data["notes"], str) or not data["notes"].strip():
        raise ValueError("notes must be a nonempty string")
    for key, value in expected.items():
        # JSON serialization also distinguishes a numeric type from a boolean.
        if json.dumps(data[key], sort_keys=True) != json.dumps(value, sort_keys=True):
            raise ValueError(f"{key} differs from the mandatory assignment values")


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    validate(json.loads((root / "launch.json").read_text()))
    print("launch.json: required values, notes type, and root keys pass")
