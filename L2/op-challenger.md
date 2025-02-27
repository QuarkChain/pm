# Tools
A [Python script](./scripts/play-op-challenger.py) is provided to facilitate listing games in progress and simulating a dishonest actor attacking the game up to maxGameDepth.
To see all available commands and options, run: `python3 ./scripts/play-op-challenger.py -h`

## Environment setup
- Install `cast` and `make op-challenger`
- Replace `OP_CHALLENGER`, `L1_RPC`, and `DISPUTE_GAME_FACTORY_PROXY` in `play-op-challenger.py` with your configurations or provide these options as command-line arguments (see help for details)
- Make sure at least one `op-challenger` is running

> In the following tutorials, `--l1-rpc`, `--fdg-addr`, and `--binpath` are optional if `OP_CHALLENGER`, `L1_RPC`, and `DISPUTE_GAME_FACTORY_PROXY` have been provided in the code.

## List games with absolute prestates

```sh
python3 ./play-op-challenger.py list-games --status 1 --l1-rpc $L1_RPC --fdg-addr $DISPUTE_GAME_FACTORY_PROXY --binpath $OP_CHALLENGER_BINARY_PATH
```

This command differs from `op-challenger`'s default `list-games` command in that you can filter games by `--status` (see help for its meaning) and the absolute prestate is queried, allowing you to check if the game's absolute prestate matches the current implementation.

## 1v1 actor to attack a game to maxGameDepth

### Attacking a game with an honest root Claim
The following script simulates a dishonest actor attacking an existing game with random claims against every honest claim, it'll wait any honest actor to respond to every attack using `op-challenger` after each attack, and repeat attacking until the specified maxGameDepth.

```sh
python3 ./play-op-challenger.py attack-all --game-addr $ADDR --parent-index $INDEX --maxGameDepth 73 --pk $PRIVATE_KEY --l1-rpc $L1_RPC --fdg-addr $DISPUTE_GAME_FACTORY_PROXY --binpath $OP_CHALLENGER_BINARY_PATH 
```
The `parent-index` is the index of the honest claim you want to start attacking. If no one has attacked it before, the default index is 0.

### Create a game with a dishonest root claim and attack honest challenger's Claims
- First, create a game with a dishonest root claim:

```sh
python3 test.py create-game --output-root "any value" --l2-block-num $NUMBER --pk $PK --l1-rpc $L1_RPC --fdg-addr $DISPUTE_GAME_FACTORY_PROXY --binpath $OP_CHALLENGER_BINARY_PATH 
```

- Then, attack the game after receiving the first response from any honest challenger:

```sh
python3 ./play-op-challenger.py attack-all --game-addr $ADDR --parent-index 1 --pk $PRIVATE_KEY --l1-rpc $L1_RPC --fdg-addr $DISPUTE_GAME_FACTORY_PROXY --binpath $OP_CHALLENGER_BINARY_PATH 
```

If the game reaches `maxGameDepth` (default is 73), a dishonest actor attempting to win would need to call the game contract's `step` function themselves. However, this call will always revert, assuming the game contract is functioning correctly.

## List claims

```sh
python3 ./play-op-challenger.py list-claims --game-addr $ADDR
```

# Grafana Monitor 
Incorrect Forecast Value Scenarios:

- Warning: Dishonest actors are attacking the game
    - disagree_challenger_ahead (danger): The root claim of a game is dishonest, but the honest `op-challenger` hasn't responded to the dishonest claims for a while. This might cause an incorrect output root to be updated in the `AnchorStateRegistry`.
    - agree_challenger_ahead: The root claim of a game is honest, but dishonest actors are challenging the game and the honest `op-challenger` hasn't responded to the dishonest actors for a while.

- Fatal: Dishonest actors have won the game
    - disagree_defender_wins: The dishonest actors have won the game and the honest actors have forfeited their bonds. Besides, the dishonest root claims have been updated in the `AnchorStateRegistry`! 
    - agree_challenger_wins: The dishonest actors have won the game, and the honest actors have lost the game and forfeited their bonds.
