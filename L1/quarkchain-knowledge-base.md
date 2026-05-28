# QuarkChain 知识库

## 1. 项目概览

QuarkChain 是一个 Layer 2 状态分片（State Sharding）协议，由两部分组成：
- **PyQuarkChain** (`pyquarkchain/`): Python 参考实现，协议设计的原始参考
- **GoQuarkChain** (`goquarkchain/`): Go 语言高性能实现，生产级部署使用

### 核心特性

| 特性 | 说明 |
|------|------|
| 状态分片 | 全局状态分布在独立分片，每个分片独立处理交易 |
| 线性扩展 | TPS 随分片数量线性增长，测试网达 10,000+ TPS |
| 跨分片交易 | 原生支持跨分片代币转移 |
| 动态扩容 | 支持运行时添加新分片 |
| 多共识算法 | 每个分片可配置不同 PoW 算法 |
| EVM 兼容 | 完全兼容以太坊智能合约 |
| P2P 网络 | Kademlia DHT 节点发现 + ECIES 加密传输 |
| PoSW | Proof-of-Staked-Work 防止 51% 攻击 |
| Guardian | 守护人机制为根链提供额外安全层 |

---

## 2. 两层架构

### 2.1 Root Chain（根链层）

**职责:**
- 协调所有分片
- 打包各分片的区块头到 RootBlock
- 处理跨分片交易确认
- 维护全局状态（网络配置、难度目标等）
- 保护网络安全

**核心数据结构:**
- `RootBlock`: 包含多个 MinorBlockHeader 的列表
- `RootBlockHeader`: 包含 prev_hash, total_difficulty, coinbase 等信息
- `RootBlockChain`: 根链的完整状态和持久化

### 2.2 Shard Chains（分片层）

**职责:**
- 并行处理交易
- 独立维护各自的 EVM 状态
- 独立挖矿（不同分片可配置不同共识算法）
- 处理跨分片交易存款

**核心数据结构:**
- `MinorBlock`: 包含 EVM 交易列表
- `MinorBlockHeader`: 包含 prev_hash, root_block_header, coinbase 等
- `MinorBlockChain`: 分片链的状态和持久化

### 2.3 RootBlock 结构

RootBlock 是 QuarkChain 的核心创新。每个 RootBlock 包含：
- 前驱根块哈希
- 总难度
- **多个 MinorBlockHeader 列表**（每个已初始化的分片一个）
- coinbase 奖励（合并所有分片奖励）
- PoSW 信息

```
RootBlock
├── header: RootBlockHeader
│   ├── hash_prev_block
│   ├── total_difficulty
│   ├── coinbase_address
│   ├── difficulty
│   ├── nonce
│   └── create_time
└── minor_block_header_list: [MinorBlockHeader, ...]
    ├── branch: Branch (full_shard_id)
    ├── height
    ├── hash_prev_minor_block
    ├── hash_prev_root_block
    ├── coinbase_amount_map
    └── ...
```

---

## 3. 关键概念

### 3.1 Branch 与 FullShardId

```
Branch = full_shard_id = (chain_id << 16) | (shard_id)

FullShardKey = (chain_id << 16) | shard_id
FullShardId  = FullShardKey (+ boundary bits for sharding)
```

- **chain_id**: 集群 ID，不同集群的 chain_id 不同
- **shard_id**: 分片 ID，在一个集群内的分片序号
- **full_shard_key**: 地址中的 4 字节分片标识（20 字节 recipient + 4 字节 full_shard_key = 24 字节）
- **full_shard_id**: 全局唯一分片标识

**ShardSize（分片大小）**:
- 当 shard_id >= shard_size 时，表示这是一个扩展分片
- shard_size 决定了初始分片数量（如 4 表示 4 个初始分片）
- 扩展分片的 full_shard_key 最高 2 位表示分片层级

### 3.2 地址格式

QuarkChain 地址 = **20 字节 recipient + 4 字节 full_shard_key** = 24 字节

```
Address:
├── recipient: bytes32 (20 bytes, left-padded)
└── full_shard_key: uint32 (4 bytes)

Eth 地址转换:
    eth_addr (20 bytes) → qkc_addr (24 bytes)
    追加 full_shard_key = full_shard_id
```

### 3.3 跨分片交易（Cross-Shard Transaction）

跨分片交易发生在 `from_full_shard_id != to_full_shard_id` 时。

**交易流程:**
1. 用户在分片 A 创建跨分片交易
2. 交易在分片 A 验证和执行（扣除发送方余额）
3. 分片 A 的区块包含 `CrossShardTransactionDeposit` 列表
4. 通过 Master → gRPC 广播到目标分片 B
5. 分片 B 的 `ShardState` 将存款持久化到数据库
6. 当分片 B 打包新区块时，从存款列表中消费
7. 执行 EVM 的 `apply_xshard_deposit()`，将资产转移到接收方

**邻居检查:**
- 跨分片交易要求源分片和目标分片是"邻居"
- 邻居定义：`is_neighbor(full_shard_id_1, full_shard_id_2)` 检查分片是否在同一个 shard_id 层级

### 3.4 交易类型

| 类型 | 说明 |
|------|------|
| `EVM_TX` | 标准以太坊交易（transfer 或 contract call） |
| `CROSS_SHARD_DEPOSIT` | 跨分片交易存款（由其他分片发起） |
| `CREATE_TOKEN_TX` | 创建新代币 |
| `TOKEN_TRANSFER_TX` | 代币转账（非 QKC） |

---

## 4. 共识机制

### 4.1 支持的共识算法

| 算法 | ConsensusType | 说明 | 适用链 |
|------|---------------|------|--------|
| Simulate | `POW_SIMULATE` | 随机 nonce，测试用 | 开发/测试 |
| Ethash | `POW_ETHASH` | 以太坊原始 PoW | 分片链 |
| Qkchash | `POW_QKCHASH` | QuarkChain 专用（内存密集） | 分片链 |
| DoubleSHA256 | `POW_DOUBLESHA256` | 简单 SHA256 两次 | 测试 |

### 4.2 难度调整

使用类以太坊的 EthDifficultyCalculator：
- 基于前一个块的时间差调整
- 如果当前块时间 < 父块时间 - 13s，难度增加
- 如果当前块时间 > 父块时间 + 2s，难度降低
- 公式: `difficulty = max(minimum_difficulty, parent_difficulty + parent_difficulty // 2048 * (1 if time_delta < 13 else -1))`

### 4.3 PoSW (Proof-of-Staked-Work)

- 通过在特定分片质押 QKC 来获得根链挖矿难度减免
- 质押越多，挖矿难度越低
- 防止 51% 攻击：攻击者需要同时控制大量质押和算力

### 4.4 Guardian 机制

- 守护人持有特殊私钥，可对根块签名
- 带 Guardian 签名的根块可获得进一步难度减免
- 作为 PoSW 之外的额外安全层

---

## 5. 集群配置

### 5.1 配置文件结构

```json
{
  "NETWORK_ID": 0,
  "CHAIN_SIZE": 4,
  "BASE_ETH_CHAIN_ID": 1,
  "SHARD_SIZE": 4,
  "CONSENSUS_CONFIG": {
    "TARGET_ROOT_BLOCK_TIME": 5,
    "TARGET_MINOR_BLOCK_TIME": 1
  },
  "ROOT": {
    "COINBASE_AMOUNT": 625000000000000000000,
    "COINBASE_ADDRESS": "0x0000000000000000000000000000000000000000",
    "EPOCH_INTERVAL": 100,
    "POSW_CONFIG": { ... },
    "GUARDIAN_PUBLIC_KEY": "..."
  },
  "CHAINS": [
    {
      "CHAIN_ID": 0,
      "SHARD_SIZE": 4,
      "SHARDS": [
        {"SHARD_ID": 0, "CONSENSUS_TYPE": "POW_ETHASH"},
        {"SHARD_ID": 1, "CONSENSUS_TYPE": "POW_ETHASH"},
        {"SHARD_ID": 2, "CONSENSUS_TYPE": "POW_QKCHASH"},
        {"SHARD_ID": 3, "CONSENSUS_TYPE": "POW_QKCHASH"}
      ]
    }
  ],
  "MASTER_LIST": [
    {"ID": 0, "HOST": "127.0.0.1", "PORT": 38001}
  ],
  "SLAVE_LIST": [
    {"ID": 0, "HOST": "127.0.0.1", "PORT": 38101, "CHAIN_ID": 0, "SHARD_ID": 0},
    {"ID": 1, "HOST": "127.0.0.1", "PORT": 38102, "CHAIN_ID": 0, "SHARD_ID": 1}
  ]
}
```

### 5.2 端口约定

| 服务 | 端口 | 说明 |
|------|------|------|
| P2P | 38291 | TCP + UDP，节点间通信 |
| Public RPC | 38391 | HTTP JSON-RPC，公开接口 |
| Private RPC | 38491 | HTTP JSON-RPC，管理接口 |
| gRPC | 38191 | Master ↔ Slave 内部通信 |
| WebSocket | 38590-38597 | 按分片的 WS 接口 |

---

## 6. 数据流

### 6.1 交易生命周期

```
用户创建交易 (eth_sendRawTransaction)
  │
  ├─ 1. 签名交易 (RLP 编码)
  │
  ├─ 2. 发送到分片的 JSON-RPC
  │     eth_sendRawTransaction(rlp_encoded_tx)
  │
  ├─ 3. 分片验证
  │     - 检查签名
  │     - 检查 nonce
  │     - 检查余额
  │     - 检查 gas
  │
  ├─ 4. 加入交易池 (TransactionQueue)
  │     - 按 gas price 排序
  │     - pending tx 通知 WebSocket 订阅者
  │
  ├─ 5. 矿工选择高 gas price 的交易
  │     - 构建 MinorBlock
  │     - 逐个执行 EVM
  │
  ├─ 6. PoW 计算找到 nonce
  │
  ├─ 7. 提交区块到分片链
  │     - 执行 validate_block()
  │     - 执行 run_block()
  │     - 更新 header_tip
  │
  ├─ 8. 广播
  │     - P2P 广播到同分片其他节点
  │     - 向 Master 提交区块头
  │     - 跨分片交易广播到目标分片
  │
  └─ 9. 根链确认
        - 下一个 RootBlock 包含该 MinorBlockHeader
        - 跨分片交易在目标分片消费
```

### 6.2 根块生命周期

```
RootBlock 生产循环:
  1. RootMiner 向所有 Slave 查询未确认分片区块头
  2. 按 full_shard_id 分组，过滤时间戳
  3. 创建 RootBlock（包含所有分片最新区块头）
  4. 计算 coinbase 奖励（分片奖励 + 根链奖励 + 税费）
  5. PoW 计算（Qkchash）
  6. 找到 nonce → 提交到根链
  7. 难度调整（PoSW + Guardian）
  8. 广播到所有 Slave 和 P2P peer
```

---

## 7. PyQuarkChain 与 GoQuarkChain 对比

| 维度 | PyQuarkChain | GoQuarkChain |
|------|-------------|-------------|
| 语言 | Python 3 | Go 1.14+ |
| 角色 | 参考实现 | 生产实现 |
| 并发模型 | asyncio 单线程事件循环 | 原生 goroutine 并发 |
| 存储 | RocksDB (via rocksdict) | RocksDB (via gorocksdb) |
| EVM | 纯 Python 实现 | 从 go-ethereum 移植 |
| 网络 | asyncio TCP + P2PManager | gRPC + P2P Server (RLPx) |
| RPC | 自定义 JSON-RPC HTTP | JSON-RPC + gRPC |
| 节点启动 | cluster.py 异步进程管理 | service/Node 服务栈模式 |
| 挖矿 | 子进程 POW | 内联 POW + C 扩展 qkchash |
| P2P | Trinity 改造 (Kademlia DHT) | go-ethereum 改造 (RLPx) |
| 代码量 | ~15,000 行 Python | ~20,000 行 Go |
| 适用场景 | 研究、协议验证 | 生产部署 |

### 架构差异要点

| 差异点 | PyQuarkChain | GoQuarkChain |
|--------|-------------|-------------|
| 进程模型 | Master 和 Slave 分别作为独立 Python 子进程 | 通过 service/Node 统一管理服务生命周期 |
| 通信 | asyncio TCP 自定义协议 + RPC 类型 | gRPC + protobuf |
| Slave 概念 | Slave = 一个 Shard 实例 | Slave = 一个进程，可管理多个 Shard |
| P2P | P2PManager 基于 Trinity 框架 | ProtocolManager 基于 go-ethereum P2P |
| 配置 | JSON 配置文件 + argparse | JSON 配置文件 + cobra 命令行 |
| API | jsonrpc.py 直接实现 | api_backend.go 实现 + rpc 层 |

---

## 8. 核心文件速查

### PyQuarkChain

| 文件 | 职责 |
|------|------|
| `quarkchain/core.py` | 所有核心类型定义（Address, Branch, Block, Tx 等） |
| `quarkchain/config.py` | 配置系统（QuarkChainConfig, ShardConfig 等） |
| `quarkchain/env.py` | 环境上下文（Env 类） |
| `quarkchain/cluster/master.py` | Master 服务器（~1900 行，核心逻辑） |
| `quarkchain/cluster/slave.py` | Slave 服务器（管理 Shard 实例） |
| `quarkchain/cluster/shard.py` | Shard 实例（分片状态、P2P、同步、矿工） |
| `quarkchain/cluster/shard_state.py` | 分片状态（EVM 执行、交易池、PoSW） |
| `quarkchain/cluster/root_state.py` | 根链状态管理 |
| `quarkchain/cluster/miner.py` | 通用矿工类（多共识算法支持） |
| `quarkchain/cluster/jsonrpc.py` | JSON-RPC HTTP 服务器（eth_* + quarkchain_* API） |
| `quarkchain/cluster/protocol.py` | 集群内协议层（ClusterConnection 等） |
| `quarkchain/cluster/rpc.py` | RPC 请求/响应类型定义 |
| `quarkchain/p2p/p2p_manager.py` | P2P 管理器（基于 Trinity） |

### GoQuarkChain

| 文件 | 职责 |
|------|------|
| `cluster/service/node.go` | 协议栈 Node（类似 Geth Node） |
| `cluster/master/handle.go` | Master 后端核心逻辑（~700 行） |
| `cluster/master/api_backend.go` | Master API 实现（eth_ + qkc_ 接口） |
| `cluster/master/master_grpc.go` | gRPC 服务端实现 |
| `cluster/master/peer.go` | P2P Peer 管理 |
| `cluster/slave/api.go` | 分片 PublicFilterAPI（eth_* 兼容） |
| `cluster/slave/backend.go` | 分片后端（交易执行、块管理） |
| `cluster/rpc/*.go` | gRPC 通信层 |
| `cluster/config/config.go` | 配置系统 |
| `core/types/*.go` | 区块/交易类型 |
| `consensus/qkchash/qkchash.go` | Qkchash 共识引擎 |
| `p2p/server.go` | P2P 服务器 |

---

## 9. 测试与开发工具

| 工具 | 位置 | 用途 |
|------|------|------|
| 集成测试 | `tests/` / `cmd/integrate_test/` | 端到端集群测试 |
| 负载测试 | `tests/loadtest/` | 压力测试，验证 TPS |
| 监控工具 | `cmd/stats/` (Go) / `quarkchain/tools/stats.py` (Py) | 集群状态监控 |
| 外部矿机 | `cmd/miner/` (Go) / `quarkchain/tools/external_miner.py` (Py) | 远程挖矿 |
| 集群部署工具 | `tests/loadtest/deployer/` | 多节点集群部署 |
| 数据库浏览器 | `quarkchain/tools/db_browser.py` | 检查持久化数据 |
| 余额查询 | `quarkchain/tools/query_balance.py` | 查询账户余额 |
| 重组检测 | `quarkchain/tools/reorg_detector.py` | 检测链重组 |

---

## 10. 安全机制

### 10.1 PoSW (Proof-of-Staked-Work)

- 矿工在链 0 分片 1 质押 QKC
- 质押量影响根块难度调整
- 无质押的矿工需更高算力才能挖矿
- 防止 51% 攻击的经济模型

### 10.2 Guardian 机制

- QuarkChain 团队持有 Guardian 私钥
- 可签名降低根块难度
- 作为 PoSW 的补充
- 紧急情况下可暂停攻击

### 10.3 P2P 安全

- ECIES 加密所有 P2P 通信
- Kademlia DHT 节点发现
- 节点握手验证网络 ID 和创世块哈希
- 端口 38291 需对外开放（AWS 安全组等）

### 10.4 网络隔离

- Public RPC (38391): 只暴露查询接口（eth_ 等）
- Private RPC (38491): 管理接口（setMining 等），仅限本地
- gRPC (38191): 集群内部通信，不对外暴露
