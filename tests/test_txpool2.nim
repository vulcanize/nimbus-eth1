import
  std/[math, tables, times],
  eth/[keys],
  stew/[byteutils, results], unittest2,
  ../nimbus/db/state_db,
  ../nimbus/core/chain,
  ../nimbus/core/clique/[clique_sealer, clique_desc],
  ../nimbus/[config, transaction, constants],
  ../nimbus/core/tx_pool,
  ../nimbus/core/casper,
  ../nimbus/core/executor,
  ../nimbus/common/common,
  ../nimbus/[vm_state, vm_types],
  ./test_txpool/helpers,
  ./macro_assembler

const
  baseDir = [".", "tests"]
  repoDir = [".", "customgenesis"]
  genesisFile = "merge.json"

type
  TestEnv = object
    nonce   : uint64
    chainId : ChainId
    vaultKey: PrivateKey
    conf    : NimbusConf
    com     : CommonRef
    chain   : ChainRef
    xp      : TxPoolRef

const
  signerKeyHex = "9c647b8b7c4e7c3490668fb6c11473619db80c93704c70893d3813af4090c39c"
  vaultKeyHex = "63b508a03c3b5937ceb903af8b1b0c191012ef6eb7e9c3fb7afa94e5d214d376"
  recipient = hexToByteArray[20]("0000000000000000000000000000000000000318")
  feeRecipient = hexToByteArray[20]("0000000000000000000000000000000000000212")
  contractCode = evmByteCode:
    PrevRandao    # VAL
    Push1 "0x11"  # KEY
    Sstore        # OP
    Stop

proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

func gwei(n: uint64): GasInt {.compileTime.} =
  GasInt(n * (10'u64 ^ 9'u64))

proc makeTx*(t: var TestEnv, recipient: EthAddress, amount: UInt256, payload: openArray[byte] = []): Transaction =
  const
    gasLimit = 75000.GasInt
    gasPrice = 30.gwei

  let tx = Transaction(
    txType  : TxLegacy,
    chainId : t.chainId,
    nonce   : AccountNonce(t.nonce),
    gasPrice: gasPrice,
    gasLimit: gasLimit,
    to      : some(recipient),
    value   : amount,
    payload : @payload
  )

  inc t.nonce
  signTransaction(tx, t.vaultKey, t.chainId, eip155 = true)

proc initEnv(ttd: Option[UInt256] = none(UInt256)): TestEnv =
  var
    conf = makeConfig(@[
      "--engine-signer:658bdf435d810c91414ec09147daa6db62406379",
      "--custom-network:" & genesisFile.findFilePath(baseDir,repoDir).value
    ])

  conf.networkParams.genesis.alloc[recipient] = GenesisAccount(
    code: contractCode
  )

  if ttd.isSome:
    conf.networkParams.config.terminalTotalDifficulty = ttd

  let
    com = CommonRef.new(
      newMemoryDb(),
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )
    chain = newChain(com)

  com.initializeEmptyDb()

  result = TestEnv(
    conf: conf,
    com: com,
    chain: chain,
    xp: TxPoolRef.new(com, conf.engineSigner),
    vaultKey: privKey(vaultKeyHex),
    chainId: conf.networkParams.config.chainId,
    nonce: 0'u64
  )

const
  amount = 1000.u256
  slot = 0x11.u256
  prevRandao = EMPTY_UNCLE_HASH # it can be any valid hash

proc runTxPoolCliqueTest*() =
  var
    env = initEnv()

  var
    tx = env.makeTx(recipient, amount)
    xp = env.xp
    conf = env.conf
    chain = env.chain
    clique = env.chain.clique
    body: BlockBody
    blk: EthBlock
    com = env.chain.com

  let signerKey = privKey(signerKeyHex)
  proc signerFunc(signer: EthAddress, msg: openArray[byte]):
                  Result[RawSignature, cstring] {.gcsafe.} =
    doAssert(signer == conf.engineSigner)
    let
      data = keccakHash(msg)
      rawSign  = sign(signerKey, SkMessage(data.data)).toRaw

    ok(rawSign)
  clique.authorize(conf.engineSigner, signerFunc)

  suite "Test TxPool with Clique sealer":
    test "TxPool addLocal":
      let res = xp.addLocal(tx, force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return

    test "TxPool jobCommit":
      check xp.nItems.total == 1

    test "TxPool ethBlock":
      blk = xp.ethBlock()
      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles
      )
      check blk.txs.len == 1

    test "Clique seal":
      let rx = clique.seal(blk)
      check rx.isOk
      if rx.isErr:
        debugEcho rx.error
        return

    test "Store generated block in block chain database":
      xp.chain.clearAccounts
      check xp.chain.vmState.processBlock(com.poa, blk.header, body).isOK

      let vmstate2 = BaseVMState.new(blk.header, com)
      check vmstate2.processBlock(com.poa, blk.header, body).isOK

    test "Clique persistBlocks":
      let rr = chain.persistBlocks([blk.header], [body])
      check rr == ValidationResult.OK

proc runTxPoolPosTest*() =
  var
    env = initEnv(some(100.u256))

  var
    tx = env.makeTx(recipient, amount)
    xp = env.xp
    com = env.com
    chain = env.chain
    body: BlockBody
    blk: EthBlock

  suite "Test TxPool with PoS block":
    test "TxPool addLocal":
      let res = xp.addLocal(tx, force = true)
      check res.isOk
      if res.isErr:
        debugEcho res.error
        return

    test "TxPool jobCommit":
      check xp.nItems.total == 1

    test "TxPool ethBlock":
      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = feeRecipient
      com.pos.timestamp = getTime()

      blk = xp.ethBlock()

      check com.isBlockAfterTtd(blk.header)

      body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles
      )
      check blk.txs.len == 1

    test "PoS persistBlocks":
      let rr = chain.persistBlocks([blk.header], [body])
      check rr == ValidationResult.OK

    test "validate TxPool prevRandao setter":
      var sdb = newAccountStateDB(com.db.db, blk.header.stateRoot, pruneTrie = false)
      let (val, ok) = sdb.getStorage(recipient, slot)
      let randao = Hash256(data: val.toBytesBE)
      check ok
      check randao == prevRandao

    test "feeRecipient rewarded":
      check blk.header.coinbase == feeRecipient
      var sdb = newAccountStateDB(com.db.db, blk.header.stateRoot, pruneTrie = false)
      let bal = sdb.getBalance(feeRecipient)
      check not bal.isZero

proc runTxHeadDelta*(noisy = true) =
  ## see github.com/status-im/nimbus-eth1/issues/1031

  suite "TxPool: Synthesising blocks (covers issue #1031)":
    test "Packing and adding multiple blocks to chain":
      var
        env = initEnv(some(100.u256))
        xp = env.xp
        com = env.com
        chain = env.chain
        head = com.db.getCanonicalHead()
        timestamp = head.timestamp

      const
        txPerblock = 20
        numBlocks = 10

      # setTraceLevel()

      block:
        for n in 0..<numBlocks:

          for tn in 0..<txPerblock:
            let tx = env.makeTx(recipient, amount)
            # Instead of `add()`, the functions `addRemote()` or `addLocal()`
            # also would do.
            xp.add(tx)

          noisy.say "***", "txDB",
            &" n={n}",
            # pending/staged/packed : total/disposed
            &" stats={xp.nItems.pp}"

          timestamp = timestamp + 1.seconds
          com.pos.prevRandao = prevRandao
          com.pos.timestamp  = timestamp
          com.pos.feeRecipient = feeRecipient

          var blk = xp.ethBlock()
          check com.isBlockAfterTtd(blk.header)

          let body = BlockBody(
            transactions: blk.txs,
            uncles: blk.uncles)

          # Commit to block chain
          check chain.persistBlocks([blk.header], [body]).isOk

          # Synchronise TxPool against new chain head, register txs differences.
          # In this particular case, these differences will simply flush the
          # packer bucket.
          check xp.smartHead(blk.header)

          # Move TxPool chain head to new chain head and apply delta jobs
          check xp.nItems.staged == 0
          check xp.nItems.packed == 0

          setErrorLevel() # in case we set trace level

      check com.syncCurrent == 10.toBlockNumber
      head = com.db.getBlockHeader(com.syncCurrent)
      var
        sdb = newAccountStateDB(com.db.db, head.stateRoot, pruneTrie = false)

      let
        expected = u256(txPerblock * numBlocks) * amount
        balance = sdb.getBalance(recipient)
      check balance == expected

when isMainModule:
  const
    noisy = defined(debug)

  setErrorLevel() # mute logger

  runTxPoolCliqueTest()
  runTxPoolPosTest()
  noisy.runTxHeadDelta

# End
