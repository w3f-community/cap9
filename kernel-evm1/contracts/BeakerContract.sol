pragma solidity ^0.4.17;

import "./Kernel.sol";
import "./ProcedureTable.sol";
import "./KernelStorage.sol";

contract BeakerContract is IKernel {

    function this_proc() internal view returns (Procedure memory) {
        return _getProcedureByKey(_getCurrentProcedure());
    }

    // TODO: this doesn't actually use caps, just reads raw
    function read(uint256 location) internal view returns (uint256 result) {
        assembly {
            result := sload(location)
        }
    }

  /// Returns 0 on success, 1 on error
  function write(uint8 capIndex, uint256 location, uint256 value) internal returns (uint8 err) {
      bytes memory input = new bytes(0x80);
      bytes memory ret = new bytes(0x20);

      assembly {
        let ins := add(input, 0x20)
        // First set up the input data (at memory location 0x0)
        // The write call is 0x-07
        mstore(add(ins,0x0),0x07)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The storage location
        mstore(add(ins,0x40),location)
        // The value we want to store
        mstore(add(ins,0x60),value)
        // clear the output buffer
        let retSize := 0x20
        let retLoc := add(ret, retSize)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 97 because it is 1+32+32+32
        // we will store the result at retLoc and it will be 32 bytes
        if iszero(delegatecall(gas, caller, add(ins,31), 97, retLoc, retSize)) {
            mstore(retLoc,0)
            revert(retLoc,retSize)
        }
        err := mload(retLoc)
    }
  }

  function set_entry(uint8 capIndex, bytes32 procId) internal returns (uint32 err) {
    bytes memory input = new bytes(0x60);
    bytes memory ret = new bytes(0x20);

    assembly {
        let ins := add(input, 0x20)
        // First set up the input data (at memory location 0x0)
        // The delete syscall is 6
        mstore(add(ins,0x0),6)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The name of the procedure (24 bytes)
        mstore(add(ins,0x40),procId)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 65 because it is 1+32+32
        // we will store the result at 0x80 and it will be 32 bytes
        let retSize := 0x20
        let retLoc := add(ret, 0x20)
        err := 0
        if iszero(delegatecall(gas, caller, add(ins,31), 65, retLoc, retSize)) {
            err := add(2200, mload(retLoc))
            mstore(0xd, err)
            revert(0xd,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }

  function proc_call(uint8 capIndex, bytes24 procId, bytes memory input) internal returns (uint32 err, bytes memory output) {
        assembly {
            function malloc(size) -> result {
                // align to 32-byte words
                let rsize := add(size,sub(32,mod(size,32)))
                // get the current free mem location
                result :=  mload(0x40)
                // Bump the value of 0x40 so that it holds the next
                // available memory location.
                mstore(0x40,add(result,rsize))
            }
            function memcopy(t,f,s) {
                // t - memory address to copy to
                // f - memory address to copy from
                // s - number of bytes

                // Calculate the number of 32-byte words.
                let nwords := div(s,32)
                // Remaining bytes not in 32-byte word.
                let rem := mod(s,32)
                // Offset location of the remaining bytes.
                let startrem := mul(nwords,32)

                // Copy the 32-byte words
                let nlimit := mul(nwords,32)
                // Currently each loop costs 78 gas, i.e. 78 gas per 32 bytes
                // 2.4375 gas per byte.
                for { let n:= 0 } iszero(eq(n, nlimit)) { n := add(n, 32)} {
                    mstore(add(t, n), mload(add(f, n)))
                }

                // Copy the remaining bytes
                if rem {
                    // Copy 32 bytes from the start of the remainder
                    let val := mload(add(f,startrem))
                    // Clear the bytes we don't want
                    let clearedVal := and(val,mul(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,exp(0x100,sub(32,rem))))
                    // Copy the 32 bytes from the target desintation
                    let targetVal := mload(add(t,startrem))
                    // Clear the last rem bytes from this targetVal
                    let clearedTargetVal := and(targetVal,div(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,exp(0x100,rem)))
                    // Combine the values together with bitwise-OR
                    let finalVal := or(clearedVal, clearedTargetVal)
                    mstore(add(t,startrem),finalVal)
                }
            }

            let inputSize := mload(input)
            let bufSize := add(0x60, inputSize)

            let buf := malloc(bufSize)

            // First set up the input data
            // The call call is 0x-03
            mstore(add(buf,0x0),0x03)
            // The capability index
            mstore(add(buf,0x20),capIndex)
            // The key of the procedure
            mstore(add(buf,0x40),div(procId,0x10000000000000000))

            // The data from 0x60 onwards is the data we want to send to
            // this procedure
            let inputStart := add(input, 0x20)
            let bufStart := add(buf, 0x60)

            memcopy(bufStart,inputStart,mload(input))

            // "in_offset" is at 31, because we only want the last byte of type
            // "in_size" is 97 because it is 1+32+32+32
            // we will store the result at 0x80 and it will be 32 bytes
            if iszero(delegatecall(gas, caller, add(buf,31), sub(bufSize, 31), 0, 0)) {
                let outSize := returndatasize
                output := malloc(add(outSize, 0x20))
                mstore(output, outSize)

                returndatacopy(add(output, 0x20), 0, outSize)
                err := add(2200, mload(add(output, 0x20)))

                mstore(add(output, 0x20), err)
                revert(add(output, 0x20),outSize)
            }

            // simply return whatever the system call returned
            let outSize := returndatasize
            output := malloc(add(outSize, 0x20))
            mstore(output, outSize)

            returndatacopy(add(output, 0x20), 0, outSize)
            err := 0
        }
  }

  function proc_acc_call(uint8 capIndex, address account, uint256 amount, bytes memory input) internal returns (uint32 err, bytes memory output) {
        assembly {
            function malloc(size) -> result {
                // align to 32-byte words
                let rsize := add(size,sub(32,mod(size,32)))
                // get the current free mem location
                result :=  mload(0x40)
                // Bump the value of 0x40 so that it holds the next
                // available memory location.
                mstore(0x40,add(result,rsize))
            }
            function memcopy(t,f,s) {
                // t - memory address to copy to
                // f - memory address to copy from
                // s - number of bytes

                // Calculate the number of 32-byte words.
                let nwords := div(s,32)
                // Remaining bytes not in 32-byte word.
                let rem := mod(s,32)
                // Offset location of the remaining bytes.
                let startrem := mul(nwords,32)

                // Copy the 32-byte words
                for { let n:= 0 } iszero(eq(n, nwords)) { n := add(n, 1)} {
                    mstore(add(t, mul(n,32)), mload(add(f, mul(n,32))))
                }

                // Copy the remaining bytes
                if rem {
                    // Copy 32 bytes from the start of the remainder
                    let val := mload(add(f,startrem))
                    // Clear the bytes we don't want
                    let clearedVal := and(val,mul(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,exp(0x100,sub(32,rem))))
                    // Copy the 32 bytes from the target desintation
                    let targetVal := mload(add(t,startrem))
                    // Clear the last rem bytes from this targetVal
                    let clearedTargetVal := and(targetVal,div(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,exp(0x100,rem)))
                    // Combine the values together with bitwise-OR
                    let finalVal := or(clearedVal, clearedTargetVal)
                    mstore(add(t,startrem),finalVal)
                }
            }

            let inputSize := mload(input)
            let bufSize := add(0x80, inputSize)

            let buf := malloc(bufSize)

            // First set up the input data
            // The acc call call is 0x-09
            mstore(add(buf,0x0),0x09)
            // The capability index
            mstore(add(buf,0x20),capIndex)
            // The address of the account/contract
            mstore(add(buf,0x40),account)
            // The wei to be sent
            mstore(add(buf,0x60),amount)

            // The data from 0x80 onwards is the data we want to send to
            // this procedure
            let inputStart := add(input, 0x20)
            let bufStart := add(buf, 0x80)

            memcopy(bufStart,inputStart,inputSize)

            let x := delegatecall(gas, caller, add(buf,31), sub(bufSize, 31), 0x0, 0x0)

            let outSize := returndatasize
                output := malloc(add(outSize, 0x20))
                mstore(output, outSize)
                returndatacopy(add(output, 0x20), 0, outSize)

            if x {
                // success condition
                err := 0
            }

            if iszero(x) {
                // error condition
                err := 1
            }
        }
  }

  function proc_reg(uint8 capIndex, bytes32 procId, address procAddr, uint256[] caps) internal returns (uint32 err) {
    uint256 nCapKeys = caps.length;
    bytes memory input = new bytes(97 + nCapKeys*32);
    uint256 inSize = input.length;
    bytes memory retInput = new bytes(32);
    uint256 retSize = retInput.length;

    assembly {
        function malloc(size) -> result {
            // align to 32-byte words
            let rsize := add(size,sub(32,mod(size,32)))
            // get the current free mem location
            result :=  mload(0x40)
            // Bump the value of 0x40 so that it holds the next
            // available memory location.
            mstore(0x40,add(result,rsize))
        }
        let ins := add(input, 0x20)
        // First set up the input data (at memory location 0x0)
        // The register syscall is 4
        mstore(add(ins,0x0),4)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The name of the procedure (24 bytes)
        mstore(add(ins,0x40),procId)
        // The address (20 bytes)
        mstore(add(ins,0x60),procAddr)
        // The caps are just listed one after another, not in the dyn array
        // format specified by Solidity
        for { let n := 0 } iszero(eq(n, mul(nCapKeys,0x20))) { n := add(n, 0x20) } {
            mstore(add(add(ins,0x80),n),mload(add(caps,add(0x20,n))))
        }
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 97 because it is 1+32+32+32
        // we will store the result at 0x80 and it will be 32 bytes
        err := 0
        let status := delegatecall(gas, caller, add(ins,31), inSize, 0, 0)
        let retLoc := malloc(returndatasize)
        returndatacopy(retLoc,0,returndatasize)
        if iszero(status) {
            revert(retLoc,returndatasize)
        }
        // Here we will just take the first 32 bytes of the return data.
        err := mload(retLoc)
    }
    return err;
  }

  function proc_del(uint8 capIndex, bytes32 procId) internal returns (uint32 err) {

    bytes memory input = new bytes(0x60);
    bytes memory ret = new bytes(0x20);
    uint256 retSize = ret.length;

    assembly {
        let ins := add(input, 0x20)
        // First set up the input data (at memory location 0x0)
        // The delete syscall is 5
        mstore(add(ins,0x0),5)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The name of the procedure (24 bytes)
        mstore(add(ins,0x40),procId)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 65 because it is 1+32+32
        // we will store the result at 0x80 and it will be 32 bytes
        let retLoc := add(ret, 0x20)
        err := 0
        if iszero(delegatecall(gas, caller, add(ins,31), 65, retLoc, retSize)) {
            err := add(2200, mload(retLoc))
            mstore(0xd, err)
            revert(0xd,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }

  function proc_log0(uint8 capIndex, uint32 value) internal returns (uint32 err) {

    bytes memory input = new bytes(4 * 0x20);
    bytes memory ret = new bytes(0x20);
    uint256 retSize = ret.length;

    assembly {
        let ins := add(input, 0x20)
        let retLoc := add(ret, 0x20)
        // First set up the input data (at memory location ins)
        // The log call is 0x-08
        mstore(add(ins,0x0),0x08)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The number of topics we will use
        mstore(add(ins,0x40),0x0)
        // The value we want to log
        mstore(add(ins,0x60),value)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 97 because it is 1+32+32+32
        // we will store the result at 0x80 and it will be 32 bytes
        if iszero(delegatecall(gas, caller, add(ins,31), 97, retLoc, retSize)) {
            mstore(retLoc,add(2200,mload(retLoc)))
            revert(retLoc,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }
  function proc_log1(uint8 capIndex, bytes32 t1, bytes32 value) internal returns (uint32 err) {

    bytes memory input = new bytes(5 * 0x20);
    bytes memory ret = new bytes(0x20);
    uint256 retSize = ret.length;

    assembly {
        let ins := add(input, 0x20)
        let retLoc := add(ret, 0x20)

        // First set up the input data (at memory location 0x0)
        // The log call is 0x-08
        mstore(add(ins,0x0),0x08)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The number of topics we will use
        mstore(add(ins,0x40),0x1)
        // The first topic
        mstore(add(ins,0x60),t1)
        // The value we want to log
        mstore(add(ins,0x80),value)

        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 129 because it is 1+32+32+32+32
        // we will store the result at retLoc and it will be 32 bytes
        if iszero(delegatecall(gas, caller, add(ins,31), 129, retLoc, retSize)) {
            mstore(retLoc,add(2200,mload(retLoc)))
            revert(retLoc,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }

  function proc_log2(uint8 capIndex, uint32 t1, uint32 t2, uint32 value) internal returns (uint32 err) {
    bytes memory input = new bytes(6 * 0x20);
    bytes memory ret = new bytes(0x20);
    uint256 retSize = ret.length;

    assembly {
        let ins := add(input, 0x20)
        let retLoc := add(ret, 0x20)

        // First set up the input data (at memory location 0x0)
        // The log call is 0x-08
        mstore(add(ins,0x0),0x08)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The number of topics we will use
        mstore(add(ins,0x40),0x2)
        // The first topic
        mstore(add(ins,0x60),t1)
        // The second topic
        mstore(add(ins, 0x80),t2)
        // The value we want to log
        mstore(add(ins, 0xa0),value)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 161 because it is 1+32+32+32+32+32
        // we will store the result at retLoc and it will be 32 bytes
        if iszero(delegatecall(gas, caller, add(ins,31), 161, retLoc, retSize)) {
            mstore(retLoc,add(2200,mload(retLoc)))
            revert(retLoc,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }

  function proc_log3(uint8 capIndex, uint32 t1, uint32 t2, uint32 t3, uint32 value) internal returns (uint32 err) {
    bytes memory input = new bytes(7 * 0x20);
    bytes memory ret = new bytes(0x20);
    uint256 retSize = ret.length;

    assembly {
        let ins := add(input, 0x20)
        let retLoc := add(ret, 0x20)

        // First set up the input data (at memory location 0x0)
        // The log call is 0x-08
        mstore(add(ins,0x0),0x08)
        // The capability index
        mstore(add(ins,0x20),capIndex)
        // The number of topics we will use
        mstore(add(ins,0x40),0x3)
        // The first topic
        mstore(add(ins,0x60),t1)
        // The second topic
        mstore(add(ins,0x80),t2)
        // The third topic
        mstore(add(ins,0xa0),t3)
        // The value we want to log
        // TODO: this is limited to 32 bytes, it should not be
        mstore(add(ins,0xc0),value)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 193 because it is 1+32+32+32+32+32+32
        // we will store the result at retLoc and it will be 32 bytes
        if iszero(delegatecall(gas, caller, add(ins,31), 193, retLoc, retSize)) {
            mstore(retLoc,add(2200,mload(retLoc)))
            revert(retLoc,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }

  function proc_log4(uint8 capIndex, uint32 t1, uint32 t2, uint32 t3, uint32 t4, uint32 value) internal returns (uint32 err) {
    bytes memory input = new bytes(8 * 0x20);
    bytes memory ret = new bytes(0x20);
    uint256 retSize = ret.length;

    assembly {
        let ins := add(input, 0x20)
        let retLoc := add(ret, 0x20)

        // First set up the input data (at memory location 0x0)
        // The log call is 0x-08
        mstore(add(ins,0x0),0x08)
        // The capability index
        mstore(add(ins,0x20), capIndex)
        // The number of topics we will use
        mstore(add(ins,0x40),0x4)
        // The first topic
        mstore(add(ins,0x60),t1)
        // The second topic
        mstore(add(ins,0x80),t2)
        // The third topic
        mstore(add(ins,0xa0),t3)
        // The fourth topic
        mstore(add(ins,0xc0),t4)
        // The value we want to log
        mstore(add(ins,0xe0),value)
        // "in_offset" is at 31, because we only want the last byte of type
        // "in_size" is 225 because it is 1+32+32+32+32+32+32+32
        // we will store the result at retLoc and it will be 32 bytes
        if iszero(delegatecall(gas, caller, add(ins,31), 225, retLoc, retSize)) {
            mstore(retLoc,add(2200,mload(retLoc)))
            revert(retLoc,retSize)
        }
        err := mload(retLoc)
    }
    return err;
  }


}
