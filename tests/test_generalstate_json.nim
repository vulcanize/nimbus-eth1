# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[strutils, tables, json, os, sets, options],
  ./test_helpers, ./test_allowed_to_fail,
  ../nimbus/core/executor, test_config,
  ../nimbus/transaction,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/db/accounts_cache,
  ../nimbus/common/common,
  ../nimbus/utils/[utils, debug],
  ../tools/common/helpers as chp,
  ../tools/evmstate/helpers,
  ../tools/common/state_clearing,
  eth/trie/trie_defs,
  unittest2,
  stew/[results, byteutils]

type
  Tester = object
    name: string
    header: BlockHeader
    pre: JsonNode
    tx: Transaction
    expectedHash: Hash256
    expectedLogs: Hash256
    chainConfig: ChainConfig
    debugMode: bool
    trace: bool
    index: int
    fork: string

proc toBytes(x: string): seq[byte] =
  result = newSeq[byte](x.len)
  for i in 0..<x.len: result[i] = x[i].byte

method getAncestorHash*(vmState: BaseVMState; blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  if blockNumber >= vmState.blockNumber:
    return
  elif blockNumber < 0:
    return
  elif blockNumber < vmState.blockNumber - 256:
    return
  else:
    return keccakHash(toBytes($blockNumber))

proc dumpDebugData(tester: Tester, vmState: BaseVMState, gasUsed: GasInt, success: bool) =
  let tracingResult = if tester.trace: vmState.getTracingResult() else: %[]
  let debugData = %{
    "gasUsed": %gasUsed,
    "structLogs": tracingResult,
    "accounts": vmState.dumpAccounts()
  }
  let status = if success: "_success" else: "_failed"
  writeFile(tester.name & "_" & tester.fork & "_" & $tester.index & status & ".json", debugData.pretty())

proc testFixtureIndexes(tester: Tester, testStatusIMPL: var TestStatus) =
  let
    com    = CommonRef.new(newMemoryDB(), tester.chainConfig, getConfiguration().pruning)
    parent = BlockHeader(stateRoot: emptyRlpHash)

  let vmState = BaseVMState.new(
      parent      = parent,
      header      = tester.header,
      com         = com,
      tracerFlags = (if tester.trace: {TracerFlags.EnableTracing} else: {}),
    )

  var gasUsed: GasInt
  let sender = tester.tx.getSender()
  let fork = com.toEVMFork(tester.header.forkDeterminationInfoForHeader)

  vmState.mutateStateDB:
    setupStateDB(tester.pre, db)

    # this is an important step when using accounts_cache
    # it will affect the account storage's location
    # during the next call to `getComittedStorage`
    db.persist()

  defer:
    let obtainedHash = vmState.readOnlyStateDB.rootHash
    check obtainedHash == tester.expectedHash
    let logEntries = vmState.getAndClearLogEntries()
    let actualLogsHash = rlpHash(logEntries)
    check(tester.expectedLogs == actualLogsHash)
    if tester.debugMode:
      let success = tester.expectedLogs == actualLogsHash and obtainedHash == tester.expectedHash
      tester.dumpDebugData(vmState, gasUsed, success)

  let rc = vmState.processTransaction(
                tester.tx, sender, tester.header, fork)
  if rc.isOk:
    gasUsed = rc.value

  let miner = tester.header.coinbase
  coinbaseStateClearing(vmState, miner, fork)

proc testFixture(fixtures: JsonNode, testStatusIMPL: var TestStatus,
                 trace = false, debugMode = false) =
  var tester: Tester
  var fixture: JsonNode
  for label, child in fixtures:
    fixture = child
    tester.name = label
    break

  tester.pre = fixture["pre"]
  tester.header = parseHeader(fixture["env"])
  tester.trace = trace
  tester.debugMode = debugMode

  let
    post   = fixture["post"]
    txData = fixture["transaction"]
    conf   = getConfiguration()

  template prepareFork(forkName: string) =
    try:
      tester.chainConfig = getChainConfig(forkName)
    except ValueError as ex:
      debugEcho ex.msg
      return

  template runSubTest(subTest: JsonNode) =
    tester.expectedHash = Hash256.fromJson(subTest["hash"])
    tester.expectedLogs = Hash256.fromJson(subTest["logs"])
    tester.tx = parseTx(txData, subTest["indexes"])
    tester.testFixtureIndexes(testStatusIMPL)

  if conf.fork.len > 0:
    if not post.hasKey(conf.fork):
      debugEcho "selected fork not available: " & conf.fork
      return

    tester.fork = conf.fork
    let forkData = post[conf.fork]
    prepareFork(conf.fork)
    if conf.index.isNone:
      for subTest in forkData:
        runSubTest(subTest)
        inc tester.index
    else:
      tester.index = conf.index.get()
      if tester.index > forkData.len or tester.index < 0:
        debugEcho "selected index out of range(0-$1), requested $2" %
          [$forkData.len, $tester.index]
        return

      let subTest = forkData[tester.index]
      runSubTest(subTest)
  else:
    for forkName, forkData in post:
      prepareFork(forkName)
      tester.fork = forkName
      tester.index = 0
      for subTest in forkData:
        runSubTest(subTest)
        inc tester.index

proc generalStateJsonMain*(debugMode = false) =
  const
    legacyFolder = "eth_tests" / "LegacyTests" / "Constantinople" / "GeneralStateTests"
    newFolder = "eth_tests" / "GeneralStateTests"

  let config = getConfiguration()
  if config.testSubject == "" or not debugMode:
    # run all test fixtures
    if config.legacy:
      suite "generalstate json tests":
        jsonTest(legacyFolder, "GeneralStateTests", testFixture, skipGSTTests)
    else:
      suite "new generalstate json tests":
        jsonTest(newFolder, "newGeneralStateTests", testFixture, skipNewGSTTests)
  else:
    # execute single test in debug mode
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let folder = if config.legacy: legacyFolder else: newFolder
    let path = "tests" / "fixtures" / folder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixture(n, testStatusIMPL, config.trace, true)

when isMainModule:
  import std/times
  var message: string

  let start = getTime()

  ## Processing command line arguments
  if processArguments(message) != Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  generalStateJsonMain(true)
  let elpd = getTime() - start
  echo "TIME: ", elpd
