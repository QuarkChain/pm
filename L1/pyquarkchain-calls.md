# PyQuarkChain 调用图

## 1. 客户端发送交易 → 分片打包流程

```mermaid
sequenceDiagram
    participant Client
    participant PubJSONRPC
    participant MasterServer
    participant SlaveConn
    participant SlaveServer
    participant Shard
    participant ShardState
    participant EVM

    Client->>PubJSONRPC: quarkchain_sendRawTransaction / eth_sendRawTransaction
    PubJSONRPC->>MasterServer: add_transaction(tx)
    MasterServer->>MasterServer: extract from_full_shard_id from tx
    MasterServer->>MasterServer: lookup branch_to_slaves[from_full_shard_id]
    MasterServer->>SlaveConn: write_rpc(ADD_TRANSACTION_REQUEST, tx) [fan-out]
    SlaveConn->>SlaveServer: handle_add_transaction(req)
    SlaveServer->>Shard: add_tx(tx)
    Shard->>ShardState: add_tx(tx)
    ShardState->>ShardState: validate tx (nonce, signature, balance, gas)
    ShardState->>EVM: vm.validate_transaction(tx)
    EVM-->>ShardState: validated
    ShardState->>ShardState: tx_queue.append(tx)
    ShardState-->>Shard: True
    Shard-->>SlaveServer: ACK
    SlaveServer-->>SlaveConn: error_code=0
    SlaveConn-->>MasterServer: resp
    MasterServer->>MasterServer: broadcast to P2P peers
    MasterServer-->>PubJSONRPC: tx hash
```

**关键函数调用链:**
1. `cluster/jsonrpc.py` → `handle_quarkchain_sendRawTransaction()` / `handle_eth_sendRawTransaction()`
2. `cluster/master.py` → `MasterServer.add_transaction(tx)` (L1225)
3. `cluster/master.py` → `SlaveConnection.write_rpc(ADD_TRANSACTION_REQUEST)` (L524)
4. `cluster/slave.py` → `SlaveServer.handle_add_transaction()` (L308)
5. `cluster/slave.py` → `SlaveServer.add_tx(tx)` (L1202)
6. `cluster/shard.py` → `Shard.add_tx(tx)` (L915)
7. `cluster/shard_state.py` → `ShardState.add_tx(tx)` (L544)

## 2. 分片挖矿流程

```mermaid
sequenceDiagram
    participant MinerProcess
    participant ShardMiner
    participant ShardState
    participant Shard
    participant SlaveServer
    participant MasterServer
    participant P2PPeer

    MinerProcess->>ShardMiner: _mine_new_block_async() loop
    ShardMiner->>ShardState: create_block_to_mine(coinbase_addr)
    ShardState->>ShardState: select txs from tx_queue
    ShardState->>ShardState: apply transactions via EVM
    ShardState-->>ShardMiner: MinorBlock candidate
    ShardMiner->>ShardMiner: POW computation (subprocess)
    alt nonce found
        ShardMiner->>Shard: handle_new_block(minorBlock)
        Shard->>ShardState: validate_block(block)
        Shard->>ShardState: add_block(block)
        ShardState->>ShardState: run_block() execute txs
        ShardState->>ShardState: update header_tip
        ShardState->>Shard: xshard_list + coinbase_map
        Shard->>Shard: broadcast_new_tip()
        par fan-out to peers
            Shard->>P2PPeer: write_command(NEW_BLOCK_MINOR)
        and to master
            Shard->>SlaveServer: slave.send_minor_block_header_to_master()
            SlaveServer->>MasterServer: write_rpc(ADD_MINOR_BLOCK_HEADER_REQUEST)
            MasterServer->>MasterServer: root_state.add_validated_minor_block_hash()
            MasterServer->>MasterServer: update_shard_stats()
        end
        Shard->>SlaveServer: broadcast_xshard_tx_list()
        SlaveServer->>TargetSlave: ADD_XSHARD_TX_LIST_REQUEST [fan-out]
    end
```

**关键函数调用链:**
1. `cluster/miner.py` → `Miner._mine_new_block_async()` (L176)
2. `cluster/miner.py` → `create_block_async_func(coinbase_addr)` → `ShardState.create_block_to_mine()`
3. `cluster/shard.py` → `Shard.handle_new_block(block)` (L646)
4. `cluster/shard_state.py` → `ShardState.validate_block(block)`
5. `cluster/shard_state.py` → `ShardState.add_block(block)` (L893)
6. `cluster/shard.py` → `Shard.broadcast_new_tip()`
7. `cluster/slave.py` → `SlaveServer.send_minor_block_header_to_master()`

## 3. RootBlock 挖矿流程

```mermaid
sequenceDiagram
    participant RootMiner
    participant MasterServer
    participant SlaveConn
    participant ShardState
    participant RootState
    participant P2PPeer

    RootMiner->>MasterServer: __create_root_block_to_mine(coinbase_addr)
    MasterServer->>SlaveConn: GET_UNCONFIRMED_HEADERS_REQUEST [fan-out to all slaves]
    loop per slave
        SlaveConn->>ShardState: get_unconfirmed_headers() per shard
        ShardState-->>SlaveConn: [header_info_list]
        SlaveConn-->>MasterServer: headers_info_list
    end
    MasterServer->>MasterServer: merge headers by full_shard_id
    MasterServer->>MasterServer: filter by timestamp, sort by shard_id
    MasterServer->>RootState: create_block_to_mine(header_list, coinbase_addr)
    RootState-->>MasterServer: RootBlock candidate
    MasterServer-->>RootMiner: RootBlock candidate
    RootMiner->>RootMiner: POW computation (subprocess)
    alt nonce found
        RootMiner->>MasterServer: add_root_block_from_miner(block)
        MasterServer->>MasterServer: write_committing_hash(block_hash)
        MasterServer->>MasterServer: __adjust_diff() (PoSW/Guardian)
        MasterServer->>RootState: add_block(rootBlock)
        RootState->>RootState: validate root block
        RootState->>RootState: update root_tip
        opt tip updated
            MasterServer->>P2PPeer: send_updated_tip() [fan-out]
        end
        MasterServer->>SlaveConn: ADD_ROOT_BLOCK_REQUEST [fan-out]
        loop per slave
            SlaveConn->>ShardState: add_root_block(rootBlock)
            ShardState->>ShardState: validate root block
            ShardState->>ShardState: update root_tip
            ShardState->>ShardState: update confirmed_header_tip
        end
        MasterServer->>MasterServer: clear_committing_hash()
    end
```

**关键函数调用链:**
1. `cluster/master.py` → `MasterServer.__create_root_block_to_mine()` (L1107)
2. `cluster/master.py` → `SlaveConnection.write_rpc(GET_UNCONFIRMED_HEADERS_REQUEST)`
3. `cluster/master.py` → `RootState.create_block_to_mine(header_list, address)`
4. `cluster/miner.py` → `Miner._mine_new_block_async()` → `add_block_async_func(block)`
5. `cluster/master.py` → `MasterServer.add_root_block(block)` (L1276)
6. `cluster/master.py` → `RootState.add_block(rootBlock)`
7. `cluster/master.py` → `MasterServer.broadcast_rpc(ADD_ROOT_BLOCK_REQUEST)`

## 4. 跨分片交易流程

```mermaid
sequenceDiagram
    participant TxSender
    participant ShardA
    participant ShardB
    participant SlaveA
    participant SlaveB
    participant Master

    TxSender->>ShardA: sendRawTransaction(to=address on ShardB)
    ShardA->>ShardA: tx.set_quark_chain_config()
    ShardA->>ShardA: is_cross_shard = (from != to)
    ShardA->>ShardA: validate _is_neighbor() for xshard tx
    ShardA->>ShardA: add_tx(tx) → tx_queue
    ShardA->>ShardA: miner打包 → run_block()
    ShardA->>ShardA: __run_cross_shard_tx_with_cursor() process deposits
    ShardA->>ShardA: 执行跨分片交易 → xshard deposit

    Note over ShardA: 新区块包含跨分片交易
    ShardA->>SlaveA: add_block() → 收集 xshard_list
    SlaveA->>Master: broadcast_xshard_tx_list(block, xshard_list)
    Master->>SlaveB: ADD_XSHARD_TX_LIST_REQUEST (batch)
    SlaveB->>ShardB: handle_add_xshard_tx_list_request()
    ShardB->>ShardB: add_cross_shard_tx_list_by_minor_block_hash()
    ShardB->>ShardB: persist xshard deposits to DB

    Note over ShardB: 当ShardB打包新块时
    ShardB->>ShardB: run_block() → __run_cross_shard_tx_with_cursor()
    ShardB->>ShardB: XshardTxCursor 读取 xshard deposits
    ShardB->>ShardB: apply_xshard_deposit() → 资产转移
```

**关键函数调用链:**
1. `cluster/shard_state.py` → `ShardState.add_tx(tx)` 检查 cross-shard
2. `cluster/shard.py` → `Shard.add_block(block)` 收集 xshard_list (L743)
3. `cluster/slave.py` → `SlaveServer.broadcast_xshard_tx_list()` (L1088)
4. `cluster/slave.py` → `SlaveConnection.handle_add_xshard_tx_list_request()` (L765)
5. `cluster/shard_state.py` → `ShardState.add_cross_shard_tx_list_by_minor_block_hash()`
6. `cluster/shard_state.py` → `ShardState.__run_cross_shard_tx_with_cursor()`
7. `cluster/evm/messages.py` → `apply_xshard_deposit()`

## 5. P2P 节点发现与同步

```mermaid
sequenceDiagram
    participant P2PManager
    participant QuarkServer
    participant Kademlia DHT
    participant QuarkPeer
    participant SecurePeer
    participant MasterServer
    participant Synchronizer

    P2PManager->>P2PManager: __init__() generate ECIES keys
    P2PManager->>QuarkServer: start()
    QuarkServer->>Kademlia DHT: discovery loop
    Kademlia DHT->>Kademlia DHT: find nodes from bootnodes

    alt new peer found
        QuarkServer->>QuarkPeer: TCP handshake
        QuarkPeer->>QuarkPeer: ECIES key exchange
        QuarkPeer->>SecurePeer: create SecurePeer
        SecurePeer->>MasterServer: do_sub_proto_handshake()
        MasterServer->>MasterServer: create_peer_cluster_connections(cluster_peer_id)
        MasterServer->>SlaveConn: CREATE_CLUSTER_PEER_CONNECTION_REQUEST [broadcast]
        SlaveConn->>Shard: create_peer_shard_connections()
        Shard->>Shard: peers[cluster_peer_id] = PeerShardConnection

        SecurePeer->>Synchronizer: add_sync_task()
        Synchronizer->>MasterServer: handle_new_root_block_header()
        MasterServer->>Synchronizer: add_task(header, peer)
        Synchronizer->>Synchronizer: __run() pick best task
        Synchronizer->>SyncTask: new SyncTask(header, peer)
        SyncTask->>SyncTask: __find_ancestor() n-ary search
        SyncTask->>SecurePeer: GET_ROOT_BLOCK_HEADER_LIST_WITH_SKIP_REQUEST
        SecurePeer-->>SyncTask: block header list
        SyncTask->>SecurePeer: GET_ROOT_BLOCK_LIST_REQUEST
        SecurePeer-->>SyncTask: root blocks
        loop per block
            SyncTask->>MasterServer: __add_block(root_block)
            MasterServer->>MasterServer: add_root_block(block)
        end
    end
```

**关键函数调用链:**
1. `p2p/p2p_manager.py` → `P2PManager.start()` (L418)
2. `p2p/p2p_server.py` → `QuarkServer.run()` (Trinity discovery)
3. `p2p/peer.py` → `BasePeerPool._handshake_with_peer()`
4. `p2p/p2p_manager.py` → `SecurePeer.do_sub_proto_handshake()` (L146)
5. `p2p/p2p_manager.py` → `SecurePeer.start()` (L218) → `master.create_peer_cluster_connections()`
6. `cluster/master.py` → `MasterServer.handle_new_root_block_header()` (L1273)
7. `cluster/master.py` → `Synchronizer.add_task()` → `SyncTask.sync()`

## 6. JSON-RPC 查询流程（eth_getBalance）

```mermaid
sequenceDiagram
    participant Client
    participant JSONRPCServer
    participant MasterServer
    participant SlaveConn
    participant SlaveServer
    participant ShardState

    Client->>JSONRPCServer: eth_getBalance(address, blockNumber)
    JSONRPCServer->>JSONRPCServer: decode address to QuarkChain Address
    JSONRPCServer->>MasterServer: get_primary_account_data(address, block_height)
    MasterServer->>MasterServer: get_full_shard_id_by_full_shard_key(address)
    MasterServer->>SlaveConn: GET_ACCOUNT_DATA_REQUEST [to specific slave]
    SlaveConn->>SlaveServer: handle_get_account_data_request()
    SlaveServer->>SlaveServer: get_account_data(address, block_height)
    loop per shard on this slave
        SlaveServer->>ShardState: get_balances(address)
        ShardState->>ShardState: state.get_balance(address)
        ShardState->>ShardState: state.get_nonce(address)
        ShardState->>ShardState: state.get_code(address)
        ShardState->>ShardState: get_mining_info(address) (PoSW)
        ShardState-->>SlaveServer: AccountBranchData
    end
    SlaveServer-->>SlaveConn: AccountBranchData list
    SlaveConn-->>MasterServer: response
    MasterServer-->>JSONRPCServer: response
    JSONRPCServer-->>Client: balance (hex)
```

**关键函数调用链:**
1. `cluster/jsonrpc.py` → `handle_eth_getBalance()` (L1122)
2. `cluster/jsonrpc.py` → `encode_address(eth_addr, shard)` → Address
3. `cluster/master.py` → `MasterServer.get_primary_account_data(address)` (L1205)
4. `cluster/master.py` → `SlaveConnection.write_rpc(GET_ACCOUNT_DATA_REQUEST)` (L1183)
5. `cluster/slave.py` → `MasterConnection.handle_get_account_data_request()` (L298)
6. `cluster/slave.py` → `SlaveServer.get_account_data()` (L1255)
7. `cluster/shard_state.py` → `ShardState.get_balances()` / `get_transaction_count()`

## 7. 远程挖矿工作分配流程

```mermaid
sequenceDiagram
    participant RemoteMiner
    participant JSONRPCServer
    participant MasterServer
    participant RootMiner
    participant SlaveConn
    participant ShardMiner

    RemoteMiner->>JSONRPCServer: eth_getWork(fullShardKey, coinbaseAddr)
    JSONRPCServer->>MasterServer: get_work(branch, coinbase_addr)
    alt root chain (branch is None)
        MasterServer->>RootMiner: get_work(coinbase_addr)
        RootMiner->>RootMiner: check cached work
        alt work expired
            RootMiner->>MasterServer: create block to mine
        end
        RootMiner-->>MasterServer: MiningWork {hash, height, diff}
    else shard chain
        MasterServer->>SlaveConn: GET_WORK_REQUEST
        SlaveConn->>ShardMiner: get_work(coinbase_addr)
        ShardMiner->>ShardMiner: check cached work
        ShardMiner-->>SlaveConn: MiningWork
        SlaveConn-->>MasterServer: GetWorkResponse
    end
    MasterServer-->>JSONRPCServer: GetWorkResponse
    JSONRPCServer-->>RemoteMiner: [hash, target, height]

    RemoteMiner->>JSONRPCServer: eth_submitWork(fullShardKey, nonce, mixHash)
    JSONRPCServer->>MasterServer: submit_work(branch, header_hash, nonce, mixhash)
    alt root chain
        MasterServer->>RootMiner: submit_work(nonce, mixHash)
        RootMiner->>RootMiner: verify header in work_map
        RootMiner->>RootMiner: set nonce + mixHash
        RootMiner->>RootMiner: sign with root_signer_private_key
        RootMiner->>MasterServer: add_root_block_from_miner(block)
    else shard chain
        MasterServer->>SlaveConn: SUBMIT_WORK_REQUEST
        SlaveConn->>ShardMiner: submit_work(nonce, mixHash)
        ShardMiner->>ShardMiner: verify
        ShardMiner->>Shard: handle_new_block(block)
    end
    MasterServer-->>JSONRPCServer: True/False
    JSONRPCServer-->>RemoteMiner: success boolean
```

**关键函数调用链:**
1. `cluster/jsonrpc.py` → `handle_eth_getWork()` (L1017)
2. `cluster/master.py` → `MasterServer.get_work(branch, recipient)` (L1674)
3. `cluster/miner.py` → `Miner.get_work(coinbase_addr)` (L271)
4. `cluster/jsonrpc.py` → `handle_eth_submitWork()`
5. `cluster/master.py` → `MasterServer.submit_work(branch, ...)` (L1695)
6. `cluster/miner.py` → `Miner.submit_work(nonce, mixHash)` (L301)

## 8. WebSocket 订阅事件

```mermaid
sequenceDiagram
    participant WSClient
    participant WSHandler
    participant PublicFilterAPI
    participant EventSystem
    participant ShardState

    WSClient->>WSHandler: ws.subscribe("newHeads") / "newPendingTransactions" / "logs"
    WSHandler->>PublicFilterAPI: NewHeads() / NewPendingTransactions() / Logs()
    PublicFilterAPI->>EventSystem: SubscribeNewHeads() / SubscribePendingTxs() / SubscribeLogs()
    EventSystem->>ShardState: register callback

    loop new block
        ShardState->>EventSystem: emit new block event
        EventSystem->>PublicFilterAPI: notify subscription
        PublicFilterAPI->>PublicFilterAPI: encode block/tx/log
        PublicFilterAPI->>WSHandler: notify
        WSHandler->>WSClient: WebSocket frame
    end

    loop new tx enters pool
        ShardState->>EventSystem: emit pending tx event
        EventSystem->>PublicFilterAPI: notify
        PublicFilterAPI->>WSHandler: encode tx
        WSHandler->>WSClient: WebSocket frame
    end
```

## RPC 操作码汇总

### ClusterOp (Master ↔ Slave)

| 操作码 | 方向 | 说明 |
|--------|------|------|
| ADD_TRANSACTION_REQUEST | Master→Slave | 添加交易 |
| ADD_ROOT_BLOCK_REQUEST | Master→Slave | 添加根块 |
| ADD_MINOR_BLOCK_HEADER_REQUEST | Slave→Master | 提交分片区块头 |
| SYNC_MINOR_BLOCK_LIST_REQUEST | Master→Slave | 同步分片块列表 |
| GET_UNCONFIRMED_HEADERS_REQUEST | Master→Slave | 获取未确认区块头 |
| GET_ACCOUNT_DATA_REQUEST | Master→Slave | 查询账户数据 |
| GET_WORK_REQUEST / SUBMIT_WORK_REQUEST | Master↔Slave | 挖矿工作 |
| ADD_XSHARD_TX_LIST_REQUEST | Master→Slave | 添加跨分片交易 |
| CREATE_CLUSTER_PEER_CONNECTION_REQUEST | Master→Slave | 创建 P2P 连接 |
| MINE_REQUEST | Master→Slave | 挖矿控制 |
| GET_NEXT_BLOCK_TO_MINE_REQUEST | Master→Slave | 获取待挖块 |

### CommandOp (P2P 分片间通信)

| 操作码 | 类型 | 说明 |
|--------|------|------|
| NEW_BLOCK_MINOR | Command (单向) | 新区块广播 |
| NEW_MINOR_BLOCK_HEADER_LIST | Command (单向) | 新区块头广播 |
| NEW_TRANSACTION_LIST | Command (单向) | 新交易广播 |
| GET_MINOR_BLOCK_HEADER_LIST_REQUEST | RPC | 查询区块头 |
| GET_MINOR_BLOCK_HEADER_LIST_WITH_SKIP_REQUEST | RPC | 跳读查询 |
| GET_MINOR_BLOCK_LIST_REQUEST | RPC | 查询区块列表 |
