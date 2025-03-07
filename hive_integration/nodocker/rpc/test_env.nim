# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os],
  eth/p2p as ethp2p,
  stew/shims/net as stewNet,
  stew/results,
  chronos, json_rpc/[rpcserver, rpcclient],
  ../../../nimbus/sync/protocol,
  ../../../nimbus/common,
  ../../../nimbus/config,
  ../../../nimbus/rpc,
  ../../../nimbus/core/[chain, tx_pool, sealer],
  ../../../tests/test_helpers,
  ./vault

type
  StopServerProc = proc(srv: RpcServer)

  TestEnv* = ref object
    vault*: Vault
    rpcClient*: RpcClient
    rpcServer: RpcServer
    sealingEngine: SealingEngineRef
    stopServer: StopServerProc

const
  initPath = "hive_integration" / "nodocker" / "rpc" / "init"
  gasPrice* = 30000000000 # 30 Gwei or 30 * pow(10, 9)
  chainID*  = ChainID(7)

proc manageAccounts(ctx: EthContext, conf: NimbusConf) =
  if string(conf.importKey).len > 0:
    let res = ctx.am.importPrivateKey(string conf.importKey)
    if res.isErr:
      echo res.error()
      quit(QuitFailure)

proc setupRpcServer(ctx: EthContext, com: CommonRef,
                    ethNode: EthereumNode, txPool: TxPoolRef,
                    conf: NimbusConf): RpcServer  =
  let rpcServer = newRpcHttpServer([initTAddress(conf.rpcAddress, conf.rpcPort)])
  setupCommonRpc(ethNode, conf, rpcServer)
  setupEthRpc(ethNode, ctx, com, txPool, rpcServer)

  rpcServer.start()
  rpcServer

proc setupWsRpcServer(ctx: EthContext, com: CommonRef,
                      ethNode: EthereumNode, txPool: TxPoolRef,
                      conf: NimbusConf): RpcServer  =
  let rpcServer = newRpcWebSocketServer(initTAddress(conf.wsAddress, conf.wsPort))
  setupCommonRpc(ethNode, conf, rpcServer)
  setupEthRpc(ethNode, ctx, com, txPool, rpcServer)

  rpcServer.start()
  rpcServer

proc stopRpcHttpServer(srv: RpcServer) =
  let rpcServer = RpcHttpServer(srv)
  waitFor rpcServer.stop()
  waitFor rpcServer.closeWait()

proc stopRpcWsServer(srv: RpcServer) =
  let rpcServer = RpcWebSocketServer(srv)
  rpcServer.stop()
  waitFor rpcServer.closeWait()

proc setupEnv*(): TestEnv =
  let conf = makeConfig(@[
    "--prune-mode:archive",
    # "--nat:extip:0.0.0.0",
    "--network:7",
    "--import-key:" & initPath / "private-key",
    "--engine-signer:658bdf435d810c91414ec09147daa6db62406379",
    "--custom-network:" & initPath / "genesis.json",
    "--rpc",
    "--rpc-api:eth,debug",
    # "--rpc-address:0.0.0.0",
    "--rpc-port:8545",
    "--ws",
    "--ws-api:eth,debug",
    # "--ws-address:0.0.0.0",
    "--ws-port:8546"
  ])

  let
    ethCtx  = newEthContext()
    ethNode = setupEthNode(conf, ethCtx, eth)
    com     = CommonRef.new(newMemoryDb(),
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )

  manageAccounts(ethCtx, conf)
  com.initializeEmptyDb()

  let chainRef = newChain(com)
  let txPool = TxPoolRef.new(com, conf.engineSigner)
  let sealingEngine = SealingEngineRef.new(
    chainRef, ethCtx, conf.engineSigner,
    txPool, EngineStopped
  )

  let rpcServer = setupRpcServer(ethCtx, com, ethNode, txPool, conf)
  let rpcClient = newRpcHttpClient()
  waitFor rpcClient.connect("127.0.0.1", Port(8545), false)
  let stopServer = stopRpcHttpServer

  sealingEngine.start()

  let t = TestEnv(
    rpcClient: rpcClient,
    sealingEngine: sealingEngine,
    rpcServer: rpcServer,
    vault : newVault(chainID, gasPrice, rpcClient),
    stopServer: stopServer
  )

  result = t

proc stopEnv*(t: TestEnv) =
  waitFor t.rpcClient.close()
  waitFor t.sealingEngine.stop()
  t.stopServer(t.rpcServer)
