# stUNI

Staked UNI – `stUNI` – is the easiest way to get rewards from UniStaker.

stUNI is a convenient liquid token wrapper on top of [UniStaker](https://github.com/uniswapfoundation/UniStaker). UNI holders can stake their UNI for stUNI. stUNI automates claiming rewards and delegating governance power. It's like what stETH does for ETH staking.

## How it works

- Stake `UNI` to receive that many `stUNI`.
- Optionally, delegate UNI voting power
- The `stUNI` contract deposits the `UNI` in UniStaker. `stUNI` assigns the voting power to the holder's chosen delegate, if any. Otherwise, it assigns the voting power using the default delegation strategy
- The delegation strategy can be configured by Uniswap governance. This keeps the default voting power aligned with the DAO and mitigates capture risk.
- The `stUNI` contract claims UniStaker's ETH rewards daily.
- The ETH rewards are auctioned off for more `UNI`, which is added to each user's staked position. e.g. a balance of `100 stUNI` might grow to `100.5 stUNI`.

Holders can redeem their `stUNI` 1:1 for the underlying `UNI` at any time.

For further documentation, see [Tally's docs](https://docs.tally.xyz/knowledge-base/staking-on-tally).

```mermaid


stateDiagram-v2
    direction TB

    state "LST Contract" as LST {
        state "Core Methods" as CoreMethods {
            direction LR
            stake: "stake()"
            transfer: "transfer()"
            unstake: "unstake()"
        }
        state "Owner Methods" as OwnerMethods {
            direction LR
            setPayoutAmount: "setPayoutAmount()"
            setFeeParameters: "setFeeParameters()"
        }
        state "Strategy Admin Methods" as StrategyMethods {
            direction LR
            setDefaultDelegatee: "setDefaultDelegatee()"
            setDelegateeGuardian: "setDelegateeGuardian()"
        }
        state "Searcher Methods" as SearcherMethods {
            claimRewards: "claimAndDistributeReward()"
        }
    }

    Stakers --> CoreMethods
    Owner --> OwnerMethods
    DelegateAdmin --> StrategyMethods
    Searchers --> SearcherMethods: "Distribute rewards"
    LST --> GovernanceStaking

```

## Gas Reports

To generate gas reports run the following command.

```bash
make gas
```

This will overwrite the gas report json, which can be checked in alongside changes to the core contracts to track impact on the gas used by important user actions.

Note that the gas report tests *must* be run with the `--isolate` flag in order to generate results that reflect reality.
