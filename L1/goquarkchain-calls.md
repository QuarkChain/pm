# GoQuarkChain 调用图

## 1. 客户端发送交易流程

```mermaid
sequenceDiagram
    participant Client
    participant PubRPC
    participant MasterBackend
    participant ShardConn
    participant ShardState
    participant EVM

    Client->>PubRPC: eth_sendRawTransaction
    PubRPC->>MasterBackend: AddTransaction(tx)
    MasterBackend->>MasterBackend: GetShardSizeByChainID(fromChainID)
    MasterBackend->>MasterBackend: GetSlaveConnsById(fullShardId)
    MasterBackend->>ShardConn: AddTransaction(tx) [gRPC]
    ShardConn->>ShardState: AddTransactionAndBroadcast(tx)
    ShardState->>ShardState: add_tx(tx)
    ShardState->>EVM: vm.Run(tx)
    EVM-->>ShardState: execution result
    ShardState-->>ShardConn: result
    ShardConn-->>MasterBackend: ACK
    MasterBackend-->>PubRPC: tx hash
    MasterBackend->>ProtocolManager: BroadcastTransactions(p2p)
    ProtocolManager->>Peers: AsyncSendTransactions()
```

**关键函数调用链:**
1. `cmd/eth_api/main.go` → HTTP handler
2. `cluster/master/api_backend.go` → `AddTransaction(tx)`
3. `cluster/master/api_backend.go` → `GetSlaveConnsById(fullShardId)`
4. `cluster/rpc/grpc_client.go` → `AddTransaction(req)`
5. `cluster/slave/backend.go` → `AddTransactionAndBroadcast(tx)`
6. `cluster/slave/backend.go` → `state.addTx(tx)`
7. `core/evm/evm.go` → `EVM.Execute()`

## 2. RootBlock 挖矿流程

```mermaid
sequenceDiagram
    participant Miner
    participant MasterBackend
    participant SlaveConn
    participant ShardState
    participant RootMiner
    participant RootBlockChain

    Miner->>MasterBackend: GetWork(nil, coinbase)
    MasterBackend->>RootMiner: GetWork(coinbaseAddr)
    RootMiner->>RootMiner: createRootBlockToMine(coinbaseAddr)
    RootMiner->>MasterBackend: GetUnconfirmedHeadersRequest
    loop per slave
        MasterBackend->>SlaveConn: GetUnconfirmedHeadersRequest
        SlaveConn->>ShardState: getUnconfirmedHeaders()
        ShardState-->>SlaveConn: header list
        SlaveConn-->>MasterBackend: headers
    end
    MasterBackend->>RootMiner: assembled header list
    RootMiner->>RootBlockChain: create RootBlock
    RootBlockChain-->>RootMiner: RootBlock candidate
    RootMiner-->>MasterBackend: MiningWork
    MasterBackend-->>Miner: MiningWork {hash, height, diff}

    Miner->>MasterBackend: SubmitWork(nonce, mixHash)
    MasterBackend->>RootMiner: SubmitWork(nonce, mixHash)
    RootMiner->>RootMiner: validate_seal(block, nonce)
    alt success
        RootMiner->>MasterBackend: addRootBlock(block)
        MasterBackend->>RootBlockChain: AddBlock(block)
        RootBlockChain->>RootBlockChain: update tip
        MasterBackend->>ProtocolManager: BroadcastTip(header)
        ProtocolManager->>Peers: AsyncSendNewTip
        MasterBackend->>SlaveConn: AddRootBlockRequest [gRPC]
        SlaveConn->>ShardState: add_root_block(rootBlock)
    end
```

**关键函数调用链:**
1. `cluster/master/api_backend.go` → `GetWork(nil, addr)`
2. `cluster/master/miner.go` → `createRootBlockToMine(coinbaseAddr)`
3. `cluster/master/handle.go` → `getUnconfirmedHeaders()` (fan-out to all slaves)
4. `cluster/master/miner.go` → `insertMinedBlock(block)` → `AddRootBlock`
5. `cluster/master/handle.go` → `addRootBlock(rBlock)`
6. `core/root_chain.go` → `AddBlock(rBlock)`

## 3. MinorBlock 分片挖矿流程

```mermaid
sequenceDiagram
    participant ShardMiner
    participant ShardState
    participant SlaveBackend
    participant MasterBackend
    participant RootBlockChain

    ShardMiner->>ShardState: createBlockToMine(coinbaseAddr)
    ShardState->>ShardState: assemble MinorBlock from tx pool
    ShardState->>ShardState: include xshard tx deposits
    ShardState-->>ShardMiner: MinorBlock candidate
    ShardMiner->>ShardMiner: PoW mining (qkchash/ethash)
    ShardMiner->>ShardState: handle_new_block(minorBlock)
    ShardState->>ShardState: validate_block(block)
    ShardState->>ShardState: add_block(block) → execute txs
    ShardState-->>ShardState: xshard_list, coinbase_amount_map
    ShardState->>SlaveBackend: broadcast_new_tip()
    SlaveBackend->>MasterBackend: sendMinorBlockHeaderToMaster(header, txCount, xshardCount)
    MasterBackend->>RootBlockChain: AddValidatedMinorBlockHeader(hash, coinbaseMap)
    MasterBackend->>MasterBackend: UpdateShardStatus(shardStats)
    SlaveBackend->>SlaveBackend: broadcast_xshard_tx_list(block, xshardList)
    SlaveBackend->>PeerShardConn: BatchBroadcastXshardTxList
```

**关键函数调用链:**
1. `cluster/slave/miner.go` → `createBlockToMine()`
2. `cluster/slave/backend.go` → `state.CreateBlockToMine()`
3. `cluster/slave/api.go` → `HandleNewBlock(block)`
4. `cluster/slave/backend.go` → `state.AddBlock(block)`
5. `cluster/rpc/grpc_client.go` → `SendMinorBlockHeaderToMaster(req)`
6. `cluster/master/master_grpc.go` → `AddMinorBlockHeader(ctx, req)`
7. `cluster/master/handle.go` → `rootBlockChain.AddValidatedMinorBlockHeader()`

## 4. P2P 同步流程 (Root Chain)

```mermaid
sequenceDiagram
    participant Peer
    participant ProtocolManager
    participant Synchronizer
    participant SyncTask
    participant RootBlockChain
    participant SlaveConn

    Peer->>ProtocolManager: NewTipMsg (root header)
    ProtocolManager->>ProtocolManager: HandleNewRootTip(tip, peer)
    ProtocolManager->>Synchronizer: AddTask(rootChainTask)
    Synchronizer->>SyncTask: new RootChainTask(peer, header)
    SyncTask->>SyncTask: find_ancestor() (n-ary search)
    SyncTask->>Peer: GetRootBlockHeaderListWithSkipRequest
    Peer-->>SyncTask: block header list
    SyncTask->>Peer: GetRootBlockListRequest
    Peer-->>SyncTask: root block list
    loop per root block
        SyncTask->>RootBlockChain: AddBlock(rBlock)
        SyncTask->>Peer: SyncMinorBlockListRequest [per branch]
        Peer->>SlaveConn: forward to shard slave
        SlaveConn-->>Peer: minor blocks
        Peer-->>SyncTask: minor block list
    end
    SyncTask->>ProtocolManager: statsChan → shard status update
```

**关键函数调用链:**
1. `cluster/master/handle.go` → `handleMsg()` → `HandleNewRootTip()`
2. `cluster/master/sync.go` → `Synchronizer.AddTask()`
3. `cluster/master/sync.go` → `SyncTask.sync()`
4. `cluster/master/sync.go` → `SyncTask.find_ancestor()`
5. `p2p/` → GetRootBlockHeaderList RPC
6. `cluster/master/sync.go` → `SyncTask.__addBlock()`

## 5. 查询交易详情

```mermaid
sequenceDiagram
    participant Client
    participant PrivRPC
    participant MasterBackend
    participant SlaveConn
    participant ShardState

    Client->>PrivRPC: GetTransactionByHash(txHash, branch)
    PrivRPC->>MasterBackend: GetTransactionByHash(txHash, branch)
    MasterBackend->>MasterBackend: GetOneSlaveConnById(branch.Value)
    MasterBackend->>SlaveConn: GetTransactionByHash(txHash, branch) [gRPC]
    SlaveConn->>ShardState: GetTransactionByHash(txHash)
    ShardState->>ShardState: search tx pool + blocks
    ShardState-->>SlaveConn: (block, index)
    SlaveConn-->>MasterBackend: (block, index)
    MasterBackend-->>PrivRPC: (block, index)
    PrivRPC-->>Client: transaction + block info
```

## 6. 跨分片交易 (Cross-Shard Transaction)

```mermaid
sequenceDiagram
    participant TxSender
    participant ShardA
    participant ShardB
    participant Master
    participant RootChain

    TxSender->>ShardA: sendRawTransaction(to=shardB address)
    ShardA->>ShardA: validate + execute on EVM
    ShardA->>ShardA: mark as cross-shard (toFullShardKey != from)
    ShardA->>Master: sendMinorBlockHeaderToMaster()
    Note over Master: includes xShardTxCount

    Master->>ShardB: BroadcastXshardTxList(xshardTxs)
    ShardB->>ShardB: deposit xshard txs into tx pool
    ShardB->>ShardB: can include in next minor block

    Note over ShardB,RootChain: When next RootBlock mined:
    RootBlock->>ShardB: includes confirmed xshard deposits
    RootChain->>Master: AddValidatedMinorBlockHeader
    Master->>Master: record cross-shard confirmation
```

## 7. WebSocket 订阅事件

```mermaid
sequenceDiagram
    participant WS Client
    participant WSHandler
    participant PublicFilterAPI
    participant EventSystem
    participant ShardState

    WS Client->>WSHandler: subscribe (NewHeads / PendingTransactions / Logs)
    WSHandler->>PublicFilterAPI: NewHeads() / NewPendingTransactions() / Logs()
    PublicFilterAPI->>EventSystem: SubscribeNewHeads() / SubscribePendingTxs() / SubscribeLogs()
    EventSystem->>ShardState: register event handler

    loop new block mined
        ShardState->>EventSystem: emit block event
        EventSystem->>PublicFilterAPI: notify subscription
        PublicFilterAPI->>WSHandler: encode block/tx/log
        WSHandler->>WS Client: WebSocket notify
    end
```

## 8. 配置加载与节点启动

```mermaid
sequenceDiagram
    participant CLI
    participant CmdUtils
    participant ServiceNode
    participant Config
    participant MasterBackend
    participant SlaveBackend

    CLI->>CmdUtils: parse flags (cluster_config, service, etc.)
    CmdUtils->>Config: LoadClusterConfig(jsonFile)
    Config->>Config: parse Chains/Shards/Master/P2P sections
    Config-->>CmdUtils: ClusterConfig struct

    CmdUtils->>ServiceNode: New(conf)
    ServiceNode->>ServiceNode: setup P2P config, data dir

    ServiceNode->>ServiceNode: Register(master service constructor)
    ServiceNode->>ServiceNode: Register(slave service constructor)

    ServiceNode->>ServiceNode: Start()
    ServiceNode->>ServiceNode: startRPC(apis)
    ServiceNode->>ServiceNode: startGRPC()
    ServiceNode->>ServiceNode: startHTTP() / startPrivHTTP()

    ServiceNode->>MasterBackend: Init(p2pServer)
    MasterBackend->>MasterBackend: connect to slaves
    MasterBackend->>MasterBackend: start mining if configured

    ServiceNode->>SlaveBackend: Init(p2pServer)
    SlaveBackend->>SlaveBackend: connect to master
    SlaveBackend->>SlaveBackend: init shard state
```

## gRPC 接口定义 (cluster/rpc/rpc.proto)

主要的 gRPC RPC 方法:

| 方向 | 方法 | 说明 |
|------|------|------|
| Master←Slave | AddMinorBlockHeader | Slave 提交已验证的 minor block header |
| Master←Slave | AddMinorBlockHeaderList | 批量提交 minor block headers |
| Master→Slave | AddTransaction | 分发交易到指定分片 |
| Master→Slave | GetMinorBlockByHash/Height | 查询分区块 |
| Master→Slave | GetTransactionByHash | 查询交易 |
| Master→Slave | GetWork / SubmitWork | 挖矿工作分配 |
| Master→Slave | SyncMinorBlockList | 同步分区块列表 |
| Master→Slave | ExecuteTransaction | 模拟交易执行 |
| Peer→Peer | NewTipMsg | P2P 新区通告 |
| Peer→Peer | NewTransactionListMsg | 新交易广播 |
| Peer→Peer | NewBlockMinorMsg | 新区块广播 |
