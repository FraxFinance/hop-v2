// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console } from "forge-std/Script.sol";
import { SafeTx, SafeTxHelper } from "frax-std/SafeTxHelper.sol";

import { IHopV2 } from "src/contracts/interfaces/IHopV2.sol";

interface ILegacyFraxtalHop {
    function owner() external view returns (address);

    function recoverERC20(address tokenAddress, address recipient, uint256 tokenAmount) external;
}

/// @dev `removeDust` is public on HopV2 but is not declared on IHopV2.
interface IHopV2Dust {
    function removeDust(address oft, uint256 amountLD) external view returns (uint256);
}

/// @notice Builds the Fraxtal Safe batch that recovers stuck frxUSD from the
///         deprecated FraxtalHop and relays it to Polygon through FraxtalHopV2.
///
/// The user's original Ethereum tx called the 4-arg
/// `sendOFT(address,uint32,bytes32,uint256)` on the legacy Ethereum RemoteHop with
/// dstEid 30109, recipient 0xAfA88A..A112 and 9999.4e18 - i.e. dstGas 0 and empty
/// data - so this batch reproduces those exact parameters. Empty data means
/// `FraxtalHopV2._generateSendParam()` sets `sendParam.to = recipient` directly: a
/// plain OFT send to the EOA, with no compose on the destination.
///
/// FEE FRESHNESS: the LZ fee is quoted at script-run time and baked into the JSON as
/// a static `value`. Overpayment is refunded to the Safe by `HopV2._handleMsgValue()`,
/// but an underpayment reverts the whole batch with `InsufficientFee`. Re-run this
/// script (or the printed `cast call`) immediately before the signers execute.
///
/// Run:
///   forge script src/script/hop/fix/RecoverDeprecatedFraxtalHopToPolygon.s.sol --rpc-url https://rpc.frax.com --ffi
contract RecoverDeprecatedFraxtalHopToPolygon is Script {
    address public constant FRAXTAL_SAFE = 0x5f25218ed9474b721d6a38c115107428E832fA2E;
    address public constant LEGACY_FRAXTAL_HOP = 0x2A2019b30C157dB6c1C01306b8025167dBe1803B;
    address public constant FRAXTAL_HOP_V2 = 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36;

    address public constant FRAXTAL_FRXUSD = 0xFc00000000000000000000000000000000000001;
    address public constant FRAXTAL_FRXUSD_OFT = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4;

    uint256 public constant FRAXTAL_CHAIN_ID = 252;
    uint32 public constant POLYGON_EID = 30_109;
    uint128 public constant DST_GAS = 0;
    uint256 public constant AMOUNT_LD = 9_999_400_000_000_000_000_000;

    /// @dev Percent of the live quote written into the batch. Excess is refunded to the Safe.
    uint256 public constant FEE_BUFFER_PCT = 150;

    address public constant RECIPIENT = 0xAfA88A2F075dE96934bc0Eeb2EB846091355A112;

    function run() external {
        string memory root = vm.projectRoot();
        string memory outputDirRel = "src/script/hop/fix/txs/RecoverDeprecatedFraxtalHopToPolygon";
        string memory outputDir = string(abi.encodePacked(root, "/", outputDirRel));
        vm.createDir(outputDirRel, true);

        uint256 liveQuote = _checkPreconditions();
        uint256 fee = (liveQuote * FEE_BUFFER_PCT) / 100;

        // The Safe pays the fee out of its own native balance at execution time.
        require(FRAXTAL_SAFE.balance >= fee, "safe native balance below buffered fee");

        SafeTx[] memory txs = new SafeTx[](3);

        txs[0] = SafeTx({
            name: "Recover stuck frxUSD from legacy FraxtalHop",
            to: LEGACY_FRAXTAL_HOP,
            value: 0,
            data: abi.encodeCall(ILegacyFraxtalHop.recoverERC20, (FRAXTAL_FRXUSD, FRAXTAL_SAFE, AMOUNT_LD))
        });

        txs[1] = SafeTx({
            name: "Approve FraxtalHopV2 to bridge recovered frxUSD",
            to: FRAXTAL_FRXUSD,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (FRAXTAL_HOP_V2, AMOUNT_LD))
        });

        txs[2] = SafeTx({
            name: "Relay recovered frxUSD to Polygon",
            to: FRAXTAL_HOP_V2,
            value: fee,
            data: abi.encodeWithSignature(
                "sendOFT(address,uint32,bytes32,uint256,uint128,bytes)",
                FRAXTAL_FRXUSD_OFT,
                POLYGON_EID,
                bytes32(uint256(uint160(RECIPIENT))),
                AMOUNT_LD,
                DST_GAS,
                ""
            )
        });

        string memory filename = string(
            abi.encodePacked(outputDir, "/252-0xafa88a2f075de96934bc0eeb2eb846091355a112.json")
        );

        new SafeTxHelper().writeTxs(txs, filename);

        console.log("Safe tx JSON written to:", filename);
        console.log("Live LZ quote (wei):    ", liveQuote);
        console.log("Buffered value (wei):   ", fee);
        console.log("Safe native balance:    ", FRAXTAL_SAFE.balance);
        console.log("");
        console.log("Before signing, re-check that the live quote is still below the buffered value:");
        console.log(
            '  cast call 0x00000000e18aFc20Afe54d4B2C8688bB60c06B36 "quote(address,uint32,bytes32,uint256,uint128,bytes)(uint256)" \\'
        );
        console.log(
            "    0x96A394058E2b84A89bac9667B19661Ed003cF5D4 30109 0x000000000000000000000000afa88a2f075de96934bc0eeb2eb846091355a112 \\"
        );
        console.log("    9999400000000000000000 0 0x --rpc-url https://rpc.frax.com");
    }

    /// @dev Assert every piece of state this batch depends on, then return the live LZ quote.
    ///      Without these the script would happily emit a batch that either bricks on
    ///      execution or is silently stamped for the wrong chain.
    function _checkPreconditions() internal view returns (uint256 liveQuote) {
        // `SafeTxHelper.writeTxs()` stamps `chainId` from `block.chainid`, so a wrong
        // --rpc-url yields a plausible-looking batch labelled for the wrong chain.
        require(block.chainid == FRAXTAL_CHAIN_ID, "not Fraxtal: check --rpc-url");

        // tx0: the Safe owns the deprecated hop, and the hop still holds the stuck funds.
        require(ILegacyFraxtalHop(LEGACY_FRAXTAL_HOP).owner() == FRAXTAL_SAFE, "safe does not own legacy hop");
        require(
            IERC20(FRAXTAL_FRXUSD).balanceOf(LEGACY_FRAXTAL_HOP) >= AMOUNT_LD,
            "legacy hop balance below AMOUNT_LD"
        );

        // tx2: FraxtalHopV2 will accept this OFT and this destination.
        require(!IHopV2(FRAXTAL_HOP_V2).paused(), "FraxtalHopV2 is paused");
        require(IHopV2(FRAXTAL_HOP_V2).approvedOft(FRAXTAL_FRXUSD_OFT), "OFT not approved on FraxtalHopV2");
        require(IHopV2(FRAXTAL_HOP_V2).remoteHop(POLYGON_EID) != bytes32(0), "no remoteHop for POLYGON_EID");

        // The recipient must receive the full amount: any dust would be silently truncated.
        require(
            IHopV2Dust(FRAXTAL_HOP_V2).removeDust(FRAXTAL_FRXUSD_OFT, AMOUNT_LD) == AMOUNT_LD,
            "AMOUNT_LD would lose dust"
        );

        liveQuote = IHopV2(FRAXTAL_HOP_V2).quote({
            _oft: FRAXTAL_FRXUSD_OFT,
            _dstEid: POLYGON_EID,
            _recipient: bytes32(uint256(uint160(RECIPIENT))),
            _amountLD: AMOUNT_LD,
            _dstGas: DST_GAS,
            _data: ""
        });
        require(liveQuote > 0, "quote returned zero");
    }
}
