# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  stew/results,
  ../common/common

{.push raises: [].}

# https://eips.ethereum.org/EIPS/eip-4895
proc validateWithdrawals*(
    com: CommonRef, header: BlockHeader, body: BlockBody
): Result[void, string] =

  if com.forkGTE(Shanghai):
    if header.withdrawalsRoot.isNone:
      return err("Post-Shanghai block header must have withdrawalsRoot")
    elif body.withdrawals.isNone:
      return err("Post-Shanghai block body must have withdrawals")
    else:
      try:
        if body.withdrawals.get.calcWithdrawalsRoot != header.withdrawalsRoot.get:
          return err("Mismatched withdrawalsRoot blockNumber =" & $header.blockNumber)
      except RlpError as ex:
        return err(ex.msg)
  else:
    if header.withdrawalsRoot.isSome:
      return err("Pre-Shanghai block header must not have withdrawalsRoot")
    elif body.withdrawals.isSome:
      return err("Pre-Shanghai block body must not have withdrawals")

  return ok()
